use std::collections::HashSet;
use std::env;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, mpsc};
use std::thread;
use std::time::{Duration, Instant};

use chrono::Local;
use serde_json::{Value, json};
use thiserror::Error;

use crate::model::{AccountRateLimitsResponse, AccountTokenUsageResponse, UsageSnapshot};

const MAX_MESSAGE_BYTES: usize = 2 * 1024 * 1024;
const MAX_PENDING_MESSAGES: usize = 8;
const MAX_IGNORED_BLANK_MESSAGES: usize = 64;
const MAX_IGNORED_BLANK_BYTES: usize = 64 * 1024;
const MAX_STDERR_BYTES: usize = 16 * 1024;
const RATE_LIMIT_GRACE: Duration = Duration::from_millis(350);
const RESPONSE_STABILITY_GRACE: Duration = Duration::from_millis(50);
const TERMINATION_GRACE: Duration = Duration::from_millis(150);

const SIGTERM: i32 = 15;
const SIGKILL: i32 = 9;
const F_GETFL: i32 = 3;
const F_SETFL: i32 = 4;
const O_NONBLOCK: i32 = 0o4000;

unsafe extern "C" {
    fn kill(pid: i32, signal: i32) -> i32;
    fn fcntl(fd: i32, command: i32, ...) -> i32;
}

#[derive(Debug, Error)]
pub enum AppServerError {
    #[error("Could not find the Codex CLI. Set CODEX_USAGE_BAR_CODEX_PATH or add codex to PATH.")]
    CliNotFound,
    #[error("Could not launch Codex CLI: {0}")]
    Launch(#[source] std::io::Error),
    #[error("Could not communicate with Codex app-server: {0}")]
    Io(#[from] std::io::Error),
    #[error("Codex app-server returned invalid JSON: {message}")]
    Json {
        message: String,
        #[source]
        source: serde_json::Error,
    },
    #[error("Codex app-server returned an oversized message")]
    OversizedMessage,
    #[error("Codex app-server returned too many messages before they could be processed")]
    MessageFlood,
    #[error("Codex app-server error: {0}")]
    Server(String),
    #[error("Timed out initializing Codex app-server")]
    InitializeTimeout,
    #[error("Timed out waiting for Codex usage")]
    Timeout,
    #[error("Codex app-server stopped before returning usage{0}")]
    Stopped(String),
}

impl From<serde_json::Error> for AppServerError {
    fn from(source: serde_json::Error) -> Self {
        Self::Json {
            message: clean_diagnostic(&source.to_string()),
            source,
        }
    }
}

pub fn fetch_usage_snapshot(timeout: Duration) -> Result<UsageSnapshot, AppServerError> {
    let executable = resolve_codex().ok_or(AppServerError::CliNotFound)?;
    fetch_usage_snapshot_with_executable(&executable, timeout)
}

fn fetch_usage_snapshot_with_executable(
    executable: &Path,
    timeout: Duration,
) -> Result<UsageSnapshot, AppServerError> {
    let started = Instant::now();
    let deadline = started.checked_add(timeout).unwrap_or(started);
    let mut command = Command::new(executable);
    command
        .args(["app-server", "--stdio"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        // A dedicated process group lets cleanup reach descendants that inherit
        // the app-server's pipe descriptors.
        .process_group(0);
    let mut child = command.spawn().map_err(AppServerError::Launch)?;
    let process_group = i32::try_from(child.id()).ok().filter(|id| *id > 1);

    let (Some(mut stdin), Some(stdout), Some(stderr)) =
        (child.stdin.take(), child.stdout.take(), child.stderr.take())
    else {
        terminate_and_reap(&mut child, process_group);
        return Err(AppServerError::Io(std::io::Error::new(
            std::io::ErrorKind::BrokenPipe,
            "could not configure Codex app-server pipes",
        )));
    };
    if let Err(error) = set_nonblocking(&stdout).and_then(|()| set_nonblocking(&stderr)) {
        drop(stdin);
        terminate_and_reap(&mut child, process_group);
        return Err(AppServerError::Io(error));
    }

    let (line_tx, line_rx) = mpsc::sync_channel(MAX_PENDING_MESSAGES);
    let message_flooded = Arc::new(AtomicBool::new(false));
    let reader_message_flooded = Arc::clone(&message_flooded);
    let stop_readers = Arc::new(AtomicBool::new(false));
    let stop_stdout = Arc::clone(&stop_readers);
    let (stdout_done_tx, stdout_done_rx) = mpsc::sync_channel(1);
    let stdout_thread = thread::spawn(move || {
        let mut reader = BufReader::new(stdout);
        let mut buffer = Vec::new();
        let mut ignored_blank_messages = 0;
        let mut ignored_blank_bytes = 0_usize;
        while !stop_stdout.load(Ordering::Acquire) {
            match read_bounded_line(&mut reader, &mut buffer, MAX_MESSAGE_BYTES) {
                Ok(Some(line)) => {
                    if line.trim().is_empty() {
                        ignored_blank_messages += 1;
                        ignored_blank_bytes = ignored_blank_bytes.saturating_add(line.len());
                        if ignored_blank_messages > MAX_IGNORED_BLANK_MESSAGES
                            || ignored_blank_bytes > MAX_IGNORED_BLANK_BYTES
                        {
                            reader_message_flooded.store(true, Ordering::Release);
                            break;
                        }
                        continue;
                    }
                    match line_tx.try_send(Ok(line)) {
                        Ok(()) => {}
                        Err(mpsc::TrySendError::Full(_)) => {
                            reader_message_flooded.store(true, Ordering::Release);
                            break;
                        }
                        Err(mpsc::TrySendError::Disconnected(_)) => break,
                    }
                }
                Ok(None) => break,
                Err(AppServerError::Io(error))
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                    ) =>
                {
                    thread::sleep(Duration::from_millis(2));
                }
                Err(error) => {
                    match line_tx.try_send(Err(error)) {
                        Ok(()) | Err(mpsc::TrySendError::Disconnected(_)) => {}
                        Err(mpsc::TrySendError::Full(_)) => {
                            reader_message_flooded.store(true, Ordering::Release);
                        }
                    }
                    break;
                }
            }
        }
        let _ = stdout_done_tx.try_send(());
    });
    let (stderr_tx, stderr_rx) = mpsc::sync_channel(1);
    let stop_stderr = Arc::clone(&stop_readers);
    let stderr_thread = thread::spawn(move || {
        let mut bytes = Vec::new();
        let mut stderr = stderr;
        let mut chunk = [0_u8; 4 * 1024];
        while !stop_stderr.load(Ordering::Acquire) {
            match stderr.read(&mut chunk) {
                Ok(0) => break,
                Ok(count) => {
                    let retained = count.min(MAX_STDERR_BYTES.saturating_sub(bytes.len()));
                    bytes.extend_from_slice(&chunk[..retained]);
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(2));
                }
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => break,
            }
        }
        let _ = stderr_tx.try_send(String::from_utf8_lossy(&bytes).into_owned());
    });

    let result = exchange_messages(&mut stdin, &line_rx, &message_flooded, &mut child, deadline);
    drop(stdin);
    terminate_and_reap(&mut child, process_group);
    stop_readers.store(true, Ordering::Release);

    // Never let an escaped descendant that retained a pipe descriptor block the
    // caller indefinitely. Threads that do not finish after process-group
    // cleanup are detached when their JoinHandle is dropped.
    if stdout_done_rx
        .recv_timeout(Duration::from_millis(100))
        .is_ok()
    {
        let _ = stdout_thread.join();
    }
    let stderr = match stderr_rx.recv_timeout(Duration::from_millis(100)) {
        Ok(stderr) => {
            let _ = stderr_thread.join();
            stderr
        }
        Err(_) => String::new(),
    };

    match result {
        Err(AppServerError::Stopped(message)) if !stderr.trim().is_empty() => Err(
            AppServerError::Stopped(format!("{message}: {}", clean_stderr(&stderr))),
        ),
        other => other,
    }
}

fn exchange_messages(
    stdin: &mut ChildStdin,
    lines: &mpsc::Receiver<Result<String, AppServerError>>,
    message_flooded: &AtomicBool,
    child: &mut Child,
    deadline: Instant,
) -> Result<UsageSnapshot, AppServerError> {
    if Instant::now() >= deadline {
        return Err(AppServerError::InitializeTimeout);
    }
    write_message(
        stdin,
        &json!({
            "method": "initialize",
            "id": 1,
            "params": {
                "clientInfo": {
                    "name": "codex-usage-bar",
                    "title": "Codex Usage Bar",
                    "version": env!("CARGO_PKG_VERSION")
                },
                "capabilities": {
                    "experimentalApi": true,
                    "requestAttestation": false
                }
            }
        }),
    )?;

    let initialize_deadline = earlier_deadline(deadline, Duration::from_secs(5));
    loop {
        let message = receive_message(lines, message_flooded, initialize_deadline, true)?;
        let Some(id) = response_id(&message)? else {
            continue;
        };
        if id != 1 {
            return Err(unexpected_response_id(id));
        }
        let (result, error) = response_payload(&message, id)?;
        if let Some(error) = error {
            return Err(AppServerError::Server(describe_server_error(error)));
        }
        debug_assert!(result.is_some());
        break;
    }

    write_message(stdin, &json!({ "method": "initialized" }))?;
    write_message(
        stdin,
        &json!({ "method": "account/usage/read", "id": 2, "params": null }),
    )?;
    let rate_limit_request_sent = write_message(
        stdin,
        &json!({ "method": "account/rateLimits/read", "id": 3, "params": null }),
    )
    .is_ok();

    let mut usage = None;
    let mut rate_limits = None;
    let mut rate_limits_resolved = !rate_limit_request_sent;
    let mut resolved_response_ids = HashSet::new();
    let mut rate_limit_deadline = None;
    let mut complete_response_deadline = None;

    loop {
        if usage.is_some() && rate_limits_resolved && complete_response_deadline.is_none() {
            rate_limit_deadline = None;
            complete_response_deadline = Some(earlier_deadline(deadline, RESPONSE_STABILITY_GRACE));
        } else if usage.is_some() && !rate_limits_resolved && rate_limit_deadline.is_none() {
            rate_limit_deadline = Some(earlier_deadline(deadline, RATE_LIMIT_GRACE));
        }
        let response_deadline = [rate_limit_deadline, complete_response_deadline]
            .into_iter()
            .flatten()
            .min()
            .map_or(deadline, |secondary| secondary.min(deadline));
        let message = match receive_message(lines, message_flooded, response_deadline, false) {
            Ok(message) => message,
            Err(AppServerError::Timeout) if usage.is_some() => {
                if let Some(status) = child.try_wait()?
                    && !status.success()
                {
                    return Err(AppServerError::Stopped(format!(" ({status})")));
                }
                break;
            }
            Err(AppServerError::Stopped(_))
                if usage.is_some() && child_exited_successfully(child)? =>
            {
                break;
            }
            Err(error) => return Err(error),
        };
        let Some(id) = response_id(&message)? else {
            continue;
        };
        if !matches!(id, 2 | 3) {
            return Err(unexpected_response_id(id));
        }
        if !resolved_response_ids.insert(id) {
            return Err(AppServerError::Server(format!(
                "Codex app-server returned response ID {id} more than once."
            )));
        }
        let (result, error) = response_payload(&message, id)?;
        if let Some(error) = error {
            if id == 3 {
                rate_limits_resolved = true;
                continue;
            }
            return Err(AppServerError::Server(describe_server_error(error)));
        }
        let Some(result) = result else {
            return Err(AppServerError::Server(format!(
                "Codex app-server response ID {id} did not contain a result."
            )));
        };
        match id {
            2 => {
                usage = Some(serde_json::from_value::<AccountTokenUsageResponse>(
                    result.clone(),
                )?)
            }
            3 => {
                rate_limits = Some(
                    serde_json::from_value::<AccountRateLimitsResponse>(result.clone())
                        .unwrap_or_else(|_| AccountRateLimitsResponse::malformed_outer_response()),
                );
                rate_limits_resolved = true;
            }
            _ => {}
        }
    }

    usage
        .map(|usage| UsageSnapshot {
            fetched_at: Local::now(),
            usage,
            rate_limits,
        })
        .ok_or(AppServerError::Timeout)
}

fn response_id(message: &Value) -> Result<Option<i64>, AppServerError> {
    let Some(object) = message.as_object() else {
        return Err(AppServerError::Server(
            "Codex app-server returned a non-object JSON-RPC message.".into(),
        ));
    };
    // Messages with a method are server requests or notifications, not
    // responses to one of this client's numeric request IDs.
    if let Some(method) = object.get("method") {
        if !method.is_string() {
            return Err(AppServerError::Server(
                "Codex app-server returned a message with an invalid method.".into(),
            ));
        }
        if object.contains_key("result") || object.contains_key("error") {
            return Err(AppServerError::Server(
                "Codex app-server returned a method message with a response payload.".into(),
            ));
        }
        if object
            .get("id")
            .is_some_and(|id| !id.is_string() && id.as_i64().is_none())
        {
            return Err(AppServerError::Server(
                "Codex app-server returned a method message with an invalid request ID.".into(),
            ));
        }
        return Ok(None);
    }
    let Some(id) = object.get("id") else {
        return Err(AppServerError::Server(
            "Codex app-server returned a JSON-RPC message without an id or method.".into(),
        ));
    };
    id.as_i64().map(Some).ok_or_else(|| {
        AppServerError::Server(
            "Codex app-server returned a response with an invalid request ID.".into(),
        )
    })
}

fn response_payload(
    message: &Value,
    id: i64,
) -> Result<(Option<&Value>, Option<&Value>), AppServerError> {
    let result = message.get("result");
    let error = message.get("error");
    if result.is_some() == error.is_some() {
        return Err(AppServerError::Server(format!(
            "Codex app-server response ID {id} must contain exactly one of result or error."
        )));
    }
    if error.is_some_and(|value| !value.is_object()) {
        return Err(AppServerError::Server(format!(
            "Codex app-server response ID {id} contained an invalid error object."
        )));
    }
    Ok((result, error))
}

fn unexpected_response_id(id: i64) -> AppServerError {
    AppServerError::Server(format!(
        "Codex app-server returned unexpected response ID {id}."
    ))
}

fn read_bounded_line<R: BufRead>(
    reader: &mut R,
    buffer: &mut Vec<u8>,
    maximum: usize,
) -> Result<Option<String>, AppServerError> {
    loop {
        let available = reader.fill_buf()?;
        if available.is_empty() {
            if buffer.is_empty() {
                return Ok(None);
            }
            let bytes = std::mem::take(buffer);
            return String::from_utf8(bytes).map(Some).map_err(|error| {
                AppServerError::Io(std::io::Error::new(std::io::ErrorKind::InvalidData, error))
            });
        }

        let newline = available.iter().position(|byte| *byte == b'\n');
        let content_length = newline.unwrap_or(available.len());
        if buffer.len().saturating_add(content_length) > maximum {
            return Err(AppServerError::OversizedMessage);
        }
        buffer.extend_from_slice(&available[..content_length]);
        let consumed = content_length + usize::from(newline.is_some());
        reader.consume(consumed);

        if newline.is_some() {
            let bytes = std::mem::take(buffer);
            return String::from_utf8(bytes).map(Some).map_err(|error| {
                AppServerError::Io(std::io::Error::new(std::io::ErrorKind::InvalidData, error))
            });
        }
    }
}

fn receive_message(
    lines: &mpsc::Receiver<Result<String, AppServerError>>,
    message_flooded: &AtomicBool,
    deadline: Instant,
    initializing: bool,
) -> Result<Value, AppServerError> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return Err(timeout_error(initializing));
    }
    let line = lines
        .recv_timeout(remaining)
        .map_err(|error| match error {
            mpsc::RecvTimeoutError::Timeout => timeout_error(initializing),
            mpsc::RecvTimeoutError::Disconnected if message_flooded.load(Ordering::Acquire) => {
                AppServerError::MessageFlood
            }
            mpsc::RecvTimeoutError::Disconnected => AppServerError::Stopped(String::new()),
        })??;
    Ok(serde_json::from_str(&line)?)
}

fn earlier_deadline(overall: Instant, duration: Duration) -> Instant {
    Instant::now()
        .checked_add(duration)
        .unwrap_or(overall)
        .min(overall)
}

fn child_exited_successfully(child: &mut Child) -> Result<bool, AppServerError> {
    let deadline = Instant::now()
        .checked_add(RESPONSE_STABILITY_GRACE)
        .unwrap_or_else(Instant::now);
    loop {
        if let Some(status) = child.try_wait()? {
            return Ok(status.success());
        }
        if Instant::now() >= deadline {
            return Ok(false);
        }
        thread::sleep(Duration::from_millis(1));
    }
}

fn terminate_and_reap(child: &mut Child, process_group: Option<i32>) {
    if let Some(process_group) = process_group {
        signal_process_group(process_group, SIGTERM);
    }

    let wait_deadline = Instant::now()
        .checked_add(TERMINATION_GRACE)
        .unwrap_or_else(Instant::now);
    while Instant::now() < wait_deadline {
        let child_running = child.try_wait().ok().flatten().is_none();
        let group_running = process_group.is_some_and(process_group_exists);
        if !child_running && !group_running {
            break;
        }
        thread::sleep(Duration::from_millis(10));
    }

    if let Some(process_group) = process_group.filter(|group| process_group_exists(*group)) {
        signal_process_group(process_group, SIGKILL);
    }
    if child.try_wait().ok().flatten().is_none() {
        let _ = child.kill();
    }
    let _ = child.wait();
}

fn signal_process_group(process_group: i32, signal: i32) {
    if process_group > 1 {
        // SAFETY: `process_group` is the positive ID of the child group created
        // immediately before spawn; negating it targets that group per kill(2).
        let _ = unsafe { kill(-process_group, signal) };
    }
}

fn set_nonblocking<T: AsRawFd>(file: &T) -> std::io::Result<()> {
    let descriptor = file.as_raw_fd();
    // SAFETY: `descriptor` belongs to the live pipe object, and F_GETFL does
    // not require a variadic argument.
    let flags = unsafe { fcntl(descriptor, F_GETFL) };
    if flags < 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: F_SETFL expects one integer variadic argument. Preserving all
    // existing flags and adding O_NONBLOCK is valid for a pipe descriptor.
    if unsafe { fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) } < 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}

fn process_group_exists(process_group: i32) -> bool {
    if process_group <= 1 {
        return false;
    }
    // SAFETY: signal zero performs existence/permission checking only.
    unsafe { kill(-process_group, 0) == 0 }
}

fn timeout_error(initializing: bool) -> AppServerError {
    if initializing {
        AppServerError::InitializeTimeout
    } else {
        AppServerError::Timeout
    }
}

fn write_message(stdin: &mut ChildStdin, value: &Value) -> Result<(), AppServerError> {
    serde_json::to_writer(&mut *stdin, value)?;
    stdin.write_all(b"\n")?;
    stdin.flush()?;
    Ok(())
}

fn describe_server_error(error: &Value) -> String {
    let description = error
        .get("message")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .or_else(|| error.get("code").map(ToString::to_string))
        .unwrap_or_else(|| error.to_string());
    clean_diagnostic(&description)
}

fn clean_stderr(stderr: &str) -> String {
    let line = stderr
        .lines()
        .find(|line| !line.trim().is_empty())
        .unwrap_or(stderr)
        .trim();
    clean_diagnostic(line)
}

fn clean_diagnostic(value: &str) -> String {
    const MAXIMUM_CHARACTERS: usize = 237;
    let mut clean = String::new();
    let mut character_count = 0;
    let mut pending_space = false;
    let mut was_truncated = false;
    for character in value.chars() {
        if character.is_control()
            || character.is_whitespace()
            || is_invisible_format_control(character)
        {
            pending_space = character_count > 0;
            continue;
        }
        if pending_space {
            if character_count >= MAXIMUM_CHARACTERS {
                was_truncated = true;
                break;
            }
            clean.push(' ');
            character_count += 1;
            pending_space = false;
        }
        if character_count >= MAXIMUM_CHARACTERS {
            was_truncated = true;
            break;
        }
        clean.push(character);
        character_count += 1;
    }
    let clean = clean.trim();
    if clean.is_empty() {
        return "unknown error".into();
    }
    if was_truncated {
        format!("{clean}...")
    } else {
        clean.to_owned()
    }
}

fn is_invisible_format_control(character: char) -> bool {
    matches!(
        character,
        '\u{061c}'
            | '\u{200b}'..='\u{200f}'
            | '\u{202a}'..='\u{202e}'
            | '\u{2060}'..='\u{206f}'
            | '\u{feff}'
            | '\u{fff9}'..='\u{fffb}'
    )
}

fn resolve_codex() -> Option<PathBuf> {
    // An explicit override is authoritative. Silently falling back to PATH
    // hides typos and can execute a different binary than the user selected.
    if let Some(path) = env::var_os("CODEX_USAGE_BAR_CODEX_PATH") {
        let path = expand_home(PathBuf::from(path));
        return is_executable(&path).then_some(path);
    }
    let mut candidates = Vec::new();
    if let Some(path) = env::var_os("PATH") {
        candidates.extend(env::split_paths(&path).map(|directory| directory.join("codex")));
    }
    candidates.extend([
        PathBuf::from("/usr/bin/codex"),
        PathBuf::from("/usr/local/bin/codex"),
    ]);
    if let Some(home) = env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|home| home.is_absolute())
    {
        candidates.push(home.join(".local/bin/codex"));
        candidates.push(home.join(".npm-global/bin/codex"));
    }

    let mut seen = HashSet::new();
    candidates
        .into_iter()
        .find(|path| seen.insert(path.clone()) && is_executable(path))
}

fn expand_home(path: PathBuf) -> PathBuf {
    if path == Path::new("~") {
        return env::var_os("HOME").map(PathBuf::from).unwrap_or(path);
    }
    if let Ok(rest) = path.strip_prefix("~")
        && let Some(home) = env::var_os("HOME")
    {
        return PathBuf::from(home).join(rest);
    }
    path
}

fn is_executable(path: &Path) -> bool {
    fs::metadata(path)
        .map(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    const MAXIMUM_ETXTBSY_RETRIES: usize = 4;

    fn run_fake_codex(script: &str, timeout: Duration) -> Result<UsageSnapshot, AppServerError> {
        // Keep tests compatible with read-only source trees and external
        // CARGO_TARGET_DIR builds; only the system temporary directory is needed.
        let directory = tempfile::tempdir().unwrap();
        let executable = directory.path().join("codex");
        let mut file = fs::File::create(&executable).unwrap();
        file.write_all(script.as_bytes()).unwrap();
        file.sync_all().unwrap();
        drop(file);
        let mut permissions = fs::metadata(&executable).unwrap().permissions();
        permissions.set_mode(0o700);
        fs::set_permissions(&executable, permissions).unwrap();
        for retry in 0..=MAXIMUM_ETXTBSY_RETRIES {
            match fetch_usage_snapshot_with_executable(&executable, timeout) {
                Err(error)
                    if retry < MAXIMUM_ETXTBSY_RETRIES
                        && retryable_fake_executable_launch(&error) =>
                {
                    thread::sleep(Duration::from_millis(5 * (retry as u64 + 1)));
                }
                result => return result,
            }
        }
        unreachable!("the final fake-executable launch attempt always returns")
    }

    fn retryable_fake_executable_launch(error: &AppServerError) -> bool {
        matches!(
            error,
            AppServerError::Launch(source) if source.raw_os_error() == Some(26)
        )
    }

    fn fake_codex_script(rate_limit_action: &str) -> String {
        format!(
            r#"#!/bin/sh
set -eu
while IFS= read -r line; do
  case "$line" in
    *'"id":1'*)
      printf '%s\n' '{{"id":1,"result":{{}}}}'
      ;;
    *'"id":2'*)
      printf '%s\n' '{{"id":2,"result":{{"summary":{{"lifetimeTokens":7}},"dailyUsageBuckets":[{{"startDate":"2026-07-08","tokens":7}}]}}}}'
      ;;
{rate_limit_action}
  esac
done
"#
        )
    }

    #[test]
    fn describes_json_rpc_errors() {
        assert_eq!(
            describe_server_error(&json!({ "code": -32601, "message": "not found" })),
            "not found"
        );
    }

    #[test]
    fn fake_executable_retry_classification_is_etxtbsy_only() {
        assert!(retryable_fake_executable_launch(&AppServerError::Launch(
            std::io::Error::from_raw_os_error(26)
        )));
        assert!(!retryable_fake_executable_launch(&AppServerError::Launch(
            std::io::Error::from_raw_os_error(13)
        )));
        assert!(!retryable_fake_executable_launch(
            &AppServerError::InitializeTimeout
        ));
    }

    #[test]
    fn validates_response_ids_and_envelopes_strictly() {
        assert!(matches!(
            response_id(&json!({"id": true, "result": {}})),
            Err(AppServerError::Server(_))
        ));
        assert_eq!(
            response_id(&json!({"method": "server/notification", "params": {}})).unwrap(),
            None
        );
        assert!(response_id(&json!({"method": "server/notification", "result": {}})).is_err());
        assert!(response_id(&json!({"method": "server/request", "id": true})).is_err());
        assert!(response_id(&json!({})).is_err());
        assert!(response_id(&json!([])).is_err());
        assert!(response_payload(&json!({"id": 2}), 2).is_err());
        assert!(response_payload(&json!({"id": 2, "result": {}, "error": {}}), 2).is_err());
    }

    #[test]
    fn expands_home_paths() {
        if let Some(home) = env::var_os("HOME") {
            assert_eq!(
                expand_home(PathBuf::from("~/bin/codex")),
                PathBuf::from(home).join("bin/codex")
            );
        }
    }

    #[test]
    fn rejects_oversized_messages_before_buffering_the_whole_line() {
        let mut reader = BufReader::with_capacity(4, std::io::Cursor::new(b"123456789\n"));
        let mut buffer = Vec::new();
        assert!(matches!(
            read_bounded_line(&mut reader, &mut buffer, 8),
            Err(AppServerError::OversizedMessage)
        ));
        assert!(buffer.len() <= 8);
    }

    #[test]
    fn bounded_reader_preserves_separate_json_lines() {
        let mut reader = BufReader::with_capacity(3, std::io::Cursor::new(b"{}\n{\"id\":1}\n"));
        let mut buffer = Vec::new();
        assert_eq!(
            read_bounded_line(&mut reader, &mut buffer, 32).unwrap(),
            Some("{}".into())
        );
        assert_eq!(
            read_bounded_line(&mut reader, &mut buffer, 32).unwrap(),
            Some("{\"id\":1}".into())
        );
        assert_eq!(
            read_bounded_line(&mut reader, &mut buffer, 32).unwrap(),
            None
        );
    }

    #[test]
    fn rate_limit_errors_do_not_discard_valid_usage() {
        let script = fake_codex_script(
            r#"    *'"id":3'*)
      printf '%s\n' '{"id":3,"error":{"code":-32601,"message":"unsupported"}}'
      ;;"#,
        );
        let snapshot = run_fake_codex(&script, Duration::from_secs(1)).unwrap();
        assert_eq!(snapshot.buckets()[0].tokens, 7);
        assert!(snapshot.rate_limits.is_none());
    }

    #[test]
    fn malformed_rate_limits_preserve_usage_and_report_data_quality() {
        let script = fake_codex_script(
            r#"    *'"id":3'*)
      printf '%s\n' '{"id":3,"result":"malformed"}'
      ;;"#,
        );
        let snapshot = run_fake_codex(&script, Duration::from_secs(1)).unwrap();
        assert_eq!(snapshot.buckets()[0].tokens, 7);
        assert_eq!(
            snapshot.rate_limits.unwrap().decoding_issues,
            ["response: malformed value"]
        );
    }

    #[test]
    fn missing_rate_limits_return_usage_at_the_deadline() {
        let script = fake_codex_script("");
        let snapshot = run_fake_codex(&script, Duration::from_millis(150)).unwrap();
        assert_eq!(snapshot.buckets()[0].tokens, 7);
        assert!(snapshot.rate_limits.is_none());
    }

    #[test]
    fn missing_rate_limits_use_a_short_grace_not_the_whole_fetch_timeout() {
        let script = fake_codex_script("");
        let started = Instant::now();
        let snapshot = run_fake_codex(&script, Duration::from_secs(2)).unwrap();
        assert_eq!(snapshot.buckets()[0].tokens, 7);
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn one_deadline_bounds_initialization_and_usage_together() {
        let script = r#"#!/bin/sh
set -eu
IFS= read -r _
sleep 5
"#;
        let started = Instant::now();
        assert!(matches!(
            run_fake_codex(script, Duration::from_millis(100)),
            Err(AppServerError::InitializeTimeout)
        ));
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn successful_exit_after_usage_can_omit_optional_rate_limits() {
        let script = r#"#!/bin/sh
set -eu
while IFS= read -r line; do
  case "$line" in
    *'"id":1'*) printf '%s\n' '{"id":1,"result":{}}' ;;
    *'"id":2'*)
      printf '%s\n' '{"id":2,"result":{"summary":{"lifetimeTokens":7},"dailyUsageBuckets":null}}'
      exit 0
      ;;
  esac
done
"#;
        let snapshot = run_fake_codex(script, Duration::from_secs(1)).unwrap();
        assert_eq!(snapshot.usage.summary.lifetime_tokens, Some(7));
        assert!(snapshot.daily_buckets().is_none());
    }

    #[test]
    fn nonzero_exit_after_complete_responses_is_not_masked() {
        let script = r#"#!/bin/sh
set -eu
while IFS= read -r line; do
  case "$line" in
    *'"id":1'*) printf '%s\n' '{"id":1,"result":{}}' ;;
    *'"id":2'*) printf '%s\n' '{"id":2,"result":{"summary":{},"dailyUsageBuckets":[]}}' ;;
    *'"id":3'*) printf '%s\n' '{"id":3,"result":{"rateLimits":null}}'; exit 7 ;;
  esac
done
"#;
        assert!(matches!(
            run_fake_codex(script, Duration::from_secs(1)),
            Err(AppServerError::Stopped(_))
        ));
    }

    #[test]
    fn nonzero_exit_is_not_masked_when_a_descendant_holds_stdout_open() {
        let script = r#"#!/bin/sh
set -eu
while IFS= read -r line; do
  case "$line" in
    *'"id":1'*) printf '%s\n' '{"id":1,"result":{}}' ;;
    *'"id":2'*) printf '%s\n' '{"id":2,"result":{"summary":{},"dailyUsageBuckets":[]}}' ;;
    *'"id":3'*)
      printf '%s\n' '{"id":3,"result":{"rateLimits":null}}'
      (sleep 30) &
      exit 7
      ;;
  esac
done
"#;
        assert!(matches!(
            run_fake_codex(script, Duration::from_secs(1)),
            Err(AppServerError::Stopped(_))
        ));
    }

    #[test]
    fn trailing_malformed_frame_after_usage_is_not_ignored() {
        let script = r#"#!/bin/sh
set -eu
while IFS= read -r line; do
  case "$line" in
    *'"id":1'*) printf '%s\n' '{"id":1,"result":{}}' ;;
    *'"id":2'*) printf '%s\n' '{"id":2,"result":{"summary":{},"dailyUsageBuckets":[]}}' ;;
    *'"id":3'*) printf '%s' '{"id":3,"result":{"rateLimits":null}}{'; exit 0 ;;
  esac
done
"#;
        assert!(matches!(
            run_fake_codex(script, Duration::from_secs(1)),
            Err(AppServerError::Json { .. })
        ));
    }

    #[test]
    fn duplicate_usage_responses_are_rejected() {
        let script = r#"#!/bin/sh
set -eu
while IFS= read -r line; do
  case "$line" in
    *'"id":1'*) printf '%s\n' '{"id":1,"result":{}}' ;;
    *'"id":2'*)
      printf '%s\n' '{"id":2,"result":{"summary":{},"dailyUsageBuckets":[]}}'
      printf '%s\n' '{"id":2,"result":{"summary":{},"dailyUsageBuckets":[]}}'
      ;;
    *'"id":3'*) printf '%s\n' '{"id":3,"result":{"rateLimits":null}}' ;;
  esac
done
"#;
        assert!(matches!(
            run_fake_codex(script, Duration::from_secs(1)),
            Err(AppServerError::Server(message)) if message.contains("more than once")
        ));
    }

    #[test]
    fn unsolicited_response_ids_are_rejected() {
        let script = r#"#!/bin/sh
set -eu
IFS= read -r _
printf '%s\n' '{"id":99,"result":{}}'
printf '%s\n' '{"id":1,"result":{}}'
while IFS= read -r _; do :; done
"#;
        assert!(matches!(
            run_fake_codex(script, Duration::from_secs(1)),
            Err(AppServerError::Server(message)) if message.contains("unexpected response ID 99")
        ));
    }

    #[test]
    fn bounded_channel_reports_a_message_flood() {
        let (sender, receiver) = mpsc::sync_channel(1);
        let flooded = AtomicBool::new(false);
        sender
            .try_send(Ok(r#"{"method":"notification"}"#.into()))
            .unwrap();
        if matches!(
            sender.try_send(Ok(r#"{"method":"notification"}"#.into())),
            Err(mpsc::TrySendError::Full(_))
        ) {
            flooded.store(true, Ordering::Release);
        }
        drop(sender);
        assert_eq!(
            receive_message(
                &receiver,
                &flooded,
                Instant::now() + Duration::from_secs(1),
                false
            )
            .unwrap(),
            json!({"method": "notification"})
        );
        assert!(matches!(
            receive_message(
                &receiver,
                &flooded,
                Instant::now() + Duration::from_secs(1),
                false
            ),
            Err(AppServerError::MessageFlood)
        ));
    }

    #[test]
    fn blank_frame_flood_is_bounded() {
        let script = r#"#!/bin/sh
set -eu
IFS= read -r _
i=0
while [ "$i" -le 64 ]; do
  printf '\n'
  i=$((i + 1))
done
printf '%s\n' '{"id":1,"result":{}}'
"#;
        assert!(matches!(
            run_fake_codex(script, Duration::from_secs(1)),
            Err(AppServerError::MessageFlood)
        ));
    }

    #[test]
    fn process_group_cleanup_handles_descendants_that_inherit_pipes() {
        let script = fake_codex_script(
            r#"    *'"id":3'*)
      (sleep 30) &
      printf '%s\n' '{"id":3,"error":{"code":-32601}}'
      ;;"#,
        );
        let started = Instant::now();
        let snapshot = run_fake_codex(&script, Duration::from_secs(1)).unwrap();
        assert_eq!(snapshot.buckets()[0].tokens, 7);
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn diagnostics_are_control_sanitized_and_character_bounded() {
        let diagnostic = format!("\u{1b}[31m\u{202e}{}\nsecond line", "é".repeat(300));
        let clean = clean_diagnostic(&diagnostic);
        assert!(!clean.chars().any(char::is_control));
        assert!(!clean.contains('\u{202e}'));
        assert!(clean.chars().count() <= 240);
        assert!(clean.ends_with("..."));

        let source = serde_json::from_value::<AccountTokenUsageResponse>(json!({
            "summary": {"lifetimeTokens": "\n\u{202e}not-an-integer"},
            "dailyUsageBuckets": []
        }))
        .unwrap_err();
        let error = AppServerError::from(source).to_string();
        assert!(!error.chars().any(char::is_control));
        assert!(!error.contains('\u{202e}'));
    }

    #[test]
    fn diagnostic_limit_ignores_only_trailing_noncontent() {
        let exact = "a".repeat(237);
        for suffix in [" ", "\u{0001}", "\u{202e}"] {
            assert_eq!(clean_diagnostic(&format!("{exact}{suffix}")), exact);
        }

        let truncated = clean_diagnostic(&format!("{exact} b"));
        assert_eq!(truncated, format!("{exact}..."));
        assert_eq!(truncated.chars().count(), 240);
    }
}
