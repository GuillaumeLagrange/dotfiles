//! zellij-sessions: each zellij session's colour, order and folding (see lib.rs).
//!
//!   zellij-sessions config NAME        the config to start NAME with; prints nothing without a palette
//!   zellij-sessions ensure NAME...     give sessions without one a colour
//!   zellij-sessions color NAME [COLOR|next|prev]
//!   zellij-sessions list               the registry with each colour's hex, as JSON

use std::process::{Command, ExitCode};

use zellij_sessions::Store;

/// Every session zellij knows, exited ones included: they keep their colour for
/// when they are resurrected.
fn live() -> Vec<String> {
    Command::new("zellij")
        .args(["list-sessions", "--short", "--no-formatting"])
        .output()
        .map(|out| {
            String::from_utf8_lossy(&out.stdout)
                .lines()
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default()
}

fn run(args: &[&str]) -> Result<(), String> {
    let store = Store::from_env();
    let err = |e: std::io::Error| e.to_string();
    match args {
        ["config", name] => {
            if let Some(path) = store.zellij_config(name, &live()).map_err(err)? {
                println!("{}", path.display());
            }
        }
        ["ensure", names @ ..] => {
            let live = live();
            store
                .update(|r, p| r.ensure(names, p, &live))
                .map_err(err)?;
        }
        ["color", name] => {
            let palette = store.palette();
            if let Some(swatch) = store.load().swatch(name, &palette) {
                println!("{}", swatch.name);
            }
        }
        ["color", name, step @ ("next" | "prev")] => {
            let step = if *step == "next" { 1 } else { -1 };
            store
                .update(|r, p| r.cycle_color(name, p, step))
                .map_err(err)?;
        }
        ["color", name, color] => {
            if !store
                .update(|r, p| r.set_color(name, color, p))
                .map_err(err)?
            {
                return Err(format!("`{color}` is not in the palette"));
            }
        }
        ["list"] => {
            let palette = store.palette();
            let registry = store.load();
            let rows: Vec<_> = registry
                .sessions
                .iter()
                .map(|e| {
                    serde_json::json!({
                        "name": e.name,
                        "color": e.color,
                        "hex": registry.swatch(&e.name, &palette).map(|s| s.color.clone()),
                        "collapsed": e.collapsed,
                    })
                })
                .collect();
            println!("{}", serde_json::to_string_pretty(&rows).map_err(|e| e.to_string())?);
        }
        _ => {
            return Err(
                "usage: zellij-sessions config NAME | ensure NAME... | color NAME [COLOR|next|prev] | list"
                    .into(),
            )
        }
    }
    Ok(())
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("zellij-sessions: {e}");
            ExitCode::FAILURE
        }
    }
}
