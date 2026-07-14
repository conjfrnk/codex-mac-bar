use std::env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use crate::config::{atomic_write, config_home, read_regular_file_bounded, sync_directory};

const FILE_NAME: &str = "io.github.conjfrnk.CodexUsageBar.desktop";
const MAXIMUM_AUTOSTART_BYTES: u64 = 16 * 1024;

pub fn is_enabled() -> bool {
    let Ok(executable) = current_executable() else {
        return false;
    };
    autostart_path().is_ok_and(|path| is_enabled_at(&path, &executable))
}

pub fn set_enabled(enabled: bool) -> io::Result<()> {
    let path = autostart_path()?;
    if !enabled {
        return match fs::remove_file(&path) {
            Ok(()) => path.parent().map(sync_directory).unwrap_or(Ok(())),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error),
        };
    }

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let executable = current_executable()?;
    let entry = autostart_entry(&executable)?;
    atomic_write(&path, entry.as_bytes(), 0o600)
}

fn autostart_path() -> io::Result<PathBuf> {
    Ok(config_home()?.join("autostart").join(FILE_NAME))
}

fn autostart_entry(executable: &str) -> io::Result<String> {
    Ok(format!(
        "[Desktop Entry]\nType=Application\nName=Codex Usage Bar\nComment=Show Codex usage and rate limits\nExec={} --background\nIcon=codex-usage-bar\nTerminal=false\nCategories=Utility;\nX-GNOME-Autostart-enabled=true\n",
        quote_exec(executable)?
    ))
}

fn current_executable() -> io::Result<String> {
    let executable = env::current_exe()?;
    if !executable.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "the executable path is not absolute",
        ));
    }
    executable.into_os_string().into_string().map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "the executable path is not valid UTF-8",
        )
    })
}

fn is_enabled_at(path: &Path, expected_executable: &str) -> bool {
    let Ok(content) = read_regular_file_bounded(path, MAXIMUM_AUTOSTART_BYTES) else {
        return false;
    };
    let Ok(content) = std::str::from_utf8(&content) else {
        return false;
    };
    desktop_entry_is_enabled(content, expected_executable)
}

fn desktop_entry_is_enabled(content: &str, expected_executable: &str) -> bool {
    let Ok(expected_exec) =
        quote_exec(expected_executable).map(|executable| format!("{executable} --background"))
    else {
        return false;
    };
    let mut in_desktop_entry = false;
    let mut found_desktop_entry = false;
    let mut application_type = false;
    let mut background_exec = false;
    let mut found_type = false;
    let mut found_exec = false;

    for raw_line in content.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line.starts_with('[') && line.ends_with(']') {
            if line == "[Desktop Entry]" {
                if found_desktop_entry {
                    return false;
                }
                found_desktop_entry = true;
                in_desktop_entry = true;
            } else {
                in_desktop_entry = false;
            }
            continue;
        }
        if !in_desktop_entry {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            return false;
        };
        let key = key.trim();
        let value = value.trim();
        match key {
            "Type" => {
                if found_type {
                    return false;
                }
                found_type = true;
                application_type = value == "Application";
            }
            "Exec" => {
                if found_exec {
                    return false;
                }
                found_exec = true;
                // Compare the serialized Exec value we generate, not a shell-
                // like approximation. This rejects alternate executables,
                // extra arguments, field-code substitutions, and ambiguous
                // quoting while accepting every path emitted by quote_exec.
                background_exec = value == expected_exec;
            }
            "Hidden" if value.eq_ignore_ascii_case("true") => return false,
            "X-GNOME-Autostart-enabled" if value.eq_ignore_ascii_case("false") => return false,
            _ => {}
        }
    }
    found_desktop_entry && found_type && application_type && found_exec && background_exec
}

fn quote_exec(value: &str) -> io::Result<String> {
    if value.chars().any(char::is_control) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "desktop Exec paths cannot contain control characters",
        ));
    }
    // Desktop-entry string escaping runs before Exec argument unquoting. The
    // quoting backslash therefore also has to be escaped at the string layer.
    // Literal percent signs must be doubled so they cannot become field codes.
    let escaped = value
        .replace('\\', "\\\\\\\\")
        .replace('"', "\\\\\"")
        .replace('`', "\\\\`")
        .replace('$', "\\\\$")
        .replace('%', "%%");
    Ok(format!("\"{escaped}\""))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quotes_desktop_exec_values() {
        assert_eq!(
            quote_exec(r#"/tmp/a b/$app\100%"#).unwrap(),
            r#""/tmp/a b/\\$app\\\\100%%""#
        );
        assert_eq!(quote_exec("\"`").unwrap().as_bytes(), b"\"\\\\\"\\\\`\"");
    }

    #[test]
    fn rejects_control_characters_in_desktop_exec_values() {
        assert_eq!(
            quote_exec("/tmp/app\nHidden=true").unwrap_err().kind(),
            io::ErrorKind::InvalidInput
        );
    }

    #[test]
    fn validates_owned_enabled_autostart_entries() {
        let expected = "/opt/Codex Usage/$codex%bar\\bin";
        let entry = autostart_entry(expected).unwrap();
        assert!(desktop_entry_is_enabled(&entry, expected));
        assert!(!desktop_entry_is_enabled(
            &entry,
            "/opt/other/codex-usage-bar"
        ));
        assert!(!desktop_entry_is_enabled("", expected));
        assert!(!desktop_entry_is_enabled(
            "[Desktop Entry]\nType=Link\nExec=codex-usage-bar --background\n",
            expected,
        ));
        assert!(!desktop_entry_is_enabled(
            "[Desktop Entry]\nType=Application\nExec=codex-usage-bar --show\n",
            expected,
        ));
        assert!(!desktop_entry_is_enabled(
            &format!("{entry}Hidden=true\n"),
            expected
        ));
        assert!(!desktop_entry_is_enabled(
            &format!("{entry}X-GNOME-Autostart-enabled=false\n"),
            expected
        ));
        assert!(!desktop_entry_is_enabled(
            &format!(
                "{entry}Exec={} --background\n",
                quote_exec(expected).unwrap()
            ),
            expected,
        ));
        assert!(!desktop_entry_is_enabled(
            "[Desktop Entry]\nType=Application\nExec=\"/tmp/attacker\" --background\n",
            expected,
        ));
    }

    #[test]
    fn enabled_check_rejects_invalid_large_and_symlink_entries() {
        use std::os::unix::fs::symlink;

        let directory = tempfile::tempdir().unwrap();
        let valid = directory.path().join("valid.desktop");
        let expected = "/usr/bin/codex-usage-bar";
        fs::write(&valid, autostart_entry(expected).unwrap()).unwrap();
        assert!(is_enabled_at(&valid, expected));
        assert!(!is_enabled_at(&valid, "/usr/local/bin/codex-usage-bar"));

        let invalid = directory.path().join("invalid.desktop");
        fs::write(&invalid, "[Desktop Entry]\nHidden=true\n").unwrap();
        assert!(!is_enabled_at(&invalid, expected));

        let large = directory.path().join("large.desktop");
        fs::write(&large, vec![b'x'; MAXIMUM_AUTOSTART_BYTES as usize + 1]).unwrap();
        assert!(!is_enabled_at(&large, expected));

        let linked = directory.path().join("linked.desktop");
        symlink(&valid, &linked).unwrap();
        assert!(!is_enabled_at(&linked, expected));
    }
}
