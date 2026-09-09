use anyhow::{Context, Result};

use wt_core::config::Config;
use wt_core::registry::Registry;
use wt_core::session::Session;
use wt_core::zellij;

use crate::cmd;
use crate::ui::{self, Choice};

/// Get into a session: bare `wt`, the way it is meant to be used.
///
/// Attaching never touches the session directory — the worktrees, the mirror and
/// the marker are `new`'s and `sync`'s business. All this adds is the zellij
/// session, its tabs, and the root in the environment they inherit.
pub fn run(cfg: &Config, id: Option<&str>) -> Result<()> {
    let (reg, gone) = Registry::open(cfg)?;
    for id in &gone {
        eprintln!("wt: dropped `{id}` from the registry, its directory is gone");
    }
    anyhow::ensure!(
        !reg.sessions.is_empty(),
        "no sessions yet — `wt new <branch>` makes one"
    );

    let id = match id {
        Some(needle) => cmd::resolve_id(&reg, needle)?,
        None => pick(&reg)?,
    };
    let session = Session::from_registry(&reg, &id)?;
    anyhow::ensure!(
        session.path.is_dir(),
        "{} is gone; `wt rm {id}` to forget it",
        session.path.display()
    );
    anyhow::ensure!(
        zellij::available(),
        "zellij is not installed; `wt path {id}` prints the root instead"
    );

    // Started here even when we are inside another session and only going to
    // switch: the server has to inherit the root from this process, and zellij's
    // own server could not give it one.
    if !zellij::is_live(&id)? {
        zellij::start_detached(&id, &session.path)?;
    }

    // The tabs come after a client is on the session, never before: `new-tab`
    // needs an attached client to lay a tab out against (see
    // `zellij::has_client`). So the terminal is handed over first, and the tabs
    // are laid out behind the client that took it.
    //
    // This runs on every attach, not just the one that started the server: a
    // session keeps the tabs it has, and a member without one gets it here.
    match zellij::current() {
        Some(current) if current == id => {
            for repo in zellij::ensure_tabs(&session)? {
                println!("{id}: opened a tab for {repo}");
            }
            println!("{id}: already here");
            Ok(())
        }
        Some(_) => {
            zellij::switch_to(&id)?;
            tabs_behind_the_client(&session);
            Ok(())
        }
        None => {
            let mut child = zellij::attach_child(&id, &session.path)?;
            tabs_behind_the_client(&session);
            let status = child.wait().context("waiting for zellij to exit")?;
            std::process::exit(status.code().unwrap_or(1))
        }
    }
}

/// Lay out the tabs of the session the terminal has just been given to.
///
/// Nothing is printed and nothing fails: the screen belongs to zellij by now, and
/// `wt sync` reports the members left without a tab.
fn tabs_behind_the_client(session: &Session) {
    if zellij::wait_for_client(&session.id).unwrap_or(false) {
        let _ = zellij::ensure_tabs(session);
    }
}

fn pick(reg: &Registry) -> Result<String> {
    let choices: Vec<Choice> = reg
        .sessions
        .iter()
        .map(|(id, entry)| {
            let members = Session::from_registry(reg, id)
                .and_then(|s| s.member_names())
                .unwrap_or_default();
            let mut line = format!("{id:<16} {}", entry.title.clone().unwrap_or_default());
            if !members.is_empty() {
                line.push_str(&format!("  [{}]", members.join(" ")));
            }
            Choice::new(id.clone(), line)
        })
        .collect();
    ui::pick_one(&choices, "session>")?.ok_or_else(|| anyhow::anyhow!("nothing picked"))
}
