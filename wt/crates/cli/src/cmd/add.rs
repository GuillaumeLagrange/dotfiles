use anyhow::Result;

use wt_core::config::Config;
use wt_core::registry::Registry;
use wt_core::session::RepoState;
use wt_core::{mirror, workspace, zellij};

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

    // Best effort, and only for a session a client is on: a tab added to a
    // client-less server comes up with no pane in it (see `zellij::has_client`),
    // and attaching lays out the missing ones anyway. Either way a tab is not
    // worth failing an `add` that has already produced the worktree.
    if zellij::available() && zellij::has_client(&session.id).unwrap_or(false) {
        if let Err(err) = zellij::new_tab(&session.id, &session.path.join(repo), repo) {
            eprintln!("wt: {err:#}");
        }
    }
    Ok(())
}
