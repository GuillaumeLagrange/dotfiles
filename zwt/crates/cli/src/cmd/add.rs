use anyhow::Result;

use zwt_core::config::Config;
use zwt_core::registry::Registry;
use zwt_core::session::RepoState;
use zwt_core::{mirror, workspace};

use crate::cmd;

/// Swap a repo's symlink for a detached worktree, in place.
pub fn run(cfg: &Config, repo: &str, session_id: Option<&str>) -> Result<()> {
    let (reg, _) = Registry::open(cfg)?;
    let session = cmd::target_session(&reg, session_id)?;
    // Before the mirror is touched: nothing below should run for a name the
    // workspace has no repo for.
    workspace::repo_path(cfg, repo)?;

    match session.repo_state(repo) {
        RepoState::Worktree => anyhow::bail!("`{repo}` is already a member of {}", session.id),
        RepoState::Linked | RepoState::Absent => {}
    }

    mirror::unlink_repo(&session.path, repo)?;
    // Put the symlink back rather than leaving a hole in the mirror.
    cmd::new::check_out(cfg, &session.path, repo).inspect_err(|_| {
        let _ = mirror::relink_repo(cfg, &session.path, repo);
    })?;

    println!("{repo} joined {}", session.id);
    Ok(())
}
