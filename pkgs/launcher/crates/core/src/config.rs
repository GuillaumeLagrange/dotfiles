//! The config Nix writes: what runs a command in a terminal, and one section per enabled mode.
//! A mode without a section is disabled.

use std::collections::BTreeMap;
use std::path::Path;

use anyhow::{Context, Result};
use serde::de::DeserializeOwned;
use serde::Deserialize;

use crate::source::Mode;

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Config {
    /// The argv prefix that runs a command in a new terminal window.
    #[serde(default)]
    pub terminal: Vec<String>,
    #[serde(default)]
    pub modes: BTreeMap<Mode, serde_json::Value>,
}

impl Config {
    pub fn load(path: &Path) -> Result<Config> {
        let text =
            std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        serde_json::from_str(&text).with_context(|| format!("parsing {}", path.display()))
    }

    pub fn enabled(&self, mode: Mode) -> bool {
        self.modes.contains_key(&mode)
    }

    /// A mode's section, or its default when absent or null.
    pub fn section<T: DeserializeOwned + Default>(&self, mode: Mode) -> Result<T> {
        match self.modes.get(&mode) {
            None | Some(serde_json::Value::Null) => Ok(T::default()),
            Some(value) => serde_json::from_value(value.clone())
                .with_context(|| format!("config section {}", mode.name())),
        }
    }

    /// Every mode enabled with an empty section, for tests.
    pub fn with_modes(modes: &[Mode]) -> Config {
        Config {
            terminal: vec!["xdg-terminal-exec".into()],
            modes: modes
                .iter()
                .map(|m| (*m, serde_json::Value::Null))
                .collect(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug, Default, Deserialize, PartialEq)]
    struct Section {
        limit: u32,
    }

    #[test]
    fn a_mode_is_enabled_by_its_section() {
        let config: Config = serde_json::from_str(
            r#"{"terminal":["kitty"],"modes":{"apps":null,"clipboard":{"limit":3}}}"#,
        )
        .unwrap();
        assert!(config.enabled(Mode::Apps));
        assert!(config.enabled(Mode::Clipboard));
        assert!(!config.enabled(Mode::Files));
        assert_eq!(
            config.section::<Section>(Mode::Clipboard).unwrap(),
            Section { limit: 3 }
        );
        assert_eq!(
            config.section::<Section>(Mode::Apps).unwrap(),
            Section::default()
        );
    }
}
