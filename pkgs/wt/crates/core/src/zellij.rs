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

use crate::session::Session;
use crate::util;

/// The variable a session's panes are meant to inherit.
pub const ROOT_VAR: &str = "WORKSPACE_ROOT";

const BIN: &str = "zellij";

/// Only the fields wt acts on; zellij reports a good deal more.
#[derive(Debug, Clone, Deserialize)]
pub struct Tab {
    pub tab_id: u32,
    pub position: usize,
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
///
/// A listing can leave a live session out (see `run`), so it only counts as down
/// once a few listings agree.
pub fn is_live(name: &str) -> Result<bool> {
    for _ in 0..5 {
        let out = run(&["list-sessions", "--no-formatting"], None)?;
        // No sessions at all is a non-zero exit, not a failure to answer.
        if out
            .stdout
            .lines()
            .any(|line| line.split_whitespace().next() == Some(name) && !line.contains("(EXITED"))
        {
            return Ok(true);
        }
    }
    Ok(false)
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
    // A header line is always printed; a client is a line after it.
    query(name, "clients", &["list-clients"], |out| {
        let mut lines = out.lines();
        lines
            .next()?
            .starts_with("CLIENT_ID")
            .then(|| lines.any(|line| !line.trim().is_empty()))
    })
}

/// Wait for the client handed the terminal to reach a session, so its tabs can be
/// laid out. False if none turned up, or if the session went away first — a user
/// who quits immediately is not an error.
///
/// Waits for as long as `coming` says the client is still on its way, up to a
/// limit: a loaded machine can take seconds to let it in.
pub fn wait_for_client(name: &str, mut coming: impl FnMut() -> bool) -> Result<bool> {
    for _ in 0..600 {
        match has_client(name) {
            Ok(true) => return Ok(true),
            Ok(false) => {}
            // A server still setting up can fail to answer.
            Err(_) if is_live(name)? => {}
            Err(_) => return Ok(false),
        }
        if !coming() {
            return Ok(false);
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
            // And the client that created it in the background can still be
            // listed for a moment, which a caller waiting for a client to lay
            // tabs out against would take for one.
            for _ in 0..100 {
                if !has_client(name).unwrap_or(false) {
                    break;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    Err(anyhow!("`{name}` did not come up"))
}

/// Kill a session's server and delete its saved state (`delete-session --force`).
///
/// Zellij restores a session's saved layout on the next start, so deleting it is
/// the only way an edited layout reaches an existing session.
///
/// It is also the only way to get a client off a session: `action detach` is a
/// keybind the client acts on, and does nothing when it arrives over the CLI
/// (checked on 0.45). Every client drops back to the terminal it came from.
pub fn delete(name: &str) -> Result<()> {
    let out = run(&["delete-session", "--force", name], None)?;
    // Nothing to delete is the state being asked for, not a failure.
    if !out.ok() && !out.stderr.contains("not found") {
        return Err(anyhow!("could not delete `{name}`: {}", out.stderr.trim()));
    }
    Ok(())
}

/// A session's tabs.
pub fn tabs(name: &str) -> Result<Vec<Tab>> {
    query(name, "tabs", &["list-tabs", "--json"], |out| {
        serde_json::from_str(out).ok()
    })
}

/// Opens a tab and returns its id.
pub fn new_tab(name: &str, cwd: &Path, tab: &str) -> Result<u32> {
    let before: Vec<u32> = tabs(name)?.into_iter().map(|t| t.tab_id).collect();
    let cwd = cwd.to_string_lossy();
    let out = run(
        &[
            "--session",
            name,
            "action",
            "new-tab",
            "--cwd",
            &cwd,
            "--name",
            tab,
        ],
        None,
    )?;
    if !out.ok() {
        return Err(anyhow!(
            "could not add a `{tab}` tab to `{name}`: {}",
            out.stderr.trim()
        ));
    }
    // The id printed can be missing or another tab's, and the tab not opened yet
    // (see `query`), while a second `new-tab` would make two: the id is the
    // listed tab of that name that was not there before.
    let printed: Option<u32> = out.stdout.trim().parse().ok();
    // A loaded machine can take seconds to open it.
    for _ in 0..200 {
        let new: Vec<u32> = tabs(name)?
            .into_iter()
            .filter(|t| t.name == tab && !before.contains(&t.tab_id))
            .map(|t| t.tab_id)
            .collect();
        if let Some(id) = printed
            .filter(|id| new.contains(id))
            .or(new.first().copied())
        {
            return Ok(id);
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    Err(anyhow!("the new `{tab}` tab of `{name}` never showed up"))
}

fn move_tab(name: &str, id: u32, direction: &str, times: usize) -> Result<()> {
    let id = id.to_string();
    for _ in 0..times {
        let out = run(
            &[
                "--session",
                name,
                "action",
                "move-tab",
                "--tab-id",
                &id,
                direction,
            ],
            None,
        )?;
        if !out.ok() {
            return Err(anyhow!(
                "could not move tab {id} of `{name}`: {}",
                out.stderr.trim()
            ));
        }
    }
    Ok(())
}

pub fn close_tab(name: &str, id: u32) -> Result<()> {
    let id = id.to_string();
    let out = run(&["--session", name, "action", "close-tab-by-id", &id], None)?;
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
        return Err(anyhow!(
            "could not switch to `{name}`: {}",
            out.stderr.trim()
        ));
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
/// Compared on the last word of the name, since `mux-name` puts an icon before
/// the repo, and a tab renamed by hand may lack it.
pub fn tab_is_for(tab: &str, repo: &str) -> bool {
    tab.split_whitespace().last() == Some(repo)
}

/// What the shell's rename keybind would call the tab: `mux-name`'s answer, else
/// the bare repo where that helper is not installed.
fn tab_name(path: &Path, repo: &str) -> String {
    Command::new("mux-name")
        .arg(path)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()
        .filter(|out| out.status.success())
        .and_then(|out| String::from_utf8(out.stdout).ok())
        .map(|name| name.trim().to_string())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| repo.to_string())
}

/// Where a repo sorts among the tabs: the configured `repos` order, then the
/// unlisted ones by name.
fn rank<'a>(order: &[String], repo: &'a str) -> (usize, &'a str) {
    let index = order.iter().position(|r| r == repo);
    (index.unwrap_or(order.len()), repo)
}

/// Open a member's tab, moved among the other members' tabs to where `order`
/// puts it. Tabs that are nobody's stay where they are.
pub fn open_tab(session: &Session, repo: &str, order: &[String]) -> Result<()> {
    let path = session.path.join(repo);
    let id = new_tab(&session.id, &path, &tab_name(&path, repo))?;

    let members = session.member_names()?;
    let mine = rank(order, repo);
    let tabs = tabs(&session.id)?;
    let pos = tabs
        .iter()
        .find(|t| t.tab_id == id)
        .ok_or_else(|| anyhow!("the new `{repo}` tab is not in `{}`", session.id))?
        .position;
    let mut last_before = None;
    let mut first_after = None;
    for tab in tabs.iter().filter(|t| t.tab_id != id) {
        let Some(other) = members.iter().find(|m| tab_is_for(&tab.name, m)) else {
            continue;
        };
        let theirs = rank(order, other);
        if theirs < mine {
            last_before = last_before.max(Some(tab.position));
        } else if theirs > mine {
            first_after = Some(first_after.map_or(tab.position, |p: usize| p.min(tab.position)));
        }
    }
    match (last_before, first_after) {
        (_, Some(after)) if after < pos => move_tab(&session.id, id, "left", pos - after),
        (Some(before), _) if before > pos => move_tab(&session.id, id, "right", before - pos),
        _ => Ok(()),
    }
}

/// One tab per member, opened in it, in the configured order, for a session a
/// client is attached to.
///
/// Idempotent, and it leaves whatever tabs are already there — including however
/// the panes inside them have been split, which is not wt's business.
pub fn ensure_tabs(session: &Session, order: &[String]) -> Result<Vec<String>> {
    let mut members = session.member_names()?;
    if members.is_empty() {
        return Ok(Vec::new());
    }
    members.sort_by(|a, b| rank(order, a).cmp(&rank(order, b)));

    let before = tabs(&session.id)?;
    let mut added = Vec::new();
    for repo in members {
        if before
            .iter()
            .any(|tab| tab_is_for(&tab.name, &repo) && !tab.is_empty())
        {
            continue;
        }
        open_tab(session, &repo, order)?;
        added.push(repo);
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
pub fn untabbed(session: &Session) -> Result<Vec<String>> {
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

/// A query action's answer, parsed. An answer that does not parse is asked for
/// again: zellij answers with nothing just after a client attaches, until its
/// screen is up, and can hand any answer to the wrong command (see `run`).
fn query<T>(
    name: &str,
    what: &str,
    action: &[&str],
    parse: impl Fn(&str) -> Option<T>,
) -> Result<T> {
    let mut args = vec!["--session", name, "action"];
    args.extend(action);
    for _ in 0..40 {
        let out = run(&args, None)?;
        if !out.ok() {
            return Err(anyhow!(
                "could not list the {what} of `{name}`: {}",
                out.stderr.trim()
            ));
        }
        if let Some(answer) = parse(&out.stdout) {
            return Ok(answer);
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    Err(anyhow!("zellij never listed the {what} of `{name}`"))
}

/// zellij's CLI, through a race of its own: the server gives each connection the
/// lowest free client id, and tears the previous holder of an id down after it
/// may already be handed out again, so a connection can lose its own messages or
/// get the late ones of the connection before it. Every command connects twice:
/// first to check that the session is up, and that check then fails on a live one
/// ("There is no active session!", "Session '…' not found"), before anything was
/// sent, so the command is run again; then for the action itself, which can exit
/// having printed nothing or someone else's answer (see `query`), and before it
/// took effect.
fn run(args: &[&str], root: Option<&Path>) -> Result<util::Output> {
    let mut tries = 0;
    loop {
        let mut cmd = Command::new(BIN);
        cmd.args(args).stdin(Stdio::null());
        if let Some(root) = root {
            cmd.env(ROOT_VAR, root);
        }
        let out = cmd
            .output()
            .with_context(|| format!("failed to spawn `{BIN} {}`", args.join(" ")))?;
        let out = util::Output {
            status: out.status.code().unwrap_or(-1),
            stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        };
        tries += 1;
        // With other sessions up, zellij says so on stderr and lists them, exiting 0.
        let unsent = out.stderr.contains("There is no active session!")
            || out
                .stderr
                .contains("not found. The following sessions are active");
        if !unsent {
            return Ok(out);
        }
        if tries == 5 {
            return Ok(util::Output { status: 1, ..out });
        }
    }
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
