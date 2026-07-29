use anyhow::Result;

use wt_core::config::Config;
use wt_core::registry::Registry;
use wt_core::session::Session;

use crate::cmd;

/// The root of the session named, or of the one holding the cwd: what a shell
/// reads to resolve a session it knows only by name.
pub fn run(cfg: &Config, id: Option<&str>, exact: bool) -> Result<()> {
    let reg = Registry::open_raw(cfg)?;
    let session = match id {
        Some(needle) => {
            let id = if exact {
                anyhow::ensure!(reg.get(needle).is_some(), "no session `{needle}`");
                needle.to_string()
            } else {
                cmd::resolve_id(&reg, needle)?
            };
            Session::from_registry(&reg, &id)?
        }
        None => {
            wt_core::session::current(&reg)?.ok_or_else(|| anyhow::anyhow!("not in a session"))?
        }
    };
    println!("{}", session.path.display());
    Ok(())
}
