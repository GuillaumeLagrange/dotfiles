//! Firefox's open tabs (TabCtl over D-Bus) and its bookmarks.

mod bookmarks;
mod tabs;
#[cfg(test)]
mod tests;

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;

use launcher_core::{Action, Ctx, Entry, Icon, Mode, Outcome, Source, Status};
use serde::Deserialize;

use bookmarks::{Bookmark, Loader};
pub use tabs::Bus;
use tabs::{Tab, Watcher};

const NOT_CONNECTED: &str =
    "No open tabs: TabCtl is not connected (Firefox not running, or not restarted since its extension policy)";

/// The `browser` config section.
#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct Settings {
    /// Firefox's `profiles.ini` files; `~` is the home directory, missing ones are skipped.
    pub profiles_ini: Vec<String>,
    /// What opens a bookmark: `<firefox> --new-tab <url>`.
    pub firefox: String,
}

impl Default for Settings {
    fn default() -> Settings {
        Settings {
            profiles_ini: vec![
                "~/.config/mozilla/firefox/profiles.ini".into(),
                "~/.mozilla/firefox/profiles.ini".into(),
            ],
            firefox: "firefox".into(),
        }
    }
}

/// The enabled ones of: Browser.
pub fn sources(ctx: &Ctx) -> anyhow::Result<Vec<Box<dyn Source>>> {
    if !ctx.config.enabled(Mode::Browser) {
        return Ok(Vec::new());
    }
    Ok(vec![Box::new(Browser::new(ctx, Bus::Session)?)])
}

#[derive(Default)]
struct State {
    tabs: Vec<Tab>,
    /// None until the bus was first asked.
    connected: Option<bool>,
    bookmarks: Vec<Bookmark>,
    entries: Arc<Vec<Entry>>,
}

pub struct Browser {
    state: Arc<Mutex<State>>,
    watcher: Arc<Watcher>,
    loader: Arc<Mutex<Loader>>,
    loading: Arc<AtomicBool>,
    profiles: Vec<PathBuf>,
    firefox: String,
}

impl Browser {
    pub fn new(ctx: &Ctx, bus: Bus) -> anyhow::Result<Browser> {
        let settings: Settings = ctx.section(Mode::Browser)?;
        let home = std::env::var("HOME").unwrap_or_default();
        let profiles = settings
            .profiles_ini
            .iter()
            .map(|p| match p.strip_prefix("~/") {
                Some(rest) => PathBuf::from(&home).join(rest),
                None => PathBuf::from(p),
            })
            .collect();
        let state = Arc::new(Mutex::new(State::default()));
        let watcher = {
            let state = state.clone();
            let ctx = ctx.clone();
            tabs::watch(bus, move |tabs, connected| {
                let mut s = state.lock().unwrap();
                s.tabs = tabs;
                s.connected = Some(connected);
                rebuild(&mut s);
                drop(s);
                ctx.updated(Mode::Browser);
            })
        };
        let browser = Browser {
            state,
            watcher,
            loader: Arc::default(),
            loading: Arc::default(),
            profiles,
            firefox: settings.firefox,
        };
        browser.load_bookmarks(ctx);
        Ok(browser)
    }

    /// Rereads the bookmarks on a thread, if their databases changed.
    fn load_bookmarks(&self, ctx: &Ctx) {
        if self.loading.swap(true, Ordering::SeqCst) {
            return;
        }
        let (state, loader, loading, inis, ctx) = (
            self.state.clone(),
            self.loader.clone(),
            self.loading.clone(),
            self.profiles.clone(),
            ctx.clone(),
        );
        thread::spawn(move || {
            let dirs = bookmarks::profile_dirs(&inis);
            let loaded = loader.lock().unwrap().load(&dirs, &ctx.dirs.cache);
            if let Some(bookmarks) = loaded {
                let mut s = state.lock().unwrap();
                s.bookmarks = bookmarks;
                rebuild(&mut s);
                drop(s);
                ctx.updated(Mode::Browser);
            }
            loading.store(false, Ordering::SeqCst);
        });
    }

    fn tab(&self, id: &str) -> Option<Tab> {
        let s = self.state.lock().unwrap();
        s.tabs.iter().find(|t| tab_id(t) == id).cloned()
    }

    fn bookmark(&self, id: &str) -> Option<Bookmark> {
        let s = self.state.lock().unwrap();
        s.bookmarks.iter().find(|b| bookmark_id(b) == id).cloned()
    }
}

fn tab_id(t: &Tab) -> String {
    format!("tab:{}:{}", t.instance, t.id)
}

fn bookmark_id(b: &Bookmark) -> String {
    format!("bm:{}:{}", b.profile, b.id)
}

/// `https://example.org/a` → `example.org/a`.
fn without_scheme(url: &str) -> &str {
    url.split_once("://").map_or(url, |(_, rest)| rest)
}

fn rebuild(s: &mut State) {
    let tab_actions: Arc<[Action]> = Arc::new([
        Action::new("switch", "Switch to tab", Some("Return")),
        Action::new("close", "Close tab", Some("Shift+Delete")),
        Action::new("copy-url", "Copy URL", Some("Ctrl+Return")),
    ]);
    let bookmark_actions: Arc<[Action]> = Arc::new([
        Action::new("open", "Open", Some("Return")),
        Action::new("copy-url", "Copy URL", Some("Ctrl+Return")),
    ]);
    let several = s.tabs.iter().any(|t| t.instance != s.tabs[0].instance);
    let mut entries = Vec::with_capacity(s.tabs.len() + s.bookmarks.len());
    for t in &s.tabs {
        let title = if t.title.is_empty() { &t.url } else { &t.title };
        let mut e = Entry::new(tab_id(t), title.as_str(), tab_actions.clone());
        e.subtitle = without_scheme(&t.url).to_owned();
        e.icon = if ["http://", "https://", "data:"]
            .iter()
            .any(|p| t.icon.starts_with(p))
        {
            Icon::Url(t.icon.clone())
        } else {
            Icon::Name("firefox".into())
        };
        let mut accessory = Vec::new();
        if t.pinned {
            accessory.push("pinned");
        }
        if several {
            accessory.push(t.instance.as_str());
        }
        e.accessory = accessory.join(" · ");
        e.section = "Open tabs".into();
        e.boost = 1.5;
        entries.push(e);
    }
    for b in &s.bookmarks {
        let title = if b.title.is_empty() { &b.url } else { &b.title };
        let mut e = Entry::new(bookmark_id(b), title.as_str(), bookmark_actions.clone());
        e.subtitle = without_scheme(&b.url).to_owned();
        if !b.folder.is_empty() {
            e.subtitle.push_str(" · ");
            e.subtitle.push_str(&b.folder);
        }
        e.keywords = b.folder.clone();
        e.icon = match &b.icon {
            Some(path) => Icon::Path(path.clone()),
            None => Icon::Name("firefox".into()),
        };
        e.section = "Bookmarks".into();
        e.boost = 1.0;
        entries.push(e);
    }
    s.entries = Arc::new(entries);
}

impl Source for Browser {
    fn mode(&self) -> Mode {
        Mode::Browser
    }

    fn open(&mut self, ctx: &Ctx) {
        self.watcher.refresh();
        self.load_bookmarks(ctx);
    }

    fn entries(&self) -> Arc<Vec<Entry>> {
        self.state.lock().unwrap().entries.clone()
    }

    fn status(&self) -> Option<Status> {
        (self.state.lock().unwrap().connected == Some(false)).then(|| Status::info(NOT_CONNECTED))
    }

    fn activate(&mut self, id: &str, action: &str, ctx: &Ctx) -> Outcome {
        if let Some(tab) = self.tab(id) {
            return match action {
                "copy-url" => {
                    ctx.clipboard.copy_text(&tab.url);
                    Outcome::Close
                }
                "switch" | "close" => {
                    let Some(conn) = self.watcher.conn() else {
                        return Outcome::Error(NOT_CONNECTED.into());
                    };
                    let (switch, ctx) = (action == "switch", ctx.clone());
                    thread::spawn(move || {
                        let result = if switch {
                            tabs::switch(&conn, &tab)
                        } else {
                            tabs::close(&conn, &tab)
                        };
                        if let Err(err) = result {
                            ctx.notify("Browser", &format!("{err:#}"));
                        }
                    });
                    if switch {
                        Outcome::Close
                    } else {
                        Outcome::Stay
                    }
                }
                _ => Outcome::Error(format!("unknown action {action}")),
            };
        }
        if let Some(b) = self.bookmark(id) {
            return match action {
                "open" => ctx.spawn(&[self.firefox.clone(), "--new-tab".into(), b.url]),
                "copy-url" => {
                    ctx.clipboard.copy_text(&b.url);
                    Outcome::Close
                }
                _ => Outcome::Error(format!("unknown action {action}")),
            };
        }
        Outcome::Error(format!("no tab or bookmark {id}"))
    }
}
