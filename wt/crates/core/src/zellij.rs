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
use std::process::{Command, Stdio};

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

/// Start a session without attaching to it, so that its tabs can be set up before
/// anyone looks at it. Creates it, or resurrects it if zellij kept it.
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
        std::thread::sleep(std::time::Duration::from_millis(50));
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

/// Hand the terminal over to zellij: this replaces the process, so it returns only
/// when the attach itself could not happen.
pub fn attach(name: &str, root: &Path) -> Result<()> {
    use std::os::unix::process::CommandExt;
    let err = Command::new(BIN)
        .args(["attach", name])
        .env(ROOT_VAR, root)
        .exec();
    Err(err).with_context(|| format!("failed to attach to `{name}`"))
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

/// One tab per member, named after the repo and opened in it, for a session whose
/// server was just brought up.
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
        if before.iter().any(|tab| tab_is_for(&tab.name, &member.repo)) {
            continue;
        }
        new_tab(&session.id, &member.path, &member.repo)?;
        added.push(member.repo.clone());
    }

    // After the members' tabs exist, so the session is never left without one.
    for tab in before.iter().filter(|t| is_default_tab_name(&t.name)) {
        close_tab(&session.id, tab.tab_id)?;
    }
    Ok(added)
}

/// The members a running session has no tab for.
pub fn untabbed(session: &crate::session::Session) -> Result<Vec<String>> {
    let tabs = tabs(&session.id)?;
    Ok(session
        .members()?
        .into_iter()
        .filter(|m| !tabs.iter().any(|tab| tab_is_for(&tab.name, &m.repo)))
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
