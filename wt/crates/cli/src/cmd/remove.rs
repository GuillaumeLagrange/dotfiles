use anyhow::Result;

use wt_core::config::Config;
use wt_core::git;
use wt_core::registry::Registry;
use wt_core::session::Session;
use wt_core::workspace;

use crate::cmd;
use crate::ui::{self, Choice};

/// Tear a session down. Guarded, because the worktrees are the only copy of
/// whatever has not been pushed.
pub fn run(cfg: &Config, id: Option<&str>, force: bool) -> Result<()> {
    let (mut reg, _) = Registry::open(cfg)?;
    let id = match id {
        Some(needle) => cmd::resolve_id(&reg, needle)?,
        None => {
            let choices: Vec<Choice> = reg
                .sessions
                .iter()
                .map(|(id, e)| {
                    Choice::new(
                        id.clone(),
                        format!("{id:<16} {}", e.resolved_path().display()),
                    )
                })
                .collect();
            ui::pick_one(&choices, "remove>")?.ok_or_else(|| anyhow::anyhow!("nothing picked"))?
        }
    };
    let session = Session::from_registry(&reg, &id)?;

    let held = work_at_risk(cfg, &session)?;
    if !held.is_empty() {
        for line in &held {
            eprintln!("  {line}");
        }
        anyhow::ensure!(force, "{id} still holds work; --force removes it anyway");
    }

    if !force && ui::interactive() {
        let members = session.members()?.len();
        anyhow::ensure!(
            ui::confirm(
                &format!("remove {id} and its {members} worktree(s)?"),
                false
            )?,
            "cancelled"
        );
    }

    teardown_worktrees(cfg, &session, force)?;

    if session.path.is_dir() {
        // Unlinks symlinks instead of walking into them: the mirror points at the
        // main checkouts, and following those links would delete the workspace.
        std::fs::remove_dir_all(&session.path)?;
    }

    reg.remove(&id);
    reg.save()?;
    println!("removed {id}");
    Ok(())
}

/// Everything that would be lost: uncommitted changes, commits no remote has, and
/// stashes taken on a member's branch.
fn work_at_risk(cfg: &Config, session: &Session) -> Result<Vec<String>> {
    let mut held = Vec::new();
    for member in session.members()? {
        if git::is_dirty(&member.path) {
            held.push(format!("{}: uncommitted changes", member.repo));
        }
        let ahead = git::unpushed(&member.path);
        if ahead > 0 {
            held.push(format!(
                "{}: {ahead} commit{} no remote has",
                member.repo,
                if ahead == 1 { "" } else { "s" }
            ));
        }
        if let Some(branch) = &member.branch {
            let repo_path = cfg.workspace.join(&member.repo);
            let stashes = git::stashes_for_branch(&repo_path, branch);
            if stashes > 0 {
                held.push(format!(
                    "{}: {stashes} stash{} on {branch}",
                    member.repo,
                    if stashes == 1 { "" } else { "es" }
                ));
            }
        }
    }
    Ok(held)
}

/// Deregister every worktree pointing into the session, going by what git records
/// rather than what is on disk so nothing is left dangling.
fn teardown_worktrees(cfg: &Config, session: &Session, force: bool) -> Result<()> {
    for repo in workspace::repo_names(cfg)? {
        let repo_path = cfg.workspace.join(&repo);
        for wt in git::worktrees(&repo_path)? {
            if !wt.path.starts_with(&session.path) {
                continue;
            }
            // A record with nothing live behind it is pruned instead: the
            // directory is gone, or a mirror symlink now stands where it was.
            if git::is_live_worktree(&wt.path) {
                git::remove_worktree(&repo_path, &wt.path, force)?;
            } else {
                git::prune_record(&repo_path, &wt.path)?;
            }
        }
    }
    Ok(())
}
