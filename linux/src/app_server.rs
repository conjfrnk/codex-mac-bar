use std::collections::HashSet;
use std::env;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{ChildStdin, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use chrono::Local;
use serde_json::{Value, json};
use thiserror::Error;

use crate::model::{AccountRateLimitsResponse, AccountTokenUsageResponse, UsageSnapshot};

const MAX_MESSAGE_BYTES: usize = 2 * 1024 * 1024;

#[derive(Debug, Error)]
pub enum AppServerError {
    #[error("Could not find the Codex CLI. Set CODEX_USAGE_BAR_CODEX_PATH or add codex to PATH.")]
    CliNotFound,
    #[error("Could not launch Codex CLI: {0}")]
    Launch(#[source] std::io::Error),
    #[error("Could not communicate with Codex app-server: {0}")]
    Io(#[from] std::io::Error),
    #[error("Codex app-server returned invalid JSON: {0}")]
    Json(#[from] serde_json::Error),
    #[error("Codex app-server returned an oversized message")]
    OversizedMessage,
    #[error("Codex app-server error: {0}")]
    Server(String),
    #[error("Timed out initializing Codex app-server")]
    InitializeTimeout,
    #[error("Timed out waiting for Codex usage")]
    Timeout,
    #[error("Codex app-server stopped before returning usage{0}")]
    Stopped(String),
}

pub fn fetch_usage_snapshot(timeout: Duration) -> Result<UsageSnapshot, AppServerError> {
    let executable = resolve_codex().ok_or(AppServerError::CliNotFound)?;
    fetch_usage_snapshot_with_executable(&executable, timeout)
}

fn fetch_usage_snapshot_with_executable(
    executable: &Path,
    timeout: Duration,
) -> Result<UsageSnapshot, AppServerError> {
    let mut child = Command::new(executable)
        .args(["app-server", "--stdio"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(AppServerError::Launch)?;

    let mut stdin = child.stdin.take().expect("piped stdin");
    let stdout = child.stdout.take().expect("piped stdout");
    let stderr = child.stderr.take().expect("piped stderr");

    let (line_tx, line_rx) = mpsc::channel();
    let stdout_thread = thread::spawn(move || {
        let mut reader = BufReader::new(stdout);
        let mut buffer = Vec::new();
        loop {
            match read_bounded_line(&mut reader, &mut buffer, MAX_MESSAGE_BYTES) {
                Ok(Some(line)) => {
                    if line_tx.send(Ok(line)).is_err() {
                        break;
                    }
                }
                Ok(None) => break,
                Err(error) => {
                    let _ = line_tx.send(Err(error));
                    break;
                }
            }
        }
    });
    let stderr_thread = thread::spawn(move || {
        let mut message = String::new();
        let _ = stderr.take(64 * 1024).read_to_string(&mut message);
        message
    });

    let result = exchange_messages(&mut stdin, &line_rx, timeout);
    drop(stdin);
    let _ = child.kill();
    let _ = child.wait();
    let _ = stdout_thread.join();
    let stderr = stderr_thread.join().unwrap_or_default();

    match result {
        Err(AppServerError::Stopped(message))
            if message.is_empty() && !stderr.trim().is_empty() =>
        {
            Err(AppServerError::Stopped(format!(
                ": {}",
                clean_stderr(&stderr)
            )))
        }
        Err(AppServerError::Timeout) if !stderr.trim().is_empty() => Err(AppServerError::Stopped(
            format!(": {}", clean_stderr(&stderr)),
        )),
        other => other,
    }
}

fn exchange_messages(
    stdin: &mut ChildStdin,
    lines: &mpsc::Receiver<Result<String, AppServerError>>,
    timeout: Duration,
) -> Result<UsageSnapshot, AppServerError> {
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

    let initialize_deadline = Instant::now() + timeout.min(Duration::from_secs(5));
    loop {
        let message = receive_message(lines, initialize_deadline, true)?;
        if message.get("id").and_then(Value::as_i64) != Some(1) {
            continue;
        }
        if let Some(error) = message.get("error") {
            return Err(AppServerError::Server(describe_server_error(error)));
        }
        break;
    }

    write_message(stdin, &json!({ "method": "initialized" }))?;
    write_message(
        stdin,
        &json!({ "method": "account/usage/read", "id": 2, "params": null }),
    )?;
    write_message(
        stdin,
        &json!({ "method": "account/rateLimits/read", "id": 3, "params": null }),
    )?;

    let deadline = Instant::now() + timeout;
    let mut usage = None;
    let mut rate_limits = None;
    let mut rate_limits_resolved = false;

    while Instant::now() < deadline {
        let message = match receive_message(lines, deadline, false) {
            Ok(message) => message,
            Err(AppServerError::Timeout) if usage.is_some() => break,
            Err(error) => return Err(error),
        };
        let Some(id) = message.get("id").and_then(Value::as_i64) else {
            continue;
        };
        if let Some(error) = message.get("error") {
            if id == 3 {
                rate_limits_resolved = true;
                if usage.is_some() {
                    break;
                }
                continue;
            }
            return Err(AppServerError::Server(describe_server_error(error)));
        }
        let Some(result) = message.get("result") else {
            continue;
        };
        match id {
            2 => {
                usage = Some(serde_json::from_value::<AccountTokenUsageResponse>(
                    result.clone(),
                )?)
            }
            3 => {
                rate_limits =
                    serde_json::from_value::<AccountRateLimitsResponse>(result.clone()).ok();
                rate_limits_resolved = true;
            }
            _ => {}
        }
        if usage.is_some() && rate_limits_resolved {
            break;
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
    deadline: Instant,
    initializing: bool,
) -> Result<Value, AppServerError> {
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(timeout_error(initializing));
        }
        let line = lines
            .recv_timeout(remaining)
            .map_err(|error| match error {
                mpsc::RecvTimeoutError::Timeout => timeout_error(initializing),
                mpsc::RecvTimeoutError::Disconnected => AppServerError::Stopped(String::new()),
            })??;
        if !line.trim().is_empty() {
            return Ok(serde_json::from_str(&line)?);
        }
    }
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
    error
        .get("message")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .or_else(|| error.get("code").map(ToString::to_string))
        .unwrap_or_else(|| error.to_string())
}

fn clean_stderr(stderr: &str) -> String {
    let line = stderr
        .lines()
        .find(|line| !line.trim().is_empty())
        .unwrap_or(stderr)
        .trim();
    let mut clean: String = line.chars().take(237).collect();
    if line.chars().count() > 237 {
        clean.push_str("...");
    }
    clean
}

fn resolve_codex() -> Option<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(path) = env::var_os("CODEX_USAGE_BAR_CODEX_PATH") {
        candidates.push(expand_home(PathBuf::from(path)));
    }
    if let Some(path) = env::var_os("PATH") {
        candidates.extend(env::split_paths(&path).map(|directory| directory.join("codex")));
    }
    candidates.extend([
        PathBuf::from("/usr/bin/codex"),
        PathBuf::from("/usr/local/bin/codex"),
    ]);
    if let Some(home) = env::var_os("HOME").map(PathBuf::from) {
        candidates.push(home.join(".local/bin/codex"));
        candidates.push(home.join(".npm-global/bin/codex"));
    }

    let mut seen = HashSet::new();
    candidates
        .into_iter()
        .find(|path| seen.insert(path.clone()) && is_executable(path))
}

fn expand_home(path: PathBuf) -> PathBuf {
    let text = path.to_string_lossy();
    if text == "~" {
        return env::var_os("HOME").map(PathBuf::from).unwrap_or(path);
    }
    if let Some(rest) = text.strip_prefix("~/")
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

    fn run_fake_codex(script: &str, timeout: Duration) -> Result<UsageSnapshot, AppServerError> {
        let target = Path::new(env!("CARGO_MANIFEST_DIR")).join("target");
        fs::create_dir_all(&target).unwrap();
        let directory = tempfile::tempdir_in(target).unwrap();
        let executable = directory.path().join("codex");
        fs::write(&executable, script).unwrap();
        let mut permissions = fs::metadata(&executable).unwrap().permissions();
        permissions.set_mode(0o700);
        fs::set_permissions(&executable, permissions).unwrap();
        fetch_usage_snapshot_with_executable(&executable, timeout)
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
    fn malformed_rate_limits_do_not_discard_valid_usage() {
        let script = fake_codex_script(
            r#"    *'"id":3'*)
      printf '%s\n' '{"id":3,"result":"malformed"}'
      ;;"#,
        );
        let snapshot = run_fake_codex(&script, Duration::from_secs(1)).unwrap();
        assert_eq!(snapshot.buckets()[0].tokens, 7);
        assert!(snapshot.rate_limits.is_none());
    }

    #[test]
    fn missing_rate_limits_return_usage_at_the_deadline() {
        let script = fake_codex_script("");
        let snapshot = run_fake_codex(&script, Duration::from_millis(150)).unwrap();
        assert_eq!(snapshot.buckets()[0].tokens, 7);
        assert!(snapshot.rate_limits.is_none());
    }
}
