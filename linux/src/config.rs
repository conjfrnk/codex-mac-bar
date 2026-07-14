use std::env;
use std::ffi::OsString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use serde::{Deserialize, Serialize};

use crate::range::Timeframe;

const MAXIMUM_PREFERENCES_BYTES: u64 = 64 * 1024;
const O_NONBLOCK: i32 = 0o4000;
#[cfg(any(
    target_arch = "aarch64",
    target_arch = "arm",
    target_arch = "m68k",
    target_arch = "powerpc",
    target_arch = "powerpc64"
))]
const O_NOFOLLOW: i32 = 0o100000;
#[cfg(not(any(
    target_arch = "aarch64",
    target_arch = "arm",
    target_arch = "m68k",
    target_arch = "powerpc",
    target_arch = "powerpc64"
)))]
const O_NOFOLLOW: i32 = 0o400000;
static TEMPORARY_FILE_COUNTER: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize)]
pub struct Preferences {
    #[serde(default)]
    pub timeframe: Timeframe,
}

impl Preferences {
    pub fn load() -> Self {
        preferences_path()
            .and_then(|path| Self::load_from(&path))
            .unwrap_or_default()
    }

    pub fn save(self) -> io::Result<()> {
        self.save_to(&preferences_path()?)
    }

    fn load_from(path: &Path) -> io::Result<Self> {
        let content = read_regular_file_bounded(path, MAXIMUM_PREFERENCES_BYTES)?;
        serde_json::from_slice(&content)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
    }

    fn save_to(self, path: &Path) -> io::Result<()> {
        let content = serde_json::to_vec_pretty(&self).map_err(io::Error::other)?;
        atomic_write(path, &content, 0o600)
    }
}

pub fn config_home() -> io::Result<PathBuf> {
    config_home_from(env::var_os("XDG_CONFIG_HOME"), env::var_os("HOME"))
}

fn preferences_path() -> io::Result<PathBuf> {
    Ok(config_home()?.join("codex-usage-bar/config.json"))
}

fn config_home_from(xdg: Option<OsString>, home: Option<OsString>) -> io::Result<PathBuf> {
    if let Some(path) = xdg.filter(|value| !value.is_empty()).map(PathBuf::from)
        && path.is_absolute()
    {
        return Ok(path);
    }
    if let Some(path) = home.filter(|value| !value.is_empty()).map(PathBuf::from)
        && path.is_absolute()
    {
        return Ok(path.join(".config"));
    }
    Err(io::Error::new(
        io::ErrorKind::NotFound,
        "could not determine an absolute configuration directory from XDG_CONFIG_HOME or HOME",
    ))
}

pub(crate) fn read_regular_file_bounded(path: &Path, maximum: u64) -> io::Result<Vec<u8>> {
    // Configuration paths must not hang startup by pointing at a FIFO/device,
    // nor should they silently follow a symlink elsewhere.
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(O_NONBLOCK | O_NOFOLLOW)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "configuration path is not a regular file",
        ));
    }
    if metadata.len() > maximum {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "configuration file is too large",
        ));
    }
    let mut content = Vec::new();
    file.take(maximum.saturating_add(1))
        .read_to_end(&mut content)?;
    if content.len() as u64 > maximum {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "configuration file is too large",
        ));
    }
    Ok(content)
}

pub(crate) fn atomic_write(path: &Path, content: &[u8], mode: u32) -> io::Result<()> {
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "destination has no parent directory",
        )
    })?;
    fs::create_dir_all(parent)?;

    let file_name = path.file_name().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "destination has no file name")
    })?;
    let mut temporary_file = None;
    for _ in 0..128 {
        let counter = TEMPORARY_FILE_COUNTER.fetch_add(1, Ordering::Relaxed);
        let temporary = parent.join(format!(
            ".{}.tmp-{}-{counter}",
            file_name.to_string_lossy(),
            std::process::id()
        ));
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(mode)
            .open(&temporary)
        {
            Ok(file) => {
                temporary_file = Some((temporary, file));
                break;
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        }
    }
    let (temporary, mut file) = temporary_file.ok_or_else(|| {
        io::Error::new(io::ErrorKind::AlreadyExists, "no temporary name available")
    })?;
    let write_result = (|| {
        file.write_all(content)?;
        file.sync_all()?;
        fs::rename(&temporary, path)?;
        sync_directory(parent)
    })();
    if write_result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    write_result
}

pub(crate) fn sync_directory(path: &Path) -> io::Result<()> {
    File::open(path)?.sync_all()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};

    #[test]
    fn preferences_round_trip() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.json");
        Preferences {
            timeframe: Timeframe::Ninety,
        }
        .save_to(&path)
        .unwrap();
        assert_eq!(
            Preferences::load_from(&path).unwrap().timeframe,
            Timeframe::Ninety
        );
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    #[test]
    fn ignores_relative_xdg_and_home_paths() {
        assert_eq!(
            config_home_from(Some("relative".into()), Some("/home/example".into())).unwrap(),
            PathBuf::from("/home/example/.config")
        );
        assert_eq!(
            config_home_from(Some("/xdg".into()), Some("/home/example".into())).unwrap(),
            PathBuf::from("/xdg")
        );
        assert_eq!(
            config_home_from(Some("relative".into()), Some("also-relative".into()))
                .unwrap_err()
                .kind(),
            io::ErrorKind::NotFound
        );
        assert_eq!(
            config_home_from(None, None).unwrap_err().kind(),
            io::ErrorKind::NotFound
        );
    }

    #[test]
    fn rejects_oversized_preferences_without_reading_them_unboundedly() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.json");
        fs::write(&path, vec![b' '; MAXIMUM_PREFERENCES_BYTES as usize + 1]).unwrap();
        let error = Preferences::load_from(&path).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn rejects_invalid_timeframe_values() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.json");
        fs::write(&path, br#"{"timeframe":42}"#).unwrap();
        assert_eq!(
            Preferences::load_from(&path).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
    }

    #[test]
    fn does_not_follow_preferences_symlinks() {
        let directory = tempfile::tempdir().unwrap();
        let victim = directory.path().join("victim.json");
        let path = directory.path().join("config.json");
        fs::write(&victim, br#"{"timeframe":"seven"}"#).unwrap();
        symlink(&victim, &path).unwrap();
        assert!(Preferences::load_from(&path).is_err());
    }

    #[test]
    fn atomic_save_replaces_a_symlink_without_following_it() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.json");
        let victim = directory.path().join("victim");
        fs::write(&victim, b"do not replace").unwrap();
        symlink(&victim, &path).unwrap();

        Preferences {
            timeframe: Timeframe::Seven,
        }
        .save_to(&path)
        .unwrap();

        assert_eq!(fs::read(&victim).unwrap(), b"do not replace");
        assert_eq!(
            Preferences::load_from(&path).unwrap().timeframe,
            Timeframe::Seven
        );
        assert!(fs::symlink_metadata(&path).unwrap().file_type().is_file());
    }
}
