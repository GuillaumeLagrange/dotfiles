//! What a source is to the engine: the entries it lists, what picking one does, and the
//! handle (`Ctx`) through which it reaches the rest of the daemon.

use std::path::PathBuf;
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::clipboard::Clipboard;
use crate::config::Config;
use crate::engine::Updater;
use crate::frecency::Frecency;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    Apps,
    Windows,
    Emoji,
    Clipboard,
    Browser,
    Passwords,
    Sessions,
    Reviews,
    Files,
}

impl Mode {
    pub const ALL: [Mode; 9] = [
        Mode::Apps,
        Mode::Windows,
        Mode::Emoji,
        Mode::Clipboard,
        Mode::Browser,
        Mode::Passwords,
        Mode::Sessions,
        Mode::Reviews,
        Mode::Files,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Mode::Apps => "apps",
            Mode::Windows => "windows",
            Mode::Emoji => "emoji",
            Mode::Clipboard => "clipboard",
            Mode::Browser => "browser",
            Mode::Passwords => "passwords",
            Mode::Sessions => "sessions",
            Mode::Reviews => "reviews",
            Mode::Files => "files",
        }
    }

    pub fn short(self) -> &'static str {
        match self {
            Mode::Apps => "a",
            Mode::Windows => "w",
            Mode::Emoji => "e",
            Mode::Clipboard => "c",
            Mode::Browser => "b",
            Mode::Passwords => "p",
            Mode::Sessions => "s",
            Mode::Reviews => "r",
            Mode::Files => "f",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Mode::Apps => "Apps",
            Mode::Windows => "Windows",
            Mode::Emoji => "Emoji",
            Mode::Clipboard => "Clipboard",
            Mode::Browser => "Browser",
            Mode::Passwords => "Passwords",
            Mode::Sessions => "Sessions",
            Mode::Reviews => "Reviews",
            Mode::Files => "Files",
        }
    }

    /// A key of the bar's `Config.glyph`.
    pub fn glyph(self) -> &'static str {
        match self {
            Mode::Apps => "apps",
            Mode::Windows => "windows",
            Mode::Emoji => "emoji",
            Mode::Clipboard => "clipboard",
            Mode::Browser => "browser",
            Mode::Passwords => "passwords",
            Mode::Sessions => "sessions",
            Mode::Reviews => "reviews",
            Mode::Files => "files",
        }
    }

    /// The mode a `/name` or `/short` token names.
    pub fn from_token(token: &str) -> Option<Mode> {
        Mode::ALL
            .into_iter()
            .find(|m| m.name() == token || m.short() == token)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "kind", content = "value", rename_all = "lowercase")]
pub enum Icon {
    /// An icon theme name, resolved by the panel.
    Name(String),
    /// An absolute file.
    Path(PathBuf),
    /// http(s) or data:.
    Url(String),
    /// The emoji itself, drawn as text.
    Emoji(String),
    /// A key of the bar's `Config.glyph`.
    Glyph(String),
    None,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Action {
    pub id: String,
    pub label: String,
    /// The panel binding that runs it: `Return`, `Alt+Return`, `Ctrl+Return`, `Shift+Delete`,
    /// `Ctrl+R`; none puts it in the actions menu (Ctrl+K) only.
    pub key: Option<String>,
}

impl Action {
    pub fn new(id: &str, label: &str, key: Option<&str>) -> Action {
        Action {
            id: id.to_owned(),
            label: label.to_owned(),
            key: key.map(str::to_owned),
        }
    }
}

#[derive(Debug, Clone)]
pub struct Entry {
    /// Stable within its mode: activations and previews name it.
    pub id: String,
    pub title: String,
    pub subtitle: String,
    /// Matched, never shown.
    pub keywords: String,
    pub icon: Icon,
    pub accessory: String,
    /// A dot before the title, "#rrggbb".
    pub color: Option<String>,
    /// The heading the row sits under while the query is empty.
    pub section: String,
    /// Multiplies the match score: open tabs rank over bookmarks.
    pub boost: f64,
    /// The first is Enter's. Shared, since a mode's rows mostly carry the same ones.
    pub actions: Arc<[Action]>,
    pub preview: bool,
}

impl Entry {
    pub fn new(id: impl Into<String>, title: impl Into<String>, actions: Arc<[Action]>) -> Entry {
        Entry {
            id: id.into(),
            title: title.into(),
            subtitle: String::new(),
            keywords: String::new(),
            icon: Icon::None,
            accessory: String::new(),
            color: None,
            section: String::new(),
            boost: 1.0,
            actions,
            preview: false,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Preview {
    Text { text: String, mono: bool },
    Image { path: PathBuf },
    Fields { fields: Vec<(String, String)> },
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Status {
    pub kind: StatusKind,
    pub text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum StatusKind {
    Loading,
    Info,
    Error,
}

impl Status {
    pub fn loading(text: impl Into<String>) -> Status {
        Status {
            kind: StatusKind::Loading,
            text: text.into(),
        }
    }
    pub fn info(text: impl Into<String>) -> Status {
        Status {
            kind: StatusKind::Info,
            text: text.into(),
        }
    }
    pub fn error(text: impl Into<String>) -> Status {
        Status {
            kind: StatusKind::Error,
            text: text.into(),
        }
    }
}

/// What the panel does once an activation returns.
#[derive(Debug, PartialEq)]
pub enum Outcome {
    Close,
    /// Stay open; the entries may have changed (a row deleted), so the results are sent again.
    Stay,
    Switch(Mode),
    Error(String),
    /// Slow work the panel waits for, saying `status` meanwhile: it closes once the work
    /// succeeds, and shows its error otherwise. The engine runs it on a thread of its own.
    Wait {
        status: String,
        work: Work,
    },
}

/// The work of an `Outcome::Wait`; its error is a message for the user.
pub struct Work(Box<dyn FnOnce() -> Result<(), String> + Send>);

impl Work {
    pub fn new(work: impl FnOnce() -> Result<(), String> + Send + 'static) -> Work {
        Work(Box::new(work))
    }

    pub fn run(self) -> Result<(), String> {
        (self.0)()
    }
}

impl std::fmt::Debug for Work {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Work")
    }
}

/// Never equal: what work does is seen by running it.
impl PartialEq for Work {
    fn eq(&self, _: &Work) -> bool {
        false
    }
}

/// One mode's entries and what picking them does.
///
/// Called on the engine's thread: every method returns quickly. Slow work runs on a thread
/// the source spawns, which replaces the source's shared entries and calls `ctx.updated`.
pub trait Source: Send {
    fn mode(&self) -> Mode;

    /// The panel opened on this mode: refresh what may have changed since.
    fn open(&mut self, _ctx: &Ctx) {}

    /// The last panel on this mode left it.
    fn close(&mut self, _ctx: &Ctx) {}

    /// The entries, in the order an empty query shows them.
    fn entries(&self) -> Arc<Vec<Entry>>;

    /// Rows that depend on the query itself (e.g. "New session «query»"), listed after the
    /// matches.
    fn extra(&self, _query: &str) -> Vec<Entry> {
        Vec::new()
    }

    fn status(&self) -> Option<Status> {
        None
    }

    /// Whether picking an entry counts towards its frecency, which then orders the empty query
    /// and adds to match scores.
    fn frecency(&self) -> bool {
        false
    }

    fn activate(&mut self, id: &str, action: &str, ctx: &Ctx) -> Outcome;

    fn preview(&self, _id: &str, _ctx: &Ctx) -> Option<Preview> {
        None
    }

    /// Whether matching treats titles as paths (fzf's path scoring: separators are boundaries).
    fn paths(&self) -> bool {
        false
    }
}

/// The daemon's directories, created at startup.
#[derive(Debug, Clone)]
pub struct Dirs {
    pub state: PathBuf,
    pub data: PathBuf,
    pub cache: PathBuf,
    pub runtime: PathBuf,
}

impl Dirs {
    /// `$XDG_*_HOME/launcher`, and `$XDG_RUNTIME_DIR` itself.
    pub fn from_env() -> anyhow::Result<Dirs> {
        let home = PathBuf::from(
            std::env::var_os("HOME").ok_or_else(|| anyhow::anyhow!("HOME is not set"))?,
        );
        let xdg = |var: &str, fallback: &str| {
            std::env::var_os(var)
                .map(PathBuf::from)
                .filter(|p| p.is_absolute())
                .unwrap_or_else(|| home.join(fallback))
        };
        let runtime = std::env::var_os("XDG_RUNTIME_DIR")
            .map(PathBuf::from)
            .ok_or_else(|| anyhow::anyhow!("XDG_RUNTIME_DIR is not set"))?;
        let dirs = Dirs {
            state: xdg("XDG_STATE_HOME", ".local/state").join("launcher"),
            data: xdg("XDG_DATA_HOME", ".local/share").join("launcher"),
            cache: xdg("XDG_CACHE_HOME", ".cache").join("launcher"),
            runtime,
        };
        dirs.create()?;
        Ok(dirs)
    }

    /// All four under one directory, for tests.
    pub fn under(root: &std::path::Path) -> anyhow::Result<Dirs> {
        let dirs = Dirs {
            state: root.join("state"),
            data: root.join("data"),
            cache: root.join("cache"),
            runtime: root.join("run"),
        };
        dirs.create()?;
        Ok(dirs)
    }

    fn create(&self) -> anyhow::Result<()> {
        for dir in [&self.state, &self.data, &self.cache, &self.runtime] {
            std::fs::create_dir_all(dir)?;
        }
        Ok(())
    }
}

/// A source's way into the daemon. Cheap to clone and Send: threads a source spawns take one.
#[derive(Clone)]
pub struct Ctx {
    pub config: Arc<Config>,
    pub dirs: Arc<Dirs>,
    pub clipboard: Clipboard,
    pub frecency: Frecency,
    updater: Updater,
}

impl Ctx {
    pub fn new(
        config: Arc<Config>,
        dirs: Arc<Dirs>,
        clipboard: Clipboard,
        frecency: Frecency,
        updater: Updater,
    ) -> Ctx {
        Ctx {
            config,
            dirs,
            clipboard,
            frecency,
            updater,
        }
    }

    /// A mode's entries or status changed: the panels on it get fresh results.
    pub fn updated(&self, mode: Mode) {
        self.updater.updated(mode);
    }

    pub(crate) fn updater(&self) -> Updater {
        self.updater.clone()
    }

    /// A desktop notification, for failures of work that outlived the panel.
    pub fn notify(&self, summary: &str, body: &str) {
        crate::notify::send(summary, body);
    }

    /// This mode's section of the config, or its default when absent or empty.
    pub fn section<T: serde::de::DeserializeOwned + Default>(
        &self,
        mode: Mode,
    ) -> anyhow::Result<T> {
        self.config.section(mode)
    }

    /// Runs `argv` as niri's child, with the session's environment. A failure to hand it over
    /// is the outcome's error.
    pub fn spawn(&self, argv: &[String]) -> Outcome {
        match crate::niri::spawn(argv) {
            Ok(()) => Outcome::Close,
            Err(err) => Outcome::Error(format!("{err:#}")),
        }
    }

    /// Runs `argv` in a new terminal window (the config's `terminal` prefix).
    pub fn spawn_in_terminal(&self, argv: &[String]) -> Outcome {
        let mut full = self.config.terminal.clone();
        full.extend(argv.iter().cloned());
        self.spawn(&full)
    }

    /// Opens a URL or a path with its default application.
    pub fn open(&self, target: &str) -> Outcome {
        self.spawn(&["xdg-open".to_owned(), target.to_owned()])
    }

    /// A context for tests: directories under `root`, a clipboard that records what it is
    /// asked to copy, and the modes reported updated.
    pub fn testing(root: &std::path::Path, config: Config) -> (Ctx, crate::testing::Handles) {
        crate::testing::ctx(root, config)
    }
}
