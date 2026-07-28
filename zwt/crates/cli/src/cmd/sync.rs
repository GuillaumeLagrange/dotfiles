use anyhow::Result;

use zwt_core::config::Config;
use zwt_core::drift;
use zwt_core::registry::Registry;
use zwt_core::session::Session;

use crate::cmd;

pub fn run(cfg: &Config, id: Option<&str>, fix: bool, all: bool) -> Result<()> {
    let (reg, gone) = Registry::open(cfg)?;
    for id in &gone {
        println!("{id}: directory gone, dropped from the registry");
    }

    // Swept before the per-session pass: these belong to sessions the registry no
    // longer knows about, so no session below would reach them.
    let mut outstanding = sweep_orphans(cfg, fix)?;

    let sessions: Vec<Session> = if all {
        reg.sessions
            .keys()
            .map(|id| Session::from_registry(&reg, id))
            .collect::<Result<_>>()?
    } else {
        vec![cmd::target_session(&reg, id)?]
    };
    for session in &sessions {
        let items = drift::detect(cfg, session)?;
        if items.is_empty() {
            println!("{}: clean", session.id);
            continue;
        }
        println!("{}:", session.id);
        for item in &items {
            if fix {
                match drift::fix(cfg, session, item) {
                    Ok(()) => println!("  fixed: {}", item.describe()),
                    Err(err) => {
                        outstanding += 1;
                        println!("  failed: {} ({err:#})", item.describe());
                    }
                }
            } else {
                outstanding += 1;
                println!("  {}", item.describe());
            }
        }
    }

    if outstanding > 0 && !fix {
        println!("`zwt sync --fix` repairs what it can");
    }
    Ok(())
}

/// Worktree records left behind by a session directory that was deleted rather
/// than removed. Each one keeps its branch claimed, so they have to go even
/// though no session refers to them any more.
fn sweep_orphans(cfg: &Config, fix: bool) -> Result<usize> {
    let orphans = drift::orphans(cfg)?;
    if orphans.is_empty() {
        return Ok(0);
    }
    let mut outstanding = 0;
    for orphan in &orphans {
        let held = orphan
            .branch
            .as_ref()
            .map(|b| format!(", holding `{b}`"))
            .unwrap_or_default();
        let what = format!(
            "{}: worktree record for {} is gone{held}",
            orphan.repo,
            orphan.path.display()
        );
        // Only paths under the sessions root are zwt's to clean up; a stale record
        // elsewhere may be a drive that is merely unmounted.
        if !orphan.ours {
            outstanding += 1;
            println!("  {what} — outside the sessions root, `git worktree prune` it yourself");
            continue;
        }
        if !fix {
            outstanding += 1;
            println!("  {what}");
            continue;
        }
        match drift::prune_orphan(cfg, orphan) {
            Ok(()) => println!("  pruned: {what}"),
            Err(err) => {
                outstanding += 1;
                println!("  failed: {what} ({err:#})");
            }
        }
    }
    Ok(outstanding)
}
