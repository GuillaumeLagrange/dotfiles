use std::path::Path;

use anyhow::{Context, Result};

use crate::util::{capture, which};
use crate::{envrc, git, util};

#[derive(Debug, Default)]
pub struct Report {
    pub copied: Vec<String>,
    pub failed: Vec<(String, String)>,
    pub direnv_allowed: bool,
    pub envrc_linked: bool,
}

/// A git-ignored path that carries environment rather than build output: what a
/// worktree is unusable without.
fn is_environment(path: &str) -> bool {
    let base = path.rsplit('/').next().unwrap_or(path);
    base == ".envrc"
        || base == ".nvim.lua"
        || base == ".taplo.toml"
        || base == "Session.vim"
        || base.starts_with(".env")
        || path.ends_with(".claude/settings.local.json")
}

/// Containers whose contents belong to other checkouts, not to this one.
fn is_excluded(path: &str) -> bool {
    path == ".git"
        || path.starts_with(".git/")
        || path == ".worktrees"
        || path.starts_with(".worktrees/")
}

/// Copy a worktree's environment from the main checkout, then let direnv run
/// there.
///
/// `git worktree add` brings no ignored file, which on a globally-gitignored
/// `.envrc` means the flake environment is silently missing.
pub fn hydrate(main: &Path, worktree: &Path) -> Result<Report> {
    let mut report = Report::default();

    let ignored = git::ignored_paths(main)
        .with_context(|| format!("failed to list ignored paths in {}", main.display()))?;

    for rel in ignored {
        if is_excluded(&rel) {
            continue;
        }
        if !is_environment(&rel) {
            continue;
        }
        let src = main.join(&rel);
        let dst = worktree.join(&rel);
        if util::exists(&dst) || !util::exists(&src) {
            continue;
        }
        if let Some(parent) = dst.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("failed to create {}", parent.display()))?;
        }
        let out = capture(
            "cp",
            &[
                "-a".as_ref(),
                "--reflink=auto".as_ref(),
                "-T".as_ref(),
                src.as_os_str(),
                dst.as_os_str(),
            ],
            None,
        )?;
        if out.ok() {
            report.copied.push(rel);
        } else {
            report.failed.push((rel, out.stderr.trim().to_string()));
        }
    }

    // Before direnv is allowed below, since its approval covers the contents.
    match envrc::link_member(worktree) {
        Ok(linked) => report.envrc_linked = linked,
        Err(err) => report.failed.push((envrc::FILE.into(), err.to_string())),
    }

    match allow_direnv(worktree) {
        Ok(allowed) => report.direnv_allowed = allowed,
        Err(err) => report.failed.push((envrc::FILE.into(), err.to_string())),
    }

    Ok(report)
}

/// Let direnv load the `.envrc` at `path`. Its allow list is keyed on the path,
/// so every new directory needs this once.
pub fn allow_direnv(path: &Path) -> Result<bool> {
    if !path.join(".envrc").exists() || which("direnv").is_none() {
        return Ok(false);
    }
    let out = capture("direnv", &["allow".as_ref(), path.as_os_str()], None)?;
    if !out.ok() {
        anyhow::bail!("{}", out.stderr.trim());
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn environment_files_are_recognised() {
        assert!(is_environment(".envrc"));
        assert!(is_environment("apps/api/.env"));
        assert!(is_environment("apps/api/.env.local"));
        assert!(is_environment(".claude/settings.local.json"));
        assert!(!is_environment("node_modules"));
        assert!(!is_environment("target"));
    }

    #[test]
    fn git_internals_are_excluded() {
        assert!(is_excluded(".git"));
        assert!(is_excluded(".worktrees/proj-9"));
        assert!(!is_excluded("target"));
    }
}
