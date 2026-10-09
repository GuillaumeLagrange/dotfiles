//! reviews: pick a pull request awaiting my review.
//!
//!   reviews [--out FILE] [QUERY...]
//!
//! The pick is written as `<repo>\t<url>` to FILE (stdout without one), for the
//! `review` script (`review.sh`) to open the PR in a tab of the reviews session.

mod github;
mod kitty;
mod tui;

use anyhow::{bail, Context, Result};

fn main() -> Result<()> {
    let mut out = None;
    let mut query = Vec::new();
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--out" => out = Some(args.next().context("--out needs a file")?),
            "-h" | "--help" => {
                println!("usage: reviews [--out FILE] [QUERY...]");
                return Ok(());
            }
            flag if flag.starts_with('-') => bail!("unknown option {flag}"),
            _ => query.push(arg),
        }
    }

    let Some(pr) = tui::pick(query.join(" "))? else {
        std::process::exit(1);
    };
    let line = format!("{}\t{}\n", pr.repo, pr.url);
    match out {
        Some(path) => std::fs::write(&path, line).with_context(|| format!("writing {path}"))?,
        None => print!("{line}"),
    }
    Ok(())
}
