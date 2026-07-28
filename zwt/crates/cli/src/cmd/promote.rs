use anyhow::Result;

use zwt_core::config::Config;
use zwt_core::git;
use zwt_core::registry::Registry;
use zwt_core::session::RepoState;
use zwt_core::{mirror, workspace};

use crate::cmd;

/// Drop a member's worktree and move the main checkout onto its branch. The
/// session keeps working through the symlink that replaces it.
pub fn run(cfg: &Config, repo: &str, session_id: Option<&str>) -> Result<()> {
    let (reg, _) = Registry::open(cfg)?;
    let session = cmd::target_session(&reg, session_id)?;
    let repo_path = workspace::repo_path(cfg, repo)?;

    anyhow::ensure!(
        session.repo_state(repo) == RepoState::Worktree,
        "`{repo}` is not a member of {}",
        session.id
    );

    let worktree = session.path.join(repo);
    let branch = git::current_branch(&worktree)
        .ok_or_else(|| anyhow::anyhow!("{repo} is on a detached HEAD; nothing to promote"))?;

    // Both sides must be clean: the worktree because removing it discards
    // whatever is uncommitted, the main checkout because it is about to move.
    anyhow::ensure!(
        !git::is_dirty(&worktree),
        "{} has uncommitted changes; commit or stash them first",
        worktree.display()
    );
    let main = git::main_worktree(&repo_path)?;
    anyhow::ensure!(
        !git::is_dirty(&main),
        "{} has uncommitted changes; commit or stash them first",
        main.display()
    );

    git::remove_worktree(&repo_path, &worktree, false)?;
    git::switch_branch(&main, &branch)?;
    mirror::relink_repo(cfg, &session.path, repo)?;

    println!("{repo}: {} is now the checkout on {branch}", main.display());
    Ok(())
}
