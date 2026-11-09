use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use crate::config::Config;
use crate::util;

/// What nothing else on the machine knows. Members and branches are read from
/// `git worktree list` instead, so they cannot go stale.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Entry {
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
}

impl Entry {
    pub fn resolved_path(&self) -> PathBuf {
        util::expand_tilde(&self.path)
    }
}

#[derive(Debug, Default)]
pub struct Registry {
    path: PathBuf,
    pub sessions: BTreeMap<String, Entry>,
}

impl Registry {
    /// Read the registry as stored, keeping entries whose directory is gone.
    pub fn open_raw(cfg: &Config) -> Result<Self> {
        let path = cfg.registry_path();
        let sessions = match std::fs::read_to_string(&path) {
            Ok(raw) if raw.trim().is_empty() => BTreeMap::new(),
            Ok(raw) => serde_json::from_str(&raw)
                .with_context(|| format!("failed to parse {}", path.display()))?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => BTreeMap::new(),
            Err(e) => return Err(e).context(format!("failed to read {}", path.display())),
        };
        Ok(Self { path, sessions })
    }

    /// Read the registry, dropping entries whose directory no longer exists —
    /// the only drift the registry can accumulate.
    pub fn open(cfg: &Config) -> Result<(Self, Vec<String>)> {
        let mut reg = Self::open_raw(cfg)?;
        let gone: Vec<String> = reg
            .sessions
            .iter()
            .filter(|(_, e)| !e.resolved_path().is_dir())
            .map(|(id, _)| id.clone())
            .collect();
        if !gone.is_empty() {
            for id in &gone {
                reg.sessions.remove(id);
            }
            reg.save()?;
        }
        Ok((reg, gone))
    }

    pub fn save(&self) -> Result<()> {
        let json = serde_json::to_string_pretty(&self.sessions)?;
        util::write_atomic(&self.path, &format!("{json}\n"))
    }

    pub fn insert(&mut self, id: &str, path: &Path, title: Option<String>) {
        self.sessions.insert(
            id.to_string(),
            Entry {
                path: util::contract_tilde(path),
                title,
            },
        );
    }

    pub fn get(&self, id: &str) -> Option<&Entry> {
        self.sessions.get(id)
    }

    pub fn remove(&mut self, id: &str) -> Option<Entry> {
        self.sessions.remove(id)
    }

    /// The session whose directory contains `path`.
    pub fn containing(&self, path: &Path) -> Option<(&String, &Entry)> {
        let path = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
        self.sessions.iter().find(|(_, e)| {
            let root = e.resolved_path();
            let root = std::fs::canonicalize(&root).unwrap_or(root);
            path.starts_with(&root)
        })
    }
}
