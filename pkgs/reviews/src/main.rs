//! reviews: pick a pull request awaiting my review, one I reviewed lately, or
//! one of my own.
//!
//!   reviews [--out FILE] [QUERY...]
//!   reviews open --pr URL
//!   reviews open --mine URL BRANCH
//!   reviews --refresh
//!   reviews --json
//!
//! QUERY pre-fills the picker's filter. The pick is opened in zellij (`open.rs`),
//! or with --out written as `<kind>\t<repo>\t<url>\t<branch>` to FILE, `kind`
//! being `mine` for a pick in the "my PRs" tab and `review` otherwise.
//! `open` skips the picker: --pr opens URL as if picked in a review tab, --mine as
//! if picked in "my PRs".
//! `--refresh` only fetches the lists into the cache, for a timer to run.
//! `--json` prints every cached list with its stacks, for the bar.

mod feed;
mod github;
mod kitty;
mod linear;
mod markdown;
mod open;
mod stacks;
mod tui;

use anyhow::{bail, Context, Result};

const USAGE: &str = "usage: reviews [--out FILE] [QUERY...] | reviews open --pr URL | reviews open --mine URL BRANCH | reviews --refresh | reviews --json";

fn open_args(args: &[String]) -> Result<open::Pick> {
    match args {
        [flag, url] if flag == "--pr" => Ok(open::Pick::Review { url: url.clone() }),
        [flag, url, branch] if flag == "--mine" => Ok(open::Pick::Mine {
            url: url.clone(),
            branch: branch.clone(),
        }),
        _ => bail!("{USAGE}"),
    }
}

fn main() -> Result<()> {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    if argv.first().is_some_and(|a| a == "open") {
        let pick = open_args(&argv[1..])?;
        std::process::exit(open::run(pick));
    }
    let mut out = None;
    let mut query = Vec::new();
    let mut args = argv.into_iter();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--out" => out = Some(args.next().context("--out needs a file")?),
            "--refresh" => return github::refresh(&github::Cache::from_env()),
            "--json" => return feed::print(&github::Cache::from_env()),
            "-h" | "--help" => {
                println!("{USAGE}");
                return Ok(());
            }
            flag if flag.starts_with('-') => bail!("unknown option {flag}"),
            _ => query.push(arg),
        }
    }

    let Some((pr, tab)) = tui::pick(query.join(" "))? else {
        // Nothing picked is no failure, unless a caller waits for the pick.
        std::process::exit(if out.is_some() { 1 } else { 0 });
    };
    let kind = match tab {
        tui::Tab::Mine => "mine",
        tui::Tab::Requested | tui::Tab::Reviewed => "review",
    };
    let Some(path) = out else {
        let pick = match tab {
            tui::Tab::Mine => open::Pick::Mine {
                url: pr.url,
                branch: pr.branch,
            },
            tui::Tab::Requested | tui::Tab::Reviewed => open::Pick::Review { url: pr.url },
        };
        std::process::exit(open::run(pick));
    };
    let line = format!("{kind}\t{}\t{}\t{}\n", pr.repo, pr.url, pr.branch);
    std::fs::write(&path, line).with_context(|| format!("writing {path}"))?;
    Ok(())
}
