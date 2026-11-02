use anyhow::{Context, Result};

use wt_core::config::Config;
use wt_core::registry::Registry;
use wt_core::session::{self, Session};
use wt_core::{git, hydrate, util, zellij};

use crate::cmd;

/// Rename a session: its registry key, its marker, and its directory when it sits
/// at the default path for its id. One placed with `--at` keeps its directory.
pub fn run(cfg: &Config, id: &str, name: &str) -> Result<()> {
    let (mut reg, _) = Registry::open(cfg)?;
    let id = cmd::resolve_id(&reg, id)?;
    let session = Session::from_registry(&reg, &id)?;
    let new_id = cmd::new::slug(name);
    anyhow::ensure!(!new_id.is_empty(), "`{name}` is not a usable session name");
    anyhow::ensure!(new_id != id, "the session is already called `{id}`");
    anyhow::ensure!(
        reg.get(&new_id).is_none(),
        "session `{new_id}` already exists"
    );

    // Its panes hold the old root in their environment and their cwd, and zellij
    // knows it by the old name: nothing a rename from out here can update.
    if zellij::available() {
        anyhow::ensure!(
            !zellij::is_live(&id)?,
            "`{id}` has a running zellij session; quit it first"
        );
    }

    let path = if session.path == cfg.session_path(&id) {
        let to = cfg.session_path(&new_id);
        anyhow::ensure!(!util::exists(&to), "{} already exists", to.display());
        std::fs::rename(&session.path, &to).with_context(|| {
            format!(
                "failed to move {} to {}",
                session.path.display(),
                to.display()
            )
        })?;
        to
    } else {
        session.path.clone()
    };
    let moved = path != session.path;

    session::write_marker(&path, &new_id, &cfg.workspace)?;
    reg.remove(&id);
    reg.insert(&new_id, &path, session.title.clone());
    reg.save()?;
    println!("{id} -> {new_id} ({})", path.display());

    // Saved for resurrection under the old name, with the old cwds in its layout.
    if zellij::available() {
        zellij::delete(&id)?;
    }

    if moved {
        let renamed = Session::from_registry(&reg, &new_id)?;
        let mut failed = 0;
        for member in renamed.members()? {
            let repair = git::repair_worktree(&cfg.workspace.join(&member.repo), &member.path)
                .and_then(|()| hydrate::allow_direnv(&member.path).map(drop));
            if let Err(err) = repair {
                eprintln!("wt: {}: {err:#}", member.repo);
                failed += 1;
            }
        }
        if let Err(err) = hydrate::allow_direnv(&path) {
            eprintln!("wt: could not allow direnv in the session root: {err:#}");
        }
        anyhow::ensure!(
            failed == 0,
            "{failed} member(s) not repaired; `git worktree repair <path>` from the main checkout retries one"
        );
    }
    Ok(())
}
