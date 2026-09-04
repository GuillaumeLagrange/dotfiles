use std::path::PathBuf;

use anyhow::{Context, Result};

use crate::config::Config;
use crate::git;

/// How a workspace entry is reproduced inside a session mirror.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reproduce {
    /// Repos: a symlink until they join the session, then a real worktree.
    Repo,
    /// The workspace's own dotfiles, copied so the session owns them.
    CopiedDotfile,
    Symlink,
}

#[derive(Debug, Clone)]
pub struct Entry {
    pub name: String,
    pub path: PathBuf,
    pub how: Reproduce,
}

/// Entries a session mirror is built from. `.direnv` is skipped because it caches
/// paths, and `.git` because a session is not a checkout of the workspace.
pub fn entries(cfg: &Config) -> Result<Vec<Entry>> {
    let mut out = Vec::new();
    let dir = std::fs::read_dir(&cfg.workspace)
        .with_context(|| format!("failed to read workspace {}", cfg.workspace.display()))?;
    for entry in dir {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if name == ".git" || name == ".direnv" {
            continue;
        }
        let path = entry.path();
        if cfg.is_sessions_root(&path) {
            continue;
        }
        let how = if git::is_repo(&path) {
            Reproduce::Repo
        } else if name.starts_with('.') && path.is_file() {
            Reproduce::CopiedDotfile
        } else {
            Reproduce::Symlink
        };
        out.push(Entry { name, path, how });
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(out)
}

pub fn repos(cfg: &Config) -> Result<Vec<Entry>> {
    Ok(entries(cfg)?
        .into_iter()
        .filter(|e| e.how == Reproduce::Repo)
        .collect())
}

pub fn repo_names(cfg: &Config) -> Result<Vec<String>> {
    Ok(repos(cfg)?.into_iter().map(|e| e.name).collect())
}

/// Repos a session may take as members: the configured list, restricted to the
/// ones actually cloned, else every repo in the workspace.
pub fn selectable(cfg: &Config) -> Result<Vec<String>> {
    let present = repo_names(cfg)?;
    if cfg.repos.is_empty() {
        return Ok(present);
    }
    Ok(cfg
        .repos
        .iter()
        .filter(|name| present.contains(name))
        .cloned()
        .collect())
}

pub fn repo_path(cfg: &Config, repo: &str) -> Result<PathBuf> {
    let path = cfg.workspace.join(repo);
    anyhow::ensure!(
        git::is_repo(&path),
        "{} is not a git repo in {}",
        repo,
        cfg.workspace.display()
    );
    Ok(path)
}
