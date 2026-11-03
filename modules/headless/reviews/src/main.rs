//! reviews: pick a pull request awaiting my review, one I reviewed lately, or
//! one of my own.
//!
//!   reviews [--out FILE] [QUERY...]
//!   reviews --refresh
//!   reviews --json
//!
//! The pick is written as `<kind>\t<repo>\t<url>\t<branch>` to FILE (stdout
//! without one), `kind` being `mine` for a pick in the "my PRs" tab and `review`
//! otherwise, for the `review` script (`review.sh`) to open it.
//! `--refresh` only fetches the lists into the cache, for a timer to run.
//! `--json` prints every cached list with its stacks, for the bar.

mod feed;
mod github;
mod kitty;
mod markdown;
mod stacks;
mod tui;

use anyhow::{bail, Context, Result};

fn main() -> Result<()> {
    let mut out = None;
    let mut query = Vec::new();
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--out" => out = Some(args.next().context("--out needs a file")?),
            "--refresh" => return github::refresh(&github::Cache::from_env()),
            "--json" => return feed::print(&github::Cache::from_env()),
            "-h" | "--help" => {
                println!(
                    "usage: reviews [--out FILE] [QUERY...] | reviews --refresh | reviews --json"
                );
                return Ok(());
            }
            flag if flag.starts_with('-') => bail!("unknown option {flag}"),
            _ => query.push(arg),
        }
    }

    let Some((pr, tab)) = tui::pick(query.join(" "))? else {
        std::process::exit(1);
    };
    let kind = match tab {
        tui::Tab::Mine => "mine",
        tui::Tab::Requested | tui::Tab::Reviewed => "review",
    };
    let line = format!("{kind}\t{}\t{}\t{}\n", pr.repo, pr.url, pr.branch);
    match out {
        Some(path) => std::fs::write(&path, line).with_context(|| format!("writing {path}"))?,
        None => print!("{line}"),
    }
    Ok(())
}
