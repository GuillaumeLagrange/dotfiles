//! Proton Pass (pass-cli) and 1Password (op) items.
//!
//! Lists only metadata (titles, usernames, urls, ids, vault names); secrets are fetched on
//! activation and handed straight to the clipboard.

use std::collections::HashMap;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use launcher_core::{Action, Ctx, Entry, Icon, Mode, Outcome, Preview, Source, Status, Work};
use serde::Deserialize;

mod onepassword;
mod proton;

#[cfg(test)]
mod tests;

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Config {
    #[serde(default)]
    pub proton: Option<Manager>,
    #[serde(default)]
    pub onepassword: Option<Manager>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Manager {
    pub command: String,
}

/// The enabled ones of: Passwords.
pub fn sources(ctx: &Ctx) -> anyhow::Result<Vec<Box<dyn Source>>> {
    if !ctx.config.enabled(Mode::Passwords) {
        return Ok(Vec::new());
    }
    Ok(vec![Box::new(Passwords::new(
        ctx.section(Mode::Passwords)?,
    ))])
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Kind {
    Proton,
    OnePassword,
}

impl Kind {
    fn name(self) -> &'static str {
        match self {
            Kind::Proton => "Proton Pass",
            Kind::OnePassword => "1Password",
        }
    }
}

/// One listed item: what activation and preview need, never a secret.
#[derive(Debug, Clone)]
struct Item {
    kind: Kind,
    /// Proton share id, 1Password vault id.
    container: String,
    item: String,
    title: String,
    username: Option<String>,
    urls: Vec<String>,
    vault: String,
    /// Has a username field (1Password's Password category has none).
    login: bool,
}

/// What one manager's listing yields.
enum Listing {
    Items(Vec<Item>),
    LoggedOut,
    Failed(String),
}

#[derive(Default)]
struct Snapshot {
    entries: Arc<Vec<Entry>>,
    items: HashMap<String, Item>,
    logged_out: bool,
    errors: Vec<String>,
}

const LOGIN_ID: &str = "proton:login";

pub struct Passwords {
    config: Config,
    snapshot: Arc<Mutex<Option<Snapshot>>>,
    refreshing: Arc<AtomicBool>,
}

impl Passwords {
    pub fn new(config: Config) -> Passwords {
        Passwords {
            config,
            snapshot: Arc::new(Mutex::new(None)),
            refreshing: Arc::new(AtomicBool::new(false)),
        }
    }

    fn item(&self, id: &str) -> Option<Item> {
        self.snapshot
            .lock()
            .unwrap()
            .as_ref()?
            .items
            .get(id)
            .cloned()
    }

    fn manager(&self, kind: Kind) -> Option<&Manager> {
        match kind {
            Kind::Proton => self.config.proton.as_ref(),
            Kind::OnePassword => self.config.onepassword.as_ref(),
        }
    }
}

impl Source for Passwords {
    fn mode(&self) -> Mode {
        Mode::Passwords
    }

    fn open(&mut self, ctx: &Ctx) {
        if self.refreshing.swap(true, Ordering::SeqCst) {
            return;
        }
        let (config, snapshot, refreshing, ctx) = (
            self.config.clone(),
            self.snapshot.clone(),
            self.refreshing.clone(),
            ctx.clone(),
        );
        std::thread::spawn(move || {
            let fresh = load(&config);
            *snapshot.lock().unwrap() = Some(fresh);
            refreshing.store(false, Ordering::SeqCst);
            ctx.updated(Mode::Passwords);
        });
    }

    fn entries(&self) -> Arc<Vec<Entry>> {
        match &*self.snapshot.lock().unwrap() {
            Some(s) => s.entries.clone(),
            None => Arc::new(Vec::new()),
        }
    }

    fn status(&self) -> Option<Status> {
        let snapshot = self.snapshot.lock().unwrap();
        let Some(s) = snapshot.as_ref() else {
            if !self.refreshing.load(Ordering::SeqCst) {
                return None;
            }
            let names: Vec<&str> = [
                self.config.proton.as_ref().map(|_| Kind::Proton.name()),
                self.config
                    .onepassword
                    .as_ref()
                    .map(|_| Kind::OnePassword.name()),
            ]
            .into_iter()
            .flatten()
            .collect();
            return Some(Status::loading(format!("Loading {}…", names.join(" and "))));
        };
        if !s.errors.is_empty() {
            return Some(Status::error(s.errors.join("; ")));
        }
        s.logged_out
            .then(|| Status::info("Proton Pass: not logged in"))
    }

    fn frecency(&self) -> bool {
        true
    }

    fn activate(&mut self, id: &str, action: &str, ctx: &Ctx) -> Outcome {
        if id == LOGIN_ID {
            return match &self.config.proton {
                Some(m) => ctx.spawn_in_terminal(&[m.command.clone(), "login".to_owned()]),
                None => Outcome::Error("Proton Pass is not configured".to_owned()),
            };
        }
        let Some(item) = self.item(id) else {
            return Outcome::Error(format!("unknown item {id}"));
        };
        let Some(command) = self.manager(item.kind).map(|m| m.command.clone()) else {
            return Outcome::Error(format!("{} is not configured", item.kind.name()));
        };
        if action == "open-url" {
            return match item.urls.first() {
                Some(url) => ctx.open(url),
                None => Outcome::Error("no URL".to_owned()),
            };
        }
        let (secret, what) = match action {
            "password" => (true, "password"),
            "totp" => (true, "one-time code"),
            "username" => (false, "username"),
            _ => return Outcome::Error(format!("unknown action {action}")),
        };
        let action = action.to_owned();
        let ctx = ctx.clone();
        // The panel stays until the clipboard holds the value: a fetch takes over a second,
        // and a paste meanwhile would paste what was there before.
        Outcome::Wait {
            status: format!("Copying the {what}\u{2026}"),
            work: Work::new(move || {
                let value = match item.kind {
                    Kind::Proton => proton::fetch(&command, &item, &action),
                    Kind::OnePassword => onepassword::fetch(&command, &item, &action),
                }
                .map_err(|err| format!("Copying the {what} failed: {err}"))?;
                if secret {
                    ctx.clipboard.copy_secret(&value);
                } else {
                    ctx.clipboard.copy_text(&value);
                }
                Ok(())
            }),
        }
    }

    fn preview(&self, id: &str, _ctx: &Ctx) -> Option<Preview> {
        let item = self.item(id)?;
        let mut fields = Vec::new();
        if let Some(user) = &item.username {
            fields.push(("Username".to_owned(), user.clone()));
        }
        if !item.urls.is_empty() {
            fields.push(("URLs".to_owned(), item.urls.join("\n")));
        }
        fields.push(("Vault".to_owned(), item.vault.clone()));
        fields.push(("Manager".to_owned(), item.kind.name().to_owned()));
        Some(Preview::Fields { fields })
    }
}

fn load(config: &Config) -> Snapshot {
    let (proton, onepassword) = std::thread::scope(|s| {
        let p = config
            .proton
            .as_ref()
            .map(|m| s.spawn(|| proton::list(&m.command)));
        let o = config
            .onepassword
            .as_ref()
            .map(|m| s.spawn(|| onepassword::list(&m.command)));
        (p.map(|h| h.join().unwrap()), o.map(|h| h.join().unwrap()))
    });
    let mut snapshot = Snapshot::default();
    let mut entries = Vec::new();
    for (kind, listing) in [(Kind::Proton, proton), (Kind::OnePassword, onepassword)] {
        match listing {
            None => {}
            Some(Listing::LoggedOut) => {
                snapshot.logged_out = true;
                let mut login = Entry::new(
                    LOGIN_ID,
                    "Log in to Proton Pass",
                    Arc::from([Action::new("login", "Log in", Some("Return"))]),
                );
                login.subtitle = "Opens pass-cli login in a terminal".to_owned();
                login.icon = icon(kind);
                login.section = kind.name().to_owned();
                entries.insert(0, login);
            }
            Some(Listing::Failed(err)) => snapshot.errors.push(format!("{}: {err}", kind.name())),
            Some(Listing::Items(mut items)) => {
                items.sort_by_cached_key(|i| i.title.to_lowercase());
                for item in items {
                    let entry = entry(&item);
                    snapshot.items.insert(entry.id.clone(), item);
                    entries.push(entry);
                }
            }
        }
    }
    snapshot.entries = Arc::new(entries);
    snapshot
}

fn icon(kind: Kind) -> Icon {
    Icon::Name(
        match kind {
            Kind::Proton => "proton-pass",
            Kind::OnePassword => "1password",
        }
        .to_owned(),
    )
}

fn entry(item: &Item) -> Entry {
    let prefix = match item.kind {
        Kind::Proton => "proton",
        Kind::OnePassword => "op",
    };
    let mut actions = vec![Action::new("password", "Copy password", Some("Return"))];
    if item.login {
        actions.push(Action::new("username", "Copy username", Some("Alt+Return")));
        actions.push(Action::new(
            "totp",
            "Copy one-time code",
            Some("Ctrl+Return"),
        ));
    }
    if !item.urls.is_empty() {
        actions.push(Action::new("open-url", "Open URL", None));
    }
    let hosts: Vec<&str> = item.urls.iter().map(|u| host(u)).collect();
    let mut e = Entry::new(
        format!("{prefix}:{}:{}", item.container, item.item),
        item.title.clone(),
        Arc::from(actions),
    );
    e.subtitle = item
        .username
        .clone()
        .or_else(|| hosts.first().map(|h| (*h).to_owned()))
        .unwrap_or_default();
    e.keywords = format!("{} {} {}", hosts.join(" "), item.vault, item.kind.name());
    e.accessory = format!(
        "{} · {}",
        match item.kind {
            Kind::Proton => "Proton",
            Kind::OnePassword => "1Password",
        },
        item.vault
    );
    e.icon = icon(item.kind);
    e.section = item.kind.name().to_owned();
    e.preview = true;
    e
}

/// The host of a URL, or the URL itself.
fn host(url: &str) -> &str {
    let rest = url.split_once("://").map_or(url, |(_, r)| r);
    let rest = rest.split(['/', '?', '#']).next().unwrap_or(rest);
    let rest = rest.rsplit_once('@').map_or(rest, |(_, h)| h);
    let rest = rest.split(':').next().unwrap_or(rest);
    rest.strip_prefix("www.").unwrap_or(rest)
}

/// Runs a manager's CLI: its stdout, or the first line of its stderr. Output is never logged.
fn run(command: &str, args: &[&str]) -> Result<String, String> {
    let out = Command::new(command)
        .args(args)
        .stdin(Stdio::null())
        .output()
        .map_err(|err| format!("running {command}: {err}"))?;
    if out.status.success() {
        return String::from_utf8(out.stdout)
            .map_err(|_| format!("{command}: output is not UTF-8"));
    }
    let stderr = String::from_utf8_lossy(&out.stderr);
    Err(stderr
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .map_or_else(
            || format!("{command} failed ({})", out.status),
            str::to_owned,
        ))
}

/// A fetched field: the output without its trailing newline; empty is an error.
fn value(out: String, what: &str) -> Result<String, String> {
    let v = out.trim_end_matches(['\n', '\r']);
    if v.is_empty() {
        return Err(format!("empty {what}"));
    }
    Ok(v.to_owned())
}
