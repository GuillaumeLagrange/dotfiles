//! What wt asks of zellij: whether a session is running, what tabs it has, and how
//! to get into it.
//!
//! This is also where the session root is handed over. Panes inherit the server's
//! environment and the server inherits the environment of whoever started it, so
//! the way to set it for a whole session is to *be* the process that starts the
//! server — which `attach --create-background` does, for a new session and for one
//! being resurrected alike. Everything else follows from that: even switching from
//! inside another session starts the target here first, because letting zellij's
//! own server spawn it would hand it an environment that never saw the root.

use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use serde::Deserialize;

use crate::util;

/// The variable a session's panes are meant to inherit.
pub const ROOT_VAR: &str = "WORKSPACE_ROOT";

const BIN: &str = "zellij";

/// Only the fields wt acts on; zellij reports a good deal more.
#[derive(Debug, Clone, Deserialize)]
pub struct Tab {
    pub tab_id: u32,
    pub name: String,
    pub selectable_tiled_panes_count: u32,
    pub selectable_floating_panes_count: u32,
}

impl Tab {
    /// A tab with nothing in it: what a `new-tab` zellij could not lay out leaves
    /// behind (see `has_client`). Zellij cannot show it, and the user cannot use it.
    pub fn is_empty(&self) -> bool {
        self.selectable_tiled_panes_count == 0 && self.selectable_floating_panes_count == 0
    }
}

pub fn available() -> bool {
    util::which(BIN).is_some()
}

/// The session this process is running in, if any.
pub fn current() -> Option<String> {
    std::env::var_os("ZELLIJ")?;
    std::env::var("ZELLIJ_SESSION_NAME").ok()
}

/// Whether a session has a running server. One that zellij lists as resurrectable
/// has none, and cannot be asked anything until it is revived.
pub fn is_live(name: &str) -> Result<bool> {
    let out = run(&["list-sessions", "--no-formatting"], None)?;
    // No sessions at all is a non-zero exit, not a failure to answer.
    Ok(out.stdout.lines().any(|line| {
        line.split_whitespace().next() == Some(name) && !line.contains("(EXITED")
    }))
}

/// Whether a client is attached to a session.
///
/// Tabs are only ever added to a session someone is looking at: zellij lays a new
/// tab out against the attached client's size, and a server with no client has
/// none — since 0.45 it reports a zero-sized viewport, so `new-tab` fails with
/// "Not enough room for panes" and leaves a tab with no pane in it at all. A
/// client landing later does not repair it, and attaching to such a tab drops the
/// client straight back out.
pub fn has_client(name: &str) -> Result<bool> {
    let out = run(&["--session", name, "action", "list-clients"], None)?;
    if !out.ok() {
        return Err(anyhow!(
            "could not list the clients of `{name}`: {}",
            out.stderr.trim()
        ));
    }
    // A header line is always printed; a client is a line after it.
    Ok(out.stdout.lines().skip(1).any(|line| !line.trim().is_empty()))
}

/// Wait for the client handed the terminal to reach a session, so its tabs can be
/// laid out. False if none turned up, or if the session went away first — a user
/// who quits immediately is not an error.
pub fn wait_for_client(name: &str) -> Result<bool> {
    for _ in 0..100 {
        match has_client(name) {
            Ok(true) => return Ok(true),
            Ok(false) => {}
            Err(_) => return Ok(false),
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    Ok(false)
}

/// Start a session's server without attaching to it, which is what puts the root
/// in its environment. Creates the session, or resurrects it if zellij kept it.
pub fn start_detached(name: &str, root: &Path) -> Result<()> {
    let out = run(&["attach", "--create-background", name], Some(root))?;
    if !out.ok() {
        return Err(anyhow!("could not start `{name}`: {}", out.stderr.trim()));
    }
    // The command returns before the server is listening.
    for _ in 0..100 {
        if is_live(name)? {
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    Err(anyhow!("`{name}` did not come up"))
}

pub fn tabs(name: &str) -> Result<Vec<Tab>> {
    let out = run(&["--session", name, "action", "list-tabs", "--json"], None)?;
    if !out.ok() {
        return Err(anyhow!(
            "could not list the tabs of `{name}`: {}",
            out.stderr.trim()
        ));
    }
    serde_json::from_str(&out.stdout).context("could not read zellij's tab list")
}

pub fn new_tab(name: &str, cwd: &Path, tab: &str) -> Result<()> {
    let cwd = cwd.to_string_lossy();
    let out = run(
        &[
            "--session", name, "action", "new-tab", "--cwd", &cwd, "--name", tab,
        ],
        None,
    )?;
    if !out.ok() {
        return Err(anyhow!(
            "could not add a `{tab}` tab to `{name}`: {}",
            out.stderr.trim()
        ));
    }
    Ok(())
}

pub fn close_tab(name: &str, id: u32) -> Result<()> {
    let id = id.to_string();
    let out = run(
        &["--session", name, "action", "close-tab-by-id", &id],
        None,
    )?;
    if !out.ok() {
        return Err(anyhow!(
            "could not close tab {id} of `{name}`: {}",
            out.stderr.trim()
        ));
    }
    Ok(())
}

/// Move an attached client to another session, from inside the one it is in.
pub fn switch_to(name: &str) -> Result<()> {
    let out = run(&["action", "switch-session", name], None)?;
    if !out.ok() {
        return Err(anyhow!("could not switch to `{name}`: {}", out.stderr.trim()));
    }
    Ok(())
}

/// Hand the terminal over to zellij, as a child of this process rather than by
/// replacing it: the session's tabs can only be laid out once this client is
/// attached, so the caller stays around to do that and then waits for it.
pub fn attach_child(name: &str, root: &Path) -> Result<Child> {
    Command::new(BIN)
        .args(["attach", name])
        .env(ROOT_VAR, root)
        .spawn()
        .with_context(|| format!("failed to attach to `{name}`"))
}

/// A tab zellij named itself, which is therefore nobody's repo.
pub fn is_default_tab_name(name: &str) -> bool {
    name.starts_with("Tab #")
}

/// Whether a tab is a member's.
///
/// Compared on the last word of the name, since a tab can be decorated: the shell
/// renames the focused one to the repo behind an icon, and that is still its tab.
pub fn tab_is_for(tab: &str, repo: &str) -> bool {
    tab.split_whitespace().last() == Some(repo)
}

/// One tab per member, named after the repo and opened in it, for a session a
/// client is attached to.
///
/// Idempotent, and it leaves whatever tabs are already there — including however
/// the panes inside them have been split, which is not wt's business.
pub fn ensure_tabs(session: &crate::session::Session) -> Result<Vec<String>> {
    let members = session.members()?;
    if members.is_empty() {
        return Ok(Vec::new());
    }

    let before = tabs(&session.id)?;
    let mut added = Vec::new();
    for member in &members {
        if before
            .iter()
            .any(|tab| tab_is_for(&tab.name, &member.repo) && !tab.is_empty())
        {
            continue;
        }
        new_tab(&session.id, &member.path, &member.repo)?;
        added.push(member.repo.clone());
    }

    // Closed after the members' tabs exist, so the session is never left without
    // one: the tab zellij opens with, and any that is empty — a tab holding
    // nothing is one a member has just been given a working replacement for.
    //
    // Zellij's own name only counts on a pass that added something, since a later
    // pass runs on every attach and a tab still carrying that name is then one the
    // user opened.
    for tab in before
        .iter()
        .filter(|t| t.is_empty() || (!added.is_empty() && is_default_tab_name(&t.name)))
    {
        close_tab(&session.id, tab.tab_id)?;
    }
    Ok(added)
}

/// The members a running session has no usable tab for.
pub fn untabbed(session: &crate::session::Session) -> Result<Vec<String>> {
    let tabs = tabs(&session.id)?;
    Ok(session
        .members()?
        .into_iter()
        .filter(|m| {
            !tabs
                .iter()
                .any(|tab| tab_is_for(&tab.name, &m.repo) && !tab.is_empty())
        })
        .map(|m| m.repo)
        .collect())
}

fn run(args: &[&str], root: Option<&Path>) -> Result<util::Output> {
    let mut cmd = Command::new(BIN);
    cmd.args(args).stdin(Stdio::null());
    if let Some(root) = root {
        cmd.env(ROOT_VAR, root);
    }
    let out = cmd
        .output()
        .with_context(|| format!("failed to spawn `{BIN} {}`", args.join(" ")))?;
    Ok(util::Output {
        status: out.status.code().unwrap_or(-1),
        stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_zellijs_own_tab_names_are_default() {
        assert!(is_default_tab_name("Tab #1"));
        assert!(is_default_tab_name("Tab #12"));
        assert!(!is_default_tab_name("platform"));
        assert!(!is_default_tab_name("Tabs"));
    }

    #[test]
    fn a_decorated_tab_is_still_its_members() {
        assert!(tab_is_for("platform", "platform"));
        assert!(tab_is_for("\u{e702} platform", "platform"));
        assert!(!tab_is_for("platform-docs", "platform"));
        assert!(!tab_is_for("Tab #1", "platform"));
    }
}
