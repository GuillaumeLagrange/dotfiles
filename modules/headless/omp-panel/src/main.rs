//! omp-panel: every omp running in a zellij session, with its state and last
//! message, and a jump to the one you pick.
//!
//!   omp-panel                     the picker (meant for a floating pane)
//!   omp-panel list [--json]       what the picker shows, once
//!   omp-panel jump <session> <pane>

mod jump;
mod markdown;
mod state;
mod tui;
mod zellij;

use anyhow::{bail, Context, Result};

use state::{now_ms, Status, Store};

fn go(session: &str, pane: u32) -> Result<()> {
    jump::jump(session, pane, &jump::Launcher::from_env()?)?;
    Store::from_env()
        .mark_viewed(session, pane, now_ms())
        .context("recording the pane as viewed")
}

fn list(json: bool) -> Result<()> {
    let store = Store::from_env();
    let groups = store.collect(&zellij::live(&store.sessions()), now_ms());
    if json {
        println!("{}", serde_json::to_string_pretty(&groups)?);
        return Ok(());
    }
    for group in &groups {
        println!("{} [{}]", group.session, label(group.status));
        for row in &group.panes {
            let text = row
                .blocked_reason
                .as_deref()
                .or(row.last_message.as_deref())
                .unwrap_or("");
            let first = text.lines().next().unwrap_or("");
            println!(
                "  {:>4} {:<8} {}  {}",
                row.pane_id,
                label(row.status),
                row.tab,
                row.title.as_deref().unwrap_or("untitled")
            );
            println!("{:16}{first}", "");
        }
    }
    Ok(())
}

fn label(status: Status) -> &'static str {
    match status {
        Status::Blocked => "blocked",
        Status::Working => "working",
        Status::Done => "done",
        Status::Idle => "idle",
    }
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    match args.as_slice() {
        [] => {
            if let Some((session, pane)) = tui::pick()? {
                go(&session, pane)?;
            }
            Ok(())
        }
        ["list"] => list(false),
        ["list", "--json"] => list(true),
        ["jump", session, pane] => go(session, pane.parse().context("pane must be a number")?),
        _ => bail!("usage: omp-panel [list [--json] | jump <session> <pane>]"),
    }
}
