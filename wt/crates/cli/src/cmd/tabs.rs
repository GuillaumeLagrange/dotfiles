use anyhow::Result;

use wt_core::config::Config;
use wt_core::registry::Registry;
use wt_core::session::Session;
use wt_core::zellij;

use crate::cmd;

/// Open the tabs a running session's members lack, as attaching does, and
/// return once they are laid out: for tools that attach a client of their own.
pub fn run(cfg: &Config, id: Option<&str>) -> Result<()> {
    let reg = Registry::open_raw(cfg)?;
    let id = match id {
        Some(needle) => cmd::resolve_id(&reg, needle)?,
        None => {
            wt_core::session::current(&reg)?
                .ok_or_else(|| anyhow::anyhow!("not in a session"))?
                .id
        }
    };
    let session = Session::from_registry(&reg, &id)?;
    anyhow::ensure!(
        zellij::has_client(&id)?,
        "`{id}` has no client attached: zellij cannot lay a tab out without one"
    );
    for repo in zellij::ensure_tabs(&session, &cfg.repos)? {
        println!("{repo}");
    }
    Ok(())
}
