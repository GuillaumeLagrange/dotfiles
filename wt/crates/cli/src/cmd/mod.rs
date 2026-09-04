pub mod add;
pub mod attach;
pub mod ls;
pub mod new;
pub mod path;
pub mod promote;
pub mod remove;
pub mod sync;

use anyhow::Result;

use wt_core::registry::Registry;
use wt_core::session::{self, Session};

/// Resolve a session id the way it gets typed: in full, or by unique prefix.
pub fn resolve_id(reg: &Registry, needle: &str) -> Result<String> {
    if reg.get(needle).is_some() {
        return Ok(needle.to_string());
    }
    let hits: Vec<&String> = reg
        .sessions
        .keys()
        .filter(|id| id.starts_with(needle))
        .collect();
    match hits.len() {
        1 => Ok(hits[0].clone()),
        0 => anyhow::bail!("no session matches `{needle}` (see `wt ls`)"),
        _ => anyhow::bail!(
            "`{needle}` matches several sessions: {}",
            hits.iter()
                .map(|s| s.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        ),
    }
}

/// The session a command applies to: named explicitly, or the one the caller is
/// standing in.
pub fn target_session(reg: &Registry, explicit: Option<&str>) -> Result<Session> {
    match explicit {
        Some(needle) => {
            let id = resolve_id(reg, needle)?;
            Session::from_registry(reg, &id)
        }
        None => session::current(reg)?.ok_or_else(|| {
            anyhow::anyhow!("not inside a session; name one with --session or cd into it")
        }),
    }
}
