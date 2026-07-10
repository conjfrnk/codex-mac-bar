use std::env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::range::Timeframe;

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize)]
pub struct Preferences {
    #[serde(default)]
    pub timeframe: Timeframe,
}

impl Preferences {
    pub fn load() -> Self {
        Self::load_from(&preferences_path()).unwrap_or_default()
    }

    pub fn save(self) -> io::Result<()> {
        self.save_to(&preferences_path())
    }

    fn load_from(path: &Path) -> io::Result<Self> {
        let content = fs::read(path)?;
        serde_json::from_slice(&content).map_err(io::Error::other)
    }

    fn save_to(self, path: &Path) -> io::Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let temporary = path.with_extension("json.tmp");
        fs::write(
            &temporary,
            serde_json::to_vec_pretty(&self).map_err(io::Error::other)?,
        )?;
        fs::rename(temporary, path)
    }
}

pub fn config_home() -> PathBuf {
    env::var_os("XDG_CONFIG_HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
        .unwrap_or_else(|| PathBuf::from(".config"))
}

fn preferences_path() -> PathBuf {
    config_home().join("codex-usage-bar/config.json")
}

#[cfg(test)]
mod tests {
    use super::*;

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
    }
}
