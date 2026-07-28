use anyhow::Result;

use zwt_core::config::Config;
use zwt_core::registry::Registry;
use zwt_core::session::Session;

use crate::cmd;
use crate::ui::{self, Choice};

/// The root of the session named, or of the one holding the cwd. This is what a
/// shell reads to point `WORKSPACE_ROOT` at a session.
pub fn run(cfg: &Config, id: Option<&str>) -> Result<()> {
    let reg = Registry::open_raw(cfg)?;
    let session = match id {
        Some(needle) => {
            let id = cmd::resolve_id(&reg, needle)?;
            Session::from_registry(&reg, &id)?
        }
        None => {
            zwt_core::session::current(&reg)?.ok_or_else(|| anyhow::anyhow!("not in a session"))?
        }
    };
    println!("{}", session.path.display());
    Ok(())
}

/// Bare `zwt [<id>]`: print a session root, picking one when none is named.
pub fn pick(cfg: &Config, id: Option<&str>) -> Result<()> {
    let (reg, gone) = Registry::open(cfg)?;
    for id in &gone {
        eprintln!("zwt: dropped `{id}` from the registry, its directory is gone");
    }
    anyhow::ensure!(
        !reg.sessions.is_empty(),
        "no sessions yet — `zwt new <branch>` makes one"
    );

    let id = match id {
        Some(needle) => cmd::resolve_id(&reg, needle)?,
        None => {
            let choices: Vec<Choice> = reg
                .sessions
                .iter()
                .map(|(id, entry)| {
                    let members = Session::from_registry(&reg, id)
                        .and_then(|s| s.member_names())
                        .unwrap_or_default();
                    let mut line = format!("{id:<16} {}", entry.title.clone().unwrap_or_default());
                    if !members.is_empty() {
                        line.push_str(&format!("  [{}]", members.join(" ")));
                    }
                    Choice::new(id.clone(), line)
                })
                .collect();
            ui::pick_one(&choices, "session>")?.ok_or_else(|| anyhow::anyhow!("nothing picked"))?
        }
    };
    let session = Session::from_registry(&reg, &id)?;
    anyhow::ensure!(
        session.path.is_dir(),
        "{} is gone; `zwt rm {id}` to forget it",
        session.path.display()
    );
    println!("{}", session.path.display());
    Ok(())
}
