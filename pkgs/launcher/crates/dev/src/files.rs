//! Files under the configured roots: .gitignore and .ignore respected, hidden ones and the
//! excluded paths skipped, symlinks not followed.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use ignore::{WalkBuilder, WalkState};
use launcher_core::{Action, Ctx, Entry, Icon, Mode, Outcome, Source, Status};
use serde::Deserialize;

/// An index younger than this is reused as is.
const FRESH: Duration = Duration::from_secs(5 * 60);
/// An index unused this long after the panel closed is dropped.
const IDLE: Duration = Duration::from_secs(10 * 60);
const BATCH: Duration = Duration::from_millis(150);

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct Config {
    pub roots: Vec<PathBuf>,
    /// Relative to each root.
    pub exclude: Vec<PathBuf>,
    pub max: usize,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            roots: std::env::var_os("HOME")
                .map(PathBuf::from)
                .into_iter()
                .collect(),
            exclude: vec![".cache".into(), ".local/share/Steam".into()],
            max: 300_000,
        }
    }
}

#[derive(Default)]
struct State {
    entries: Arc<Vec<Entry>>,
    indexed_at: Option<Instant>,
    walking: bool,
    /// Bumped by every open and close: a pending drop checks it is still the last.
    generation: u64,
}

pub struct Files {
    config: Arc<Config>,
    state: Arc<Mutex<State>>,
    actions: Arc<[Action]>,
    idle: Duration,
}

impl Files {
    pub fn new(config: Config) -> Files {
        Files {
            config: Arc::new(config),
            state: Arc::default(),
            actions: Arc::from(vec![
                Action::new("open", "Open", Some("Return")),
                Action::new("folder", "Open folder", Some("Alt+Return")),
                Action::new("copy-path", "Copy path", Some("Ctrl+Return")),
            ]),
            idle: IDLE,
        }
    }
}

impl Source for Files {
    fn mode(&self) -> Mode {
        Mode::Files
    }

    fn open(&mut self, ctx: &Ctx) {
        let mut state = self.state.lock().unwrap();
        state.generation += 1;
        if state.walking || state.indexed_at.is_some_and(|t| t.elapsed() < FRESH) {
            return;
        }
        state.walking = true;
        let (config, shared, actions, ctx) = (
            self.config.clone(),
            self.state.clone(),
            self.actions.clone(),
            ctx.clone(),
        );
        let partial = state.entries.is_empty();
        std::thread::spawn(move || walk(&config, &shared, &actions, &ctx, partial));
    }

    fn close(&mut self, _ctx: &Ctx) {
        let generation = {
            let mut state = self.state.lock().unwrap();
            state.generation += 1;
            state.generation
        };
        let (state, idle) = (self.state.clone(), self.idle);
        std::thread::spawn(move || {
            std::thread::sleep(idle);
            let mut state = state.lock().unwrap();
            if state.generation == generation && !state.walking {
                state.entries = Arc::default();
                state.indexed_at = None;
            }
        });
    }

    fn entries(&self) -> Arc<Vec<Entry>> {
        self.state.lock().unwrap().entries.clone()
    }

    fn status(&self) -> Option<Status> {
        self.state
            .lock()
            .unwrap()
            .walking
            .then(|| Status::loading("Indexing files…"))
    }

    fn frecency(&self) -> bool {
        true
    }

    fn paths(&self) -> bool {
        true
    }

    fn activate(&mut self, id: &str, action: &str, ctx: &Ctx) -> Outcome {
        let path = Path::new(id);
        match action {
            "open" => ctx.open(id),
            "folder" => match path.parent() {
                Some(parent) => ctx.open(&parent.to_string_lossy()),
                None => Outcome::Error(format!("{id} has no parent")),
            },
            "copy-path" => {
                ctx.clipboard.copy_text(id);
                Outcome::Close
            }
            other => Outcome::Error(format!("unknown action {other}")),
        }
    }
}

fn walk(config: &Config, state: &Mutex<State>, actions: &Arc<[Action]>, ctx: &Ctx, partial: bool) {
    let mut collected = Vec::new();
    let roots: Vec<PathBuf> = config
        .roots
        .iter()
        .filter(|r| r.is_dir())
        .cloned()
        .collect();
    if let Some((first, rest)) = roots.split_first() {
        let mut builder = WalkBuilder::new(first);
        for root in rest {
            builder.add(root);
        }
        let excluded: Vec<PathBuf> = roots
            .iter()
            .flat_map(|root| config.exclude.iter().map(move |e| root.join(e)))
            .collect();
        builder
            .hidden(true)
            .follow_links(false)
            .require_git(false)
            .filter_entry(move |e| !excluded.iter().any(|x| e.path() == x));
        let (tx, rx) = mpsc::channel::<Entry>();
        let count = Arc::new(AtomicUsize::new(0));
        let (max, roots2, actions2) = (config.max, roots.clone(), actions.clone());
        let walker = builder.build_parallel();
        let handle = std::thread::spawn(move || {
            walker.run(|| {
                let (tx, count, roots, actions) =
                    (tx.clone(), count.clone(), roots2.clone(), actions2.clone());
                Box::new(move |result| {
                    let Ok(dirent) = result else {
                        return WalkState::Continue;
                    };
                    if !dirent.file_type().is_some_and(|t| t.is_file()) {
                        return WalkState::Continue;
                    }
                    if count.fetch_add(1, Ordering::Relaxed) >= max {
                        return WalkState::Quit;
                    }
                    match entry(dirent.path(), &roots, &actions).map(|e| tx.send(e).is_ok()) {
                        Some(false) => WalkState::Quit,
                        _ => WalkState::Continue,
                    }
                })
            });
        });
        let mut published = Instant::now();
        let mut shown = 0;
        loop {
            match rx.recv_timeout(BATCH.saturating_sub(published.elapsed())) {
                Ok(e) => collected.push(e),
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }
            if partial && published.elapsed() >= BATCH {
                if collected.len() > shown {
                    state.lock().unwrap().entries = Arc::new(collected.clone());
                    shown = collected.len();
                    ctx.updated(Mode::Files);
                }
                published = Instant::now();
            }
        }
        let _ = handle.join();
    }
    collected.sort_by(|a, b| a.title.cmp(&b.title));
    collected.truncate(config.max);
    let mut state = state.lock().unwrap();
    state.entries = Arc::new(collected);
    state.indexed_at = Some(Instant::now());
    state.walking = false;
    drop(state);
    ctx.updated(Mode::Files);
}

fn entry(path: &Path, roots: &[PathBuf], actions: &Arc<[Action]>) -> Option<Entry> {
    let root = roots
        .iter()
        .filter(|r| path.starts_with(r))
        .max_by_key(|r| r.as_os_str().len())?;
    let rel = path.strip_prefix(root).ok()?;
    let mut entry = Entry::new(
        path.to_string_lossy(),
        rel.to_string_lossy(),
        actions.clone(),
    );
    entry.icon = Icon::Name(icon(path).into());
    Some(entry)
}

fn icon(path: &Path) -> &'static str {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    match ext.as_str() {
        "png" | "jpg" | "jpeg" | "gif" | "webp" | "svg" | "bmp" | "avif" | "heic" => {
            "image-x-generic"
        }
        "mp4" | "mkv" | "webm" | "mov" | "avi" => "video-x-generic",
        "mp3" | "flac" | "ogg" | "opus" | "wav" | "m4a" => "audio-x-generic",
        "pdf" => "application-pdf",
        "zip" | "tar" | "gz" | "xz" | "zst" | "bz2" | "7z" | "rar" => "package-x-generic",
        "rs" | "py" | "js" | "ts" | "go" | "c" | "h" | "cpp" | "nix" | "sh" | "qml" | "java"
        | "rb" | "lua" => "text-x-script",
        "html" | "htm" => "text-html",
        _ => "text-x-generic",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::Fixture;

    fn tree(fx: &Fixture) -> PathBuf {
        let root = fx.root().join("home");
        for (rel, text) in [
            (".gitignore", "*.log\nbuild/\n"),
            ("notes.md", ""),
            ("pics/cat.png", ""),
            ("debug.log", ""),
            ("build/out.bin", ""),
            (".hidden/secret.txt", ""),
            (".profile", ""),
            ("src/.ignore", "gen.rs\n"),
            ("src/main.rs", ""),
            ("src/gen.rs", ""),
            (".cache/blob", ""),
            ("games/Steam/big.dat", ""),
            ("games/keep.txt", ""),
        ] {
            fx.write(&format!("home/{rel}"), text);
        }
        std::os::unix::fs::symlink(&root, root.join("loop")).unwrap();
        std::os::unix::fs::symlink(root.join("notes.md"), root.join("link.md")).unwrap();
        root
    }

    fn config(root: &Path) -> Config {
        Config {
            roots: vec![root.to_owned()],
            exclude: vec![".cache".into(), "games/Steam".into()],
            max: 1000,
        }
    }

    fn walked(fx: &Fixture, files: &mut Files) {
        files.open(&fx.ctx);
        while files.status().is_some() {
            assert!(fx
                .handles
                .wait_updated(Mode::Files, Duration::from_secs(10)));
        }
    }

    #[test]
    fn indexes_files_respecting_ignores_hidden_excludes_and_symlinks() {
        let fx = Fixture::new(&[Mode::Files]);
        let root = tree(&fx);
        let mut files = Files::new(config(&root));
        assert!(files.paths());
        walked(&fx, &mut files);
        let entries = files.entries();
        let titles: Vec<&str> = entries.iter().map(|e| e.title.as_str()).collect();
        assert_eq!(
            titles,
            ["games/keep.txt", "notes.md", "pics/cat.png", "src/main.rs"]
        );
        assert_eq!(entries[1].id, root.join("notes.md").to_string_lossy());
        assert_eq!(entries[2].icon, Icon::Name("image-x-generic".into()));
        assert_eq!(entries[1].icon, Icon::Name("text-x-generic".into()));
    }

    #[test]
    fn stops_at_max() {
        let fx = Fixture::new(&[Mode::Files]);
        let root = tree(&fx);
        let mut files = Files::new(Config {
            max: 2,
            ..config(&root)
        });
        walked(&fx, &mut files);
        assert_eq!(files.entries().len(), 2);
    }

    #[test]
    fn a_fresh_index_is_reused_and_an_idle_one_dropped() {
        let fx = Fixture::new(&[Mode::Files]);
        let root = tree(&fx);
        let mut files = Files::new(config(&root));
        files.idle = Duration::from_millis(50);
        walked(&fx, &mut files);
        fx.write("home/new.txt", "");
        files.close(&fx.ctx);
        files.open(&fx.ctx);
        assert_eq!(files.status(), None);
        std::thread::sleep(Duration::from_millis(200));
        assert_eq!(files.entries().len(), 4, "reopened before the idle drop");
        files.close(&fx.ctx);
        while !files.entries().is_empty() {
            std::thread::sleep(Duration::from_millis(20));
        }
        walked(&fx, &mut files);
        assert_eq!(files.entries().len(), 5);
    }

    #[test]
    fn actions() {
        let fx = Fixture::new(&[Mode::Files]);
        let root = tree(&fx);
        let mut files = Files::new(config(&root));
        walked(&fx, &mut files);
        let id = root.join("pics/cat.png").to_string_lossy().into_owned();
        assert_eq!(files.activate(&id, "open", &fx.ctx), Outcome::Close);
        assert_eq!(files.activate(&id, "folder", &fx.ctx), Outcome::Close);
        assert_eq!(files.activate(&id, "copy-path", &fx.ctx), Outcome::Close);
        assert_eq!(
            fx.spawned(),
            [
                format!("xdg-open {id}"),
                format!("xdg-open {}", root.join("pics").display())
            ]
        );
        let copies = fx.handles.copies();
        assert_eq!(copies.len(), 1);
        assert_eq!(copies[0].text(), Some(id.as_str()));
        assert!(!copies[0].secret);
    }
}
