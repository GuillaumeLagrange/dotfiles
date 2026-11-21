//! `launcher daemon` serves the bar's launcher panel; `launcher query` and `launcher activate`
//! are clients of it, for tests and for poking at it from a shell.

use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{bail, Context, Result};
use launcher_core::engine::{self, Engine};
use launcher_core::frecency::Frecency;
use launcher_core::{server, Config, Ctx, Dirs, Source};

mod client;

const USAGE: &str = "usage:
  launcher daemon [--config PATH] [--socket PATH]
  launcher query MODE [TEXT] [--socket PATH] [--wait-ms N]
  launcher activate MODE ID [ACTION] [--query TEXT] [--socket PATH]";

struct Args {
    positional: Vec<String>,
    config: Option<PathBuf>,
    socket: Option<PathBuf>,
    query: Option<String>,
    wait_ms: u64,
}

fn parse(args: impl Iterator<Item = String>) -> Result<Args> {
    let mut out = Args {
        positional: Vec::new(),
        config: None,
        socket: None,
        query: None,
        wait_ms: 0,
    };
    let mut args = args.peekable();
    while let Some(arg) = args.next() {
        let mut value = |flag: &str| args.next().with_context(|| format!("{flag} needs a value"));
        match arg.as_str() {
            "--config" => out.config = Some(value("--config")?.into()),
            "--socket" => out.socket = Some(value("--socket")?.into()),
            "--query" => out.query = Some(value("--query")?),
            "--wait-ms" => out.wait_ms = value("--wait-ms")?.parse().context("--wait-ms")?,
            "-h" | "--help" => {
                println!("{USAGE}");
                std::process::exit(0);
            }
            _ => out.positional.push(arg),
        }
    }
    Ok(out)
}

fn socket_path(args: &Args) -> Result<PathBuf> {
    if let Some(path) = &args.socket {
        return Ok(path.clone());
    }
    let runtime = std::env::var_os("XDG_RUNTIME_DIR").context("XDG_RUNTIME_DIR is not set")?;
    Ok(PathBuf::from(runtime).join("launcher.sock"))
}

fn config_path(args: &Args) -> Result<PathBuf> {
    if let Some(path) = &args.config {
        return Ok(path.clone());
    }
    let base = match std::env::var_os("XDG_CONFIG_HOME") {
        Some(dir) => PathBuf::from(dir),
        None => PathBuf::from(std::env::var_os("HOME").context("HOME is not set")?).join(".config"),
    };
    Ok(base.join("launcher/config.json"))
}

/// A crate's constructor for the sources of its modes the config enables.
type Build = fn(&Ctx) -> Result<Vec<Box<dyn Source>>>;

fn daemon(args: &Args) -> Result<()> {
    let config = Arc::new(Config::load(&config_path(args)?)?);
    let dirs = Arc::new(Dirs::from_env()?);
    let (engine_tx, updater, rx) = engine::channel();

    let clipboard = launcher_clipboard::start(&config, &dirs, updater.clone())
        .context("starting the clipboard")?;
    let lost = clipboard.lost;
    // The unit restarts the daemon against the compositor that replaced the lost one.
    std::thread::spawn(move || {
        if let Ok(why) = lost.recv() {
            eprintln!("launcher: {why}");
            std::process::exit(1);
        }
    });
    let frecency = Frecency::load(dirs.state.join("frecency.json"));
    let ctx = Ctx::new(config, dirs, clipboard.clipboard, frecency, updater);

    let mut sources: Vec<Box<dyn Source>> = clipboard.source.into_iter().collect();
    let groups: [(&str, Build); 4] = [
        ("desktop", launcher_desktop::sources),
        ("browser", launcher_browser::sources),
        ("passwords", launcher_passwords::sources),
        ("dev", launcher_dev::sources),
    ];
    for (name, build) in groups {
        // One broken group leaves the others usable.
        match build(&ctx) {
            Ok(group) => sources.extend(group),
            Err(err) => eprintln!("launcher: {name} sources: {err:#}"),
        }
    }

    let listener = server::bind(&socket_path(args)?)?;
    std::thread::spawn(move || server::serve(listener, engine_tx));
    Engine::new(ctx, sources).run(rx);
    Ok(())
}

fn main() -> Result<()> {
    let args = parse(std::env::args().skip(1))?;
    let socket = || socket_path(&args);
    match args.positional.first().map(String::as_str) {
        Some("daemon") => daemon(&args),
        Some("query") => {
            let [_, mode, rest @ ..] = args.positional.as_slice() else {
                bail!("{USAGE}");
            };
            let text = rest.join(" ");
            let line = client::query(&socket()?, mode, &text, args.wait_ms)?;
            println!("{line}");
            Ok(())
        }
        Some("activate") => {
            let [_, mode, id, rest @ ..] = args.positional.as_slice() else {
                bail!("{USAGE}");
            };
            let line = client::activate(
                &socket()?,
                mode,
                args.query.as_deref().unwrap_or(""),
                id,
                rest.first().map(String::as_str),
            )?;
            println!("{line}");
            Ok(())
        }
        _ => bail!("{USAGE}"),
    }
}
