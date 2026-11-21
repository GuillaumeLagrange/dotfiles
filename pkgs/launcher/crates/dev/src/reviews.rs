//! The PRs of `reviews --json`, by tab, without the stale ones (as the bar's panel shows them).

use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{bail, Context, Result};
use launcher_core::{Action, Ctx, Entry, Icon, Mode, Outcome, Source, Status};
use serde::Deserialize;

use crate::argv;

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct Config {
    pub command: String,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            command: "reviews".into(),
        }
    }
}

#[derive(Debug, Deserialize)]
struct Feed {
    requested: Tab,
    reviewed: Tab,
    mine: Tab,
}

#[derive(Debug, Deserialize)]
struct Tab {
    rows: Vec<Row>,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
enum Row {
    Stack {},
    Pr(Box<Pr>),
}

#[derive(Debug, Clone, Deserialize)]
struct Pr {
    number: u64,
    title: String,
    url: String,
    branch: String,
    state: String,
    #[serde(default)]
    draft: bool,
    updated_at: u64,
    listed: bool,
    repo: String,
    author: String,
    avatar: Option<String>,
    #[serde(default)]
    linear: Vec<Issue>,
}

#[derive(Debug, Clone, Deserialize)]
struct Issue {
    identifier: String,
    url: String,
}

struct Item {
    /// The tab's heading.
    tab: &'static str,
    pr: Pr,
}

impl Item {
    /// A PR can be in two tabs.
    fn id(&self) -> String {
        format!("{}:{}", self.tab, self.pr.url)
    }
}

#[derive(Default)]
struct State {
    entries: Arc<Vec<Entry>>,
    items: Arc<Vec<Item>>,
    status: Option<Status>,
    loading: bool,
}

pub struct Reviews {
    config: Config,
    state: Arc<Mutex<State>>,
}

impl Reviews {
    pub fn new(config: Config) -> Reviews {
        Reviews {
            config,
            state: Arc::default(),
        }
    }
}

impl Source for Reviews {
    fn mode(&self) -> Mode {
        Mode::Reviews
    }

    fn open(&mut self, ctx: &Ctx) {
        {
            let mut state = self.state.lock().unwrap();
            if state.loading {
                return;
            }
            state.loading = true;
            if state.entries.is_empty() {
                state.status = Some(Status::loading("Loading pull requests…"));
            }
        }
        let (state, command, ctx) = (self.state.clone(), self.config.command.clone(), ctx.clone());
        std::thread::spawn(move || {
            let result = feed(&command);
            let mut state = state.lock().unwrap();
            state.loading = false;
            match result {
                Ok(items) => {
                    state.entries = Arc::new(entries(&items, now()));
                    state.items = Arc::new(items);
                    state.status = None;
                }
                Err(err) => state.status = Some(Status::error(format!("{err:#}"))),
            }
            drop(state);
            ctx.updated(Mode::Reviews);
        });
    }

    fn entries(&self) -> Arc<Vec<Entry>> {
        self.state.lock().unwrap().entries.clone()
    }

    fn status(&self) -> Option<Status> {
        self.state.lock().unwrap().status.clone()
    }

    fn activate(&mut self, id: &str, action: &str, ctx: &Ctx) -> Outcome {
        let items = self.state.lock().unwrap().items.clone();
        let Some(item) = items.iter().find(|item| item.id() == id) else {
            return Outcome::Error(format!("no pull request {id}"));
        };
        let pr = &item.pr;
        let cmd = self.config.command.as_str();
        match action {
            "open" if item.tab == "Mine" => {
                ctx.spawn(&argv(&[cmd, "open", "--mine", &pr.url, &pr.branch]))
            }
            "open" => ctx.spawn(&argv(&[cmd, "open", "--pr", &pr.url])),
            "browser" => ctx.open(&pr.url),
            other => match other
                .strip_prefix("linear:")
                .and_then(|ident| pr.linear.iter().find(|i| i.identifier == ident))
            {
                Some(issue) => ctx.open(&issue.url),
                None => Outcome::Error(format!("unknown action {other}")),
            },
        }
    }
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

fn feed(command: &str) -> Result<Vec<Item>> {
    let out = Command::new(command)
        .arg("--json")
        .stdin(Stdio::null())
        .output()
        .with_context(|| format!("running {command} --json"))?;
    if !out.status.success() {
        bail!(
            "{command} --json: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    let feed: Feed =
        serde_json::from_slice(&out.stdout).with_context(|| format!("parsing {command} --json"))?;
    let mut items = Vec::new();
    for (tab, name) in [
        (feed.requested, "Requested"),
        (feed.reviewed, "Reviewed"),
        (feed.mine, "Mine"),
    ] {
        for row in tab.rows {
            // As the panel: the PRs asked of me, and open members of their stacks.
            if let Row::Pr(pr) = row {
                if pr.listed || pr.state == "Open" {
                    items.push(Item { tab: name, pr: *pr });
                }
            }
        }
    }
    Ok(items)
}

fn age(secs: u64) -> String {
    match secs {
        s if s < 3600 => format!("{}m", s / 60),
        s if s < 86400 => format!("{}h", s / 3600),
        s if s < 86400 * 7 => format!("{}d", s / 86400),
        s => format!("{}w", s / (86400 * 7)),
    }
}

fn entries(items: &[Item], now: u64) -> Vec<Entry> {
    items
        .iter()
        .map(|item| {
            let pr = &item.pr;
            let mut actions = vec![
                Action::new("open", "Open", Some("Return")),
                Action::new("browser", "Open on GitHub", Some("Alt+Return")),
            ];
            for issue in &pr.linear {
                actions.push(Action::new(
                    &format!("linear:{}", issue.identifier),
                    &format!("Open {}", issue.identifier),
                    None,
                ));
            }
            let mut entry = Entry::new(item.id(), pr.title.clone(), Arc::from(actions));
            entry.subtitle = format!("{}#{} · {}", pr.repo, pr.number, pr.author);
            let mut keywords = vec![pr.branch.clone()];
            keywords.extend(pr.linear.iter().map(|l| l.identifier.clone()));
            entry.keywords = keywords.join(" ");
            entry.accessory = match pr.state.as_str() {
                "Open" if pr.draft => "draft".into(),
                "Open" => age(now.saturating_sub(pr.updated_at)),
                state => state.to_lowercase(),
            };
            entry.icon = match pr.avatar.as_deref() {
                Some(a) if a.starts_with("file://") => {
                    Icon::Path(a.trim_start_matches("file://").into())
                }
                _ => Icon::Glyph("reviews".into()),
            };
            entry.section = item.tab.into();
            entry
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;
    use crate::testing::Fixture;

    fn feed_json(now: u64, avatar: &str) -> String {
        let pr = |n: u64, state: &str, listed: bool, linear: &str| {
            format!(
                r#"{{"kind":"pr","place":"alone","number":{n},"title":"PR {n}","url":"https://github.com/o/app/pull/{n}","branch":"b{n}","state":"{state}","draft":false,"updated_at":{},"listed":{listed},"additions":1,"deletions":1,"repo":"app","author":"ann","avatar":{avatar},"decision":null,"checks":null,"linear":[{linear}]}}"#,
                now - 7200
            )
        };
        let issue = r#"{"identifier":"COD-1","title":"t","url":"https://linear.app/x/COD-1","state":"In Review","kind":"started"}"#;
        format!(
            r#"{{"snapshot":"/x","fetched_at":1,
            "requested":{{"count":1,"stale":0,"rows":[{{"kind":"stack","repo":"app","size":2,"base":"main"}},{},{}],"all":[]}},
            "reviewed":{{"count":1,"stale":1,"rows":[{}],"all":[{}]}},
            "mine":{{"count":1,"stale":0,"rows":[{}],"all":[]}}}}"#,
            pr(1, "Open", true, issue),
            pr(2, "Merged", false, ""),
            pr(3, "Merged", true, ""),
            pr(4, "Open", true, ""),
            pr(5, "Open", true, ""),
        )
    }

    fn opened(fx: &Fixture, avatar: &str) -> Reviews {
        let json = feed_json(now(), avatar);
        fx.write("feed.json", &json);
        fx.stub(
            "reviews",
            &format!(
                "#!/bin/sh\n[ \"$1\" = --json ] || exit 2\ncat {}\n",
                fx.root().join("feed.json").display()
            ),
        );
        let mut source = Reviews::new(Config::default());
        source.open(&fx.ctx);
        assert!(fx
            .handles
            .wait_updated(Mode::Reviews, Duration::from_secs(10)));
        source
    }

    #[test]
    fn lists_pickable_prs_by_tab_without_stale_ones() {
        let fx = Fixture::new(&[Mode::Reviews]);
        let avatar = fx.write("ann.png", "");
        let source = opened(&fx, &format!("\"file://{}\"", avatar.display()));
        let entries = source.entries();
        let rows: Vec<(&str, &str, &str, &str)> = entries
            .iter()
            .map(|e| {
                (
                    e.section.as_str(),
                    e.title.as_str(),
                    e.subtitle.as_str(),
                    e.accessory.as_str(),
                )
            })
            .collect();
        assert_eq!(
            rows,
            [
                ("Requested", "PR 1", "app#1 · ann", "2h"),
                ("Reviewed", "PR 3", "app#3 · ann", "merged"),
                ("Mine", "PR 5", "app#5 · ann", "2h"),
            ]
        );
        assert_eq!(entries[0].keywords, "b1 COD-1");
        assert_eq!(entries[0].icon, Icon::Path(avatar));
        let actions: Vec<&str> = entries[0].actions.iter().map(|a| a.id.as_str()).collect();
        assert_eq!(actions, ["open", "browser", "linear:COD-1"]);
    }

    #[test]
    fn actions_hand_their_argv_to_niri() {
        let fx = Fixture::new(&[Mode::Reviews]);
        let mut source = opened(&fx, "null");
        let entries = source.entries();
        assert_eq!(entries[0].icon, Icon::Glyph("reviews".into()));
        let (requested, mine) = (entries[0].id.clone(), entries[2].id.clone());
        assert_eq!(source.activate(&requested, "open", &fx.ctx), Outcome::Close);
        assert_eq!(source.activate(&mine, "open", &fx.ctx), Outcome::Close);
        assert_eq!(
            source.activate(&requested, "browser", &fx.ctx),
            Outcome::Close
        );
        assert_eq!(
            source.activate(&requested, "linear:COD-1", &fx.ctx),
            Outcome::Close
        );
        assert_eq!(
            fx.spawned(),
            [
                "reviews open --pr https://github.com/o/app/pull/1",
                "reviews open --mine https://github.com/o/app/pull/5 b5",
                "xdg-open https://github.com/o/app/pull/1",
                "xdg-open https://linear.app/x/COD-1",
            ]
        );
    }

    #[test]
    fn a_failing_command_is_an_error_status() {
        let fx = Fixture::new(&[Mode::Reviews]);
        fx.stub("reviews", "#!/bin/sh\necho 'no cache' >&2\nexit 1\n");
        let mut source = Reviews::new(Config::default());
        source.open(&fx.ctx);
        assert!(fx
            .handles
            .wait_updated(Mode::Reviews, Duration::from_secs(10)));
        assert_eq!(
            source.status(),
            Some(Status::error("reviews --json: no cache"))
        );
        assert!(source.entries().is_empty());
    }
}
