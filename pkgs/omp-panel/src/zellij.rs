//! Everything the panel asks of zellij, through its CLI.
//!
//! `zellij -s <session> action ...` reaches any session from anywhere, including
//! from a pane of another one, so the panel needs no plugin.

use std::collections::{HashMap, HashSet};
use std::process::Command;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use serde::Deserialize;

use crate::state::{Live, LiveSession, PaneInfo};

/// `zellij` with these arguments, run again while it says the session is not
/// there: its check that a session is up can fail on a live one, before the
/// action is sent (see `run` in pkgs/wt/crates/core/src/zellij.rs). With other
/// sessions up, it says so on stderr and lists them, exiting 0.
fn run(args: &[&str]) -> Result<String> {
    let mut tries = 0;
    loop {
        let out = Command::new("zellij")
            .args(args)
            .output()
            .context("running zellij")?;
        let stderr = String::from_utf8_lossy(&out.stderr);
        let unsent = stderr.contains("There is no active session!")
            || stderr.contains("not found. The following sessions are active");
        if out.status.success() && !unsent {
            return Ok(String::from_utf8_lossy(&out.stdout).into_owned());
        }
        tries += 1;
        if !unsent || tries == 5 {
            bail!("`zellij {}` failed: {}", args.join(" "), stderr.trim());
        }
    }
}

/// A query action's answer, parsed: one that does not parse (nothing, or another
/// command's answer) is asked for again.
fn query<T>(session: &str, action: &[&str], parse: impl Fn(&str) -> Option<T>) -> Result<T> {
    let mut args = vec!["-s", session, "action"];
    args.extend(action);
    for _ in 0..20 {
        if let Some(answer) = parse(&run(&args)?) {
            return Ok(answer);
        }
    }
    bail!("`zellij {}` never gave a usable answer", args.join(" "))
}

/// Sessions with a running server. Exited ones are only resurrectable, and have
/// no omp in them. A listing can leave a live session out (see `run`).
pub fn live_sessions() -> Vec<String> {
    // No session at all is an error exit, which means the same as an empty list.
    run(&["list-sessions", "--no-formatting"])
        .unwrap_or_default()
        .lines()
        .filter(|line| !line.contains("(EXITED"))
        .filter_map(|line| line.split_whitespace().next().map(str::to_owned))
        .collect()
}

/// Which of `wanted` are live. A session the first listing leaves out is only
/// taken for gone once a few more agree, since what is not live gets pruned.
fn live_among(wanted: &[String]) -> Vec<String> {
    let mut listed = live_sessions();
    for _ in 0..4 {
        if wanted.iter().all(|name| listed.contains(name)) {
            break;
        }
        for name in live_sessions() {
            if !listed.contains(&name) {
                listed.push(name);
            }
        }
    }
    listed.retain(|name| wanted.contains(name));
    listed
}

/// A terminal pane, as `list-panes --all` describes it.
#[derive(Deserialize)]
pub struct Pane {
    pub id: u32,
    is_plugin: bool,
    exited: bool,
    pub title: Option<String>,
    pub tab_name: Option<String>,
    pub tab_position: Option<u32>,
    /// What the pane was started with, not what runs in it now.
    pub pane_command: Option<String>,
    pub pane_cwd: Option<String>,
    /// The command of a pane started with one, kept after it exits when held.
    pub terminal_command: Option<String>,
    pub is_held: bool,
}

/// The session's running terminal panes.
pub fn terminal_panes(session: &str) -> Result<Vec<Pane>> {
    let listed: Vec<Pane> = query(session, &["list-panes", "--json", "--all"], |out| {
        serde_json::from_str(out).ok()
    })?;
    Ok(listed
        .into_iter()
        .filter(|p| !p.is_plugin && !p.exited)
        .collect())
}

pub fn panes(session: &str) -> Result<HashMap<u32, PaneInfo>> {
    Ok(terminal_panes(session)?
        .into_iter()
        .map(|p| {
            let info = PaneInfo {
                tab_name: p.tab_name.unwrap_or_default(),
                tab_position: p.tab_position.unwrap_or_default(),
            };
            (p.id, info)
        })
        .collect())
}

/// One line per attached client, under the header `list-clients` always prints.
fn clients(session: &str) -> Result<Vec<String>> {
    query(session, &["list-clients"], |out| {
        let mut lines = out.lines();
        lines
            .next()?
            .starts_with("CLIENT_ID")
            .then(|| lines.map(str::to_owned).collect())
    })
}

/// The terminal pane each attached client has focused.
pub fn client_panes(session: &str) -> Result<Vec<u32>> {
    Ok(clients(session)?
        .iter()
        .filter_map(|line| {
            line.split_whitespace()
                .nth(1)?
                .strip_prefix("terminal_")?
                .parse()
                .ok()
        })
        .collect())
}

pub fn has_client(session: &str) -> bool {
    clients(session).is_ok_and(|rows| !rows.is_empty())
}

/// Poll until someone is attached: a new window's client takes a moment to reach
/// the server, and focusing before then is lost.
pub fn wait_for_client(session: &str, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    loop {
        if has_client(session) {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Focus a pane in its session, switching the clients there to its tab.
pub fn focus_pane(session: &str, pane: u32) -> Result<()> {
    run(&[
        "-s",
        session,
        "action",
        "focus-pane-id",
        &format!("terminal_{pane}"),
    ])
    .map(drop)
}

/// Move the client this process runs under to another session's pane.
pub fn switch_session(session: &str, pane: u32) -> Result<()> {
    run(&[
        "action",
        "switch-session",
        session,
        "--pane-id",
        &format!("terminal_{pane}"),
    ])
    .map(drop)
}

/// Only the sessions asked about: one with no omp in it costs two processes a
/// refresh for nothing.
pub fn live(wanted: &[String]) -> Live {
    let sessions = std::thread::scope(|scope| {
        let handles: Vec<_> = live_among(wanted)
            .into_iter()
            .map(|name| {
                scope.spawn(move || {
                    // A session can die between the listing and this; it is simply not live.
                    let panes = panes(&name).ok()?;
                    let focused: HashSet<u32> = client_panes(&name)
                        .unwrap_or_default()
                        .into_iter()
                        .collect();
                    Some((name, LiveSession { panes, focused }))
                })
            })
            .collect();
        handles
            .into_iter()
            .filter_map(|h| h.join().ok().flatten())
            .collect()
    });
    Live { sessions }
}
