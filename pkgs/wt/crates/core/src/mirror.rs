use std::path::Path;

use anyhow::{Context, Result};

use crate::config::Config;

use crate::envrc;
use crate::util;
use crate::workspace::{self, Reproduce};

/// Lay out a session directory as a mirror of the workspace: every repo the
/// session does not own is a symlink to the main checkout, so sibling paths
/// (`../docs`, `use flake ../flake`) resolve exactly as they do outside.
pub fn build(cfg: &Config, session: &Path, members: &[String]) -> Result<()> {
    std::fs::create_dir_all(session)
        .with_context(|| format!("failed to create {}", session.display()))?;
    for entry in workspace::entries(cfg)? {
        let target = session.join(&entry.name);
        // Members are left for the worktree step, and the session's `.envrc` is
        // generated rather than copied.
        if entry.how == Reproduce::Repo && members.contains(&entry.name) {
            continue;
        }
        if entry.name == envrc::FILE {
            continue;
        }
        if util::exists(&target) {
            continue;
        }
        match entry.how {
            Reproduce::CopiedDotfile => copy_file(&entry.path, &target)?,
            Reproduce::Repo | Reproduce::Symlink => symlink(&entry.path, &target)?,
        }
    }
    Ok(())
}

pub fn symlink(target: &Path, link: &Path) -> Result<()> {
    std::os::unix::fs::symlink(target, link)
        .with_context(|| format!("failed to link {} -> {}", link.display(), target.display()))
}

fn copy_file(from: &Path, to: &Path) -> Result<()> {
    std::fs::copy(from, to)
        .with_context(|| format!("failed to copy {} to {}", from.display(), to.display()))?;
    Ok(())
}

/// Replace a repo's symlink with nothing, leaving the path free for a worktree.
/// Only ever unlinks — never touches what the link points at.
pub fn unlink_repo(session: &Path, repo: &str) -> Result<()> {
    let path = session.join(repo);
    if util::is_symlink(&path) {
        std::fs::remove_file(&path)
            .with_context(|| format!("failed to unlink {}", path.display()))?;
    }
    Ok(())
}

/// Point a repo back at the main checkout. The path is unchanged, so shell
/// cwds, nvim sessions and Claude project dirs stay valid.
pub fn relink_repo(cfg: &Config, session: &Path, repo: &str) -> Result<()> {
    let path = session.join(repo);
    if util::exists(&path) {
        anyhow::ensure!(
            util::is_symlink(&path),
            "{} still exists and is not a symlink",
            path.display()
        );
        return Ok(());
    }
    let target = cfg.workspace.join(repo);
    // A link to a target that is not there would be worse than the hole it fills:
    // it reads as a mirrored repo everywhere, and resolves nowhere.
    anyhow::ensure!(
        util::exists(&target),
        "{} does not exist, so `{repo}` cannot be linked into the mirror",
        target.display()
    );
    symlink(&target, &path)
}
