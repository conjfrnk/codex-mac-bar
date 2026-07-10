use std::env;
use std::fs;
use std::io;
use std::path::PathBuf;

use crate::config::config_home;

const FILE_NAME: &str = "io.github.conjfrnk.CodexUsageBar.desktop";

pub fn is_enabled() -> bool {
    autostart_path().is_file()
}

pub fn set_enabled(enabled: bool) -> io::Result<()> {
    let path = autostart_path();
    if !enabled {
        return match fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error),
        };
    }

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let executable = env::current_exe()?;
    let entry = format!(
        "[Desktop Entry]\nType=Application\nName=Codex Usage Bar\nComment=Show Codex usage and rate limits\nExec={} --background\nIcon=codex-usage-bar\nTerminal=false\nCategories=Utility;\nX-GNOME-Autostart-enabled=true\n",
        quote_exec(executable.to_string_lossy().as_ref())
    );
    fs::write(path, entry)
}

fn autostart_path() -> PathBuf {
    config_home().join("autostart").join(FILE_NAME)
}

fn quote_exec(value: &str) -> String {
    let escaped = value
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('`', "\\`")
        .replace('$', "\\$");
    format!("\"{escaped}\"")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quotes_desktop_exec_values() {
        assert_eq!(quote_exec("/tmp/a b/$app"), r#""/tmp/a b/\$app""#);
    }
}
