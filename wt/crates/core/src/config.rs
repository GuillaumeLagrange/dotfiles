use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::Deserialize;

use crate::util;

#[derive(Debug, Clone)]
pub struct Config {
    /// The real multi-repo checkout every session mirrors.
    pub workspace: PathBuf,
    /// Where `wt new` puts a session unless `--at` says otherwise.
    pub default_root: PathBuf,
    /// Repos a session may take as members. Empty offers every repo the workspace
    /// holds instead of a curated subset.
    pub repos: Vec<String>,
    /// Which git-ignored paths a fresh worktree is unusable without, as patterns
    /// (see `hydrate`). Which files those are is a property of a codebase, not of
    /// wt.
    pub hydrate: Vec<String>,
    pub state_dir: PathBuf,
}

/// The environment files a worktree needs when the config names none: enough to
/// make direnv, an editor and Claude behave as they do in the main checkout.
const DEFAULT_HYDRATE: &[&str] = &[
    ".envrc",
    ".env*",
    ".nvim.lua",
    ".taplo.toml",
    ".claude/settings.local.json",
];

/// `~/.config/wt/config.toml`, all keys optional.
#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct File {
    workspace: Option<String>,
    default_root: Option<String>,
    #[serde(default)]
    repos: Vec<String>,
    hydrate: Option<Vec<String>>,
}

impl Config {
    pub fn load() -> Result<Self> {
        let path = Self::config_path();
        let file: File = match std::fs::read_to_string(&path) {
            Ok(raw) => {
                toml::from_str(&raw).with_context(|| format!("invalid {}", path.display()))?
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => File::default(),
            Err(e) => return Err(e).context(format!("failed to read {}", path.display())),
        };

        // `WORKSPACE_ROOT` is deliberately not consulted: inside a session it
        // points at the mirror, not at the checkout the mirror was built from.
        let workspace = std::env::var("WT_WORKSPACE")
            .ok()
            .or(file.workspace)
            .map(|s| util::expand_tilde(&s))
            .with_context(|| {
                format!(
                    "no workspace to mirror: set `workspace` in {} or $WT_WORKSPACE",
                    path.display()
                )
            })?;

        let default_root = file
            .default_root
            .map(|s| util::expand_tilde(&s))
            .unwrap_or_else(|| workspace.join("sessions"));

        // An empty list is taken at its word — a workspace whose repos need nothing
        // carried is a valid answer, and silently substituting the defaults for it
        // would not be.
        let hydrate = file
            .hydrate
            .unwrap_or_else(|| DEFAULT_HYDRATE.iter().map(|s| s.to_string()).collect());

        Ok(Self {
            workspace,
            default_root,
            repos: file.repos,
            hydrate,
            state_dir: util::xdg_dir("XDG_STATE_HOME", ".local/state").join("wt"),
        })
    }

    pub fn config_path() -> PathBuf {
        util::xdg_dir("XDG_CONFIG_HOME", ".config")
            .join("wt")
            .join("config.toml")
    }

    pub fn registry_path(&self) -> PathBuf {
        self.state_dir.join("sessions.json")
    }

    /// Where a session with this id lands by default.
    pub fn session_path(&self, id: &str) -> PathBuf {
        self.default_root.join(id)
    }

    /// True for the entry the mirror must never recurse into: the sessions root
    /// itself, when it lives inside the workspace.
    pub fn is_sessions_root(&self, path: &Path) -> bool {
        self.default_root == path
    }
}
