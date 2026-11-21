//! zellij sessions, live and resurrectable, in zellij-sessions' order: zsm's picker.

use std::collections::BTreeSet;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result};
use launcher_core::{Action, Ctx, Entry, Icon, Mode, Outcome, Source, Status};
use zellij_sessions::Store;

use crate::argv;

#[derive(Debug, Clone, PartialEq, Eq)]
struct Listed {
    name: String,
    exited: bool,
}

#[derive(Default)]
struct State {
    entries: Arc<Vec<Entry>>,
    status: Option<Status>,
    /// Bumped by each refresh; an older refresh's result is dropped.
    generation: u64,
}

pub struct Sessions {
    state: Arc<Mutex<State>>,
    actions: Arc<[Action]>,
    new_actions: Arc<[Action]>,
}

impl Default for Sessions {
    fn default() -> Self {
        Self::new()
    }
}

impl Sessions {
    pub fn new() -> Sessions {
        Sessions {
            state: Arc::default(),
            actions: Arc::from(vec![
                Action::new("open", "Open", Some("Return")),
                Action::new("here", "Open in a new window", Some("Alt+Return")),
                Action::new("restart", "Restart", Some("Ctrl+R")),
                Action::new("delete", "Delete session", Some("Shift+Delete")),
            ]),
            new_actions: Arc::from(vec![Action::new("open", "Create", Some("Return"))]),
        }
    }

    fn refresh(&self, ctx: &Ctx) {
        let generation = {
            let mut state = self.state.lock().unwrap();
            state.generation += 1;
            if state.entries.is_empty() {
                state.status = Some(Status::loading("Listing sessions…"));
            }
            state.generation
        };
        let (state, actions, ctx) = (self.state.clone(), self.actions.clone(), ctx.clone());
        std::thread::spawn(move || {
            let result = listing().map(|listed| entries(listed, &Store::from_env(), &actions));
            let mut state = state.lock().unwrap();
            if state.generation != generation {
                return;
            }
            match result {
                Ok(entries) => {
                    state.entries = Arc::new(entries);
                    state.status = None;
                }
                Err(err) => state.status = Some(Status::error(format!("{err:#}"))),
            }
            drop(state);
            ctx.updated(Mode::Sessions);
        });
    }

    fn remove(&self, name: &str) {
        let mut state = self.state.lock().unwrap();
        let entries: Vec<Entry> = state
            .entries
            .iter()
            .filter(|e| e.id != name)
            .cloned()
            .collect();
        state.entries = Arc::new(entries);
    }
}

fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && !name.starts_with('-')
        && name.len() <= 64
        && name
            .chars()
            .all(|c| c.is_alphanumeric() || "-_.".contains(c))
}

impl Source for Sessions {
    fn mode(&self) -> Mode {
        Mode::Sessions
    }

    fn open(&mut self, ctx: &Ctx) {
        self.refresh(ctx);
    }

    fn entries(&self) -> Arc<Vec<Entry>> {
        self.state.lock().unwrap().entries.clone()
    }

    fn status(&self) -> Option<Status> {
        self.state.lock().unwrap().status.clone()
    }

    fn extra(&self, query: &str) -> Vec<Entry> {
        let name = query.trim();
        if !valid_name(name)
            || self
                .state
                .lock()
                .unwrap()
                .entries
                .iter()
                .any(|e| e.id == name)
        {
            return Vec::new();
        }
        let mut entry = Entry::new(
            format!("new:{name}"),
            format!("New session «{name}»"),
            self.new_actions.clone(),
        );
        entry.icon = Icon::Glyph("sessions".into());
        vec![entry]
    }

    fn activate(&mut self, id: &str, action: &str, ctx: &Ctx) -> Outcome {
        if let Some(name) = id.strip_prefix("new:") {
            return ctx.spawn(&argv(&["zellij-attach", "--focus", name]));
        }
        let name = id;
        match action {
            "open" => ctx.spawn(&argv(&["zellij-attach", "--focus", name])),
            "here" => {
                // xdg-terminal-exec takes the window's app id; zellij-attach in a zellij-session
                // window attaches in place even when another window shows the session.
                let mut args = Vec::new();
                if ctx
                    .config
                    .terminal
                    .first()
                    .is_some_and(|t| t.ends_with("xdg-terminal-exec"))
                {
                    args.push("--app-id=zellij-session".to_owned());
                }
                args.extend(argv(&["zellij-attach", name]));
                ctx.spawn_in_terminal(&args)
            }
            "restart" => {
                let (name, ctx) = (name.to_owned(), ctx.clone());
                std::thread::spawn(move || {
                    let result = restart(&name).and_then(|()| {
                        match ctx.spawn(&argv(&["zellij-attach", "--focus", &name])) {
                            Outcome::Error(err) => Err(anyhow::anyhow!(err)),
                            _ => Ok(()),
                        }
                    });
                    if let Err(err) = result {
                        ctx.notify(&format!("Could not restart {name}"), &format!("{err:#}"));
                    }
                });
                Outcome::Close
            }
            "delete" => {
                self.remove(name);
                let (owned, ctx2) = (name.to_owned(), ctx.clone());
                let this = Sessions {
                    state: self.state.clone(),
                    actions: self.actions.clone(),
                    new_actions: self.new_actions.clone(),
                };
                std::thread::spawn(move || {
                    if let Err(err) = delete(&owned) {
                        ctx2.notify(&format!("Could not delete {owned}"), &format!("{err:#}"));
                    }
                    this.refresh(&ctx2);
                });
                Outcome::Stay
            }
            other => Outcome::Error(format!("unknown action {other}")),
        }
    }
}

fn zellij(args: &[&str]) -> Result<std::process::Output> {
    Command::new("zellij")
        .args(args)
        .stdin(Stdio::null())
        .output()
        .with_context(|| format!("running zellij {}", args.join(" ")))
}

fn list_once() -> Result<Vec<Listed>> {
    // No sessions at all is a non-zero exit, not a failure to answer.
    let out = zellij(&["list-sessions", "--no-formatting"])?;
    Ok(String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|line| {
            let name = line.split_whitespace().next()?;
            Some(Listed {
                name: name.to_owned(),
                exited: line.contains("EXITED"),
            })
        })
        .collect())
}

/// Two listings merged: zellij's can leave a live session out, so a session either shows
/// live is live.
fn listing() -> Result<Vec<Listed>> {
    let mut merged: Vec<Listed> = list_once()?;
    for listed in list_once()? {
        match merged.iter_mut().find(|l| l.name == listed.name) {
            Some(known) => known.exited &= listed.exited,
            None => merged.push(listed),
        }
    }
    Ok(merged)
}

fn entries(listed: Vec<Listed>, store: &Store, actions: &Arc<[Action]>) -> Vec<Entry> {
    let registry = store.load();
    let palette = store.palette();
    let exited: BTreeSet<String> = listed
        .iter()
        .filter(|l| l.exited)
        .map(|l| l.name.clone())
        .collect();
    let mut names: Vec<String> = listed.into_iter().map(|l| l.name).collect();
    registry.sort(&mut names);
    // Stable: registry order holds within each group.
    names.sort_by_key(|n| exited.contains(n));
    names
        .into_iter()
        .map(|name| {
            let mut entry = Entry::new(name.clone(), name.clone(), actions.clone());
            entry.icon = Icon::Glyph("sessions".into());
            entry.color = registry.swatch(&name, &palette).map(|s| s.color.clone());
            if exited.contains(&name) {
                entry.accessory = "exited".into();
            }
            entry
        })
        .collect()
}

/// Kills the session until several listings in a row agree it is down: the kill can be lost
/// or return early.
fn restart(name: &str) -> Result<()> {
    let mut down = 0;
    for _ in 0..100 {
        let live = list_once()?.iter().any(|l| l.name == name && !l.exited);
        if live {
            down = 0;
            zellij(&["kill-session", name])?;
        } else {
            down += 1;
            if down >= 3 {
                return Ok(());
            }
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    anyhow::bail!("{name} did not stop")
}

fn delete(name: &str) -> Result<()> {
    let out = zellij(&["delete-session", "--force", name])?;
    let stderr = String::from_utf8_lossy(&out.stderr);
    // Nothing to delete is the state being asked for.
    if !out.status.success() && !stderr.contains("not found") {
        anyhow::bail!("{}", stderr.trim());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::Fixture;

    const ZELLIJ: &str = r#"#!/bin/sh
echo "$*" >> "$STUB_LOG/zellij"
case "$1" in
list-sessions)
  n=$(cat "$STUB_LOG/count" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > "$STUB_LOG/count"
  if [ -e "$STUB_LOG/killed" ]; then
    echo "work [Created 1h ago] (EXITED - attach to resurrect)"
  elif [ "$n" = 1 ]; then
    echo "work [Created 1h ago]"
  else
    echo "work [Created 1h ago]"; echo "alpha [Created 2h ago] (current)"
  fi
  echo "zeta [Created 1d ago]"
  echo "old [Created 3d ago] (EXITED - attach to resurrect)"
  ;;
kill-session) touch "$STUB_LOG/killed" ;;
delete-session) ;;
esac
"#;

    fn fixture() -> Fixture {
        let fx = Fixture::new(&[Mode::Sessions]);
        fx.stub("zellij", ZELLIJ);
        fx.write(
            "config/zellij-sessions/palette.json",
            r##"[{"name":"red","color":"#ff0000"},{"name":"blue","color":"#0000ff"}]"##,
        );
        fx.write(
            "state/zellij-sessions/sessions.json",
            r#"{"sessions":[{"name":"zeta","color":"blue"},{"name":"old"},{"name":"work","color":"red"}]}"#,
        );
        fx
    }

    fn opened(fx: &Fixture) -> Sessions {
        let mut source = Sessions::new();
        source.open(&fx.ctx);
        assert!(fx
            .handles
            .wait_updated(Mode::Sessions, Duration::from_secs(10)));
        source
    }

    #[test]
    fn lists_in_registry_order_live_first_and_keeps_a_session_one_listing_missed() {
        let fx = fixture();
        let source = opened(&fx);
        let entries = source.entries();
        let rows: Vec<(&str, Option<&str>, &str)> = entries
            .iter()
            .map(|e| (e.title.as_str(), e.color.as_deref(), e.accessory.as_str()))
            .collect();
        assert_eq!(
            rows,
            [
                ("zeta", Some("#0000ff"), ""),
                ("work", Some("#ff0000"), ""),
                ("alpha", None, ""),
                ("old", None, "exited"),
            ]
        );
        assert_eq!(entries[0].icon, Icon::Glyph("sessions".into()));
        assert_eq!(source.status(), None);
    }

    #[test]
    fn actions_hand_their_argv_to_niri() {
        let fx = fixture();
        let mut source = opened(&fx);
        assert_eq!(source.activate("work", "open", &fx.ctx), Outcome::Close);
        assert_eq!(source.activate("work", "here", &fx.ctx), Outcome::Close);
        assert_eq!(
            source.activate("new:fresh", "open", &fx.ctx),
            Outcome::Close
        );
        assert_eq!(
            fx.spawned(),
            [
                "zellij-attach --focus work",
                "xdg-terminal-exec --app-id=zellij-session zellij-attach work",
                "zellij-attach --focus fresh",
            ]
        );
    }

    #[test]
    fn a_new_session_row_only_for_an_unlisted_valid_name() {
        let fx = fixture();
        let source = opened(&fx);
        let extra = source.extra(" fresh ");
        assert_eq!(extra.len(), 1);
        assert_eq!(extra[0].id, "new:fresh");
        assert_eq!(extra[0].title, "New session «fresh»");
        assert!(source.extra("work").is_empty());
        assert!(source.extra("two words").is_empty());
        assert!(source.extra("").is_empty());
    }

    #[test]
    fn restart_kills_until_down_then_attaches() {
        let fx = fixture();
        let mut source = opened(&fx);
        assert_eq!(source.activate("work", "restart", &fx.ctx), Outcome::Close);
        let spawned = fx.wait_spawned(1);
        assert_eq!(spawned, ["zellij-attach --focus work"]);
        let calls = fx.log("zellij");
        assert_eq!(
            calls.iter().filter(|c| *c == "kill-session work").count(),
            1
        );
    }

    #[test]
    fn delete_removes_the_row_and_runs_delete_session() {
        let fx = fixture();
        let mut source = opened(&fx);
        assert_eq!(source.activate("old", "delete", &fx.ctx), Outcome::Stay);
        assert!(source.entries().iter().all(|e| e.id != "old"));
        assert!(fx
            .handles
            .wait_updated(Mode::Sessions, Duration::from_secs(10)));
        assert!(fx
            .log("zellij")
            .contains(&"delete-session --force old".to_owned()));
    }
}
