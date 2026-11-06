//! `reviews --json`: the cached lists laid out as the picker shows them, for
//! the bar's pill and its panel.

use std::path::PathBuf;

use anyhow::Result;
use serde::Serialize;

use crate::github::{Cache, Checks, Decision, Pr, Query, State};
use crate::linear::Issue;
use crate::stacks::{self, stacks, Place, Row};

#[derive(Serialize)]
struct Feed<'a> {
    /// Rewritten on every refresh: watch it to know when to ask again.
    snapshot: PathBuf,
    /// `None` until a first refresh.
    fetched_at: Option<u64>,
    requested: Tab<'a>,
    reviewed: Tab<'a>,
    mine: Tab<'a>,
}

#[derive(Serialize)]
struct Tab<'a> {
    /// Pull requests the tab's search found and not stale; the rest are stack
    /// members.
    count: usize,
    /// Those found but hidden as stale.
    stale: usize,
    /// Without the stale ones.
    rows: Vec<FeedRow<'a>>,
    /// With them.
    all: Vec<FeedRow<'a>>,
}

#[derive(Serialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
enum FeedRow<'a> {
    Stack {
        repo: &'a str,
        size: u64,
        base: &'a str,
    },
    Pr {
        /// `alone`, `child`, or `last` (the last child of its stack).
        place: &'static str,
        number: u64,
        title: &'a str,
        url: &'a str,
        branch: &'a str,
        state: State,
        draft: bool,
        updated_at: u64,
        listed: bool,
        additions: u64,
        deletions: u64,
        repo: &'a str,
        author: &'a str,
        /// The cached file as a `file://` URL, else GitHub's.
        avatar: Option<String>,
        decision: Option<Decision>,
        checks: Option<Checks>,
        linear: &'a [Issue],
    },
}

fn row<'a>(cache: &Cache, prs: &'a [Pr], row: Row) -> FeedRow<'a> {
    match row {
        Row::Stack { pr } => {
            let pr = &prs[pr];
            let stack = pr
                .stack
                .as_ref()
                .expect("a stack row's member is in a stack");
            FeedRow::Stack {
                repo: &pr.repo,
                size: stack.size,
                base: &stack.base,
            }
        }
        Row::Pr { pr, place } => {
            let pr = &prs[pr];
            let cached = cache.avatar_path(&pr.author);
            let avatar = if cached.is_file() {
                Some(format!("file://{}", cached.display()))
            } else {
                pr.avatar_url.clone()
            };
            FeedRow::Pr {
                place: match place {
                    Place::Alone => "alone",
                    Place::Child { last: false } => "child",
                    Place::Child { last: true } => "last",
                },
                number: pr.number,
                title: &pr.title,
                url: &pr.url,
                branch: &pr.branch,
                state: pr.state,
                draft: pr.draft,
                updated_at: pr.updated_at,
                listed: pr.listed,
                additions: pr.additions,
                deletions: pr.deletions,
                repo: &pr.repo,
                author: &pr.author,
                avatar,
                decision: pr.decision,
                checks: pr.checks,
                linear: &pr.linear,
            }
        }
    }
}

fn tab<'a>(cache: &Cache, prs: &'a [Pr]) -> Tab<'a> {
    let now = crate::github::now();
    let layout = |shown: Vec<usize>| -> Vec<FeedRow<'a>> {
        stacks(prs, shown)
            .into_iter()
            .map(|r| row(cache, prs, r))
            .collect()
    };
    let (stale, fresh): (Vec<usize>, Vec<usize>) =
        (0..prs.len()).partition(|&i| stacks::stale(prs, i, now));
    Tab {
        count: fresh.iter().filter(|&&i| prs[i].listed).count(),
        stale: stale.iter().filter(|&&i| prs[i].listed).count(),
        rows: layout(fresh),
        all: layout((0..prs.len()).collect()),
    }
}

pub fn print(cache: &Cache) -> Result<()> {
    let snapshot = cache.read();
    let list = |query| snapshot.as_ref().map_or(&[][..], |s| s.lists.get(query));
    let feed = Feed {
        snapshot: cache.snapshot_path(),
        fetched_at: snapshot.as_ref().map(|s| s.fetched_at),
        requested: tab(cache, list(Query::Requested)),
        reviewed: tab(cache, list(Query::Reviewed)),
        mine: tab(cache, list(Query::Mine)),
    };
    println!("{}", serde_json::to_string(&feed)?);
    Ok(())
}
