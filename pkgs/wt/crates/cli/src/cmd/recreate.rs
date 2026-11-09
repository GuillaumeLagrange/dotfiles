use anyhow::Result;

use wt_core::config::Config;
use wt_core::registry::Registry;
use wt_core::session::{self, Session};
use wt_core::zellij;

use crate::cmd;

/// Throw a session's zellij session away and get a new one.
///
/// Zellij restores a session as it was rather than as the config now describes it,
/// so an edited layout only shows up in one that does not exist yet.
pub fn run(cfg: &Config, id: Option<&str>) -> Result<()> {
    let (reg, _) = Registry::open(cfg)?;
    let session = target(&reg, id)?;
    anyhow::ensure!(
        zellij::available(),
        "zellij is not installed; there is no session to recreate"
    );

    // From inside, deleting the session kills this process along with its other
    // panes, so the request is written first. The `wt` that attached the terminal
    // then rebuilds the session; for a terminal attached some other way, the next
    // `wt <id>` does.
    if zellij::current().as_deref() == Some(session.id.as_str()) {
        session.request_recreate()?;
        return zellij::delete(&session.id);
    }

    zellij::delete(&session.id)?;
    cmd::attach::run(cfg, Some(&session.id))
}

/// The session to rebuild: named, else the one the cwd is in, else the one this
/// pane belongs to — a pane whose cwd has wandered out of the session still knows
/// which one it is in, and that name is the registry key.
fn target(reg: &Registry, id: Option<&str>) -> Result<Session> {
    if id.is_none() {
        if let Some(session) = session::current(reg)? {
            return Ok(session);
        }
        if let Some(name) = zellij::current() {
            if reg.get(&name).is_some() {
                return Session::from_registry(reg, &name);
            }
        }
    }
    cmd::target_session(reg, id)
}
