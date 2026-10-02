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

fn run(args: &[&str]) -> Result<String> {
    let out = Command::new("zellij")
        .args(args)
        .output()
        .context("running zellij")?;
    if !out.status.success() {
        bail!(
            "`zellij {}` failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Sessions with a running server. Exited ones are only resurrectable, and have
/// no omp in them.
pub fn live_sessions() -> Vec<String> {
    // No session at all is an error exit, which means the same as an empty list.
    run(&["list-sessions", "--no-formatting"])
        .unwrap_or_default()
        .lines()
        .filter(|line| !line.contains("(EXITED"))
        .filter_map(|line| line.split_whitespace().next().map(str::to_owned))
        .collect()
}

#[derive(Deserialize)]
struct ListedPane {
    id: u32,
    is_plugin: bool,
    exited: bool,
    tab_name: Option<String>,
    tab_position: Option<u32>,
}

pub fn panes(session: &str) -> Result<HashMap<u32, PaneInfo>> {
    let json = run(&[
        "-s",
        session,
        "action",
        "list-panes",
        "--json",
        "--tab",
        "--state",
    ])?;
    let listed: Vec<ListedPane> = serde_json::from_str(&json).context("parsing list-panes")?;
    Ok(listed
        .into_iter()
        .filter(|p| !p.is_plugin && !p.exited)
        .map(|p| {
            let info = PaneInfo {
                tab_name: p.tab_name.unwrap_or_default(),
                tab_position: p.tab_position.unwrap_or_default(),
            };
            (p.id, info)
        })
        .collect())
}

/// The terminal pane each attached client has focused.
pub fn client_panes(session: &str) -> Result<Vec<u32>> {
    let table = run(&["-s", session, "action", "list-clients"])?;
    Ok(table
        .lines()
        .skip(1)
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
    run(&["-s", session, "action", "list-clients"]).is_ok_and(|table| table.lines().count() > 1)
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
    let sessions = live_sessions()
        .into_iter()
        .filter(|name| wanted.contains(name))
        .filter_map(|name| {
            // A session can die between the listing and this; it is simply not live.
            let panes = panes(&name).ok()?;
            let focused: HashSet<u32> = client_panes(&name)
                .unwrap_or_default()
                .into_iter()
                .collect();
            Some((name, LiveSession { panes, focused }))
        })
        .collect();
    Live { sessions }
}
