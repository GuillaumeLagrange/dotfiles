//! The store shared by the watcher, the sink and the history mode, and the mode itself.

use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Result;
use launcher_core::clipboard::Offer;
use launcher_core::engine::Updater;
use launcher_core::{Action, Clipboard, Ctx, Entry, Icon, Mode, Outcome, Preview, Source};

use crate::store::{Content, Kind, Record, Store, URI_LIST};

pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

pub struct History {
    store: Mutex<Store>,
    entries: Mutex<Arc<Vec<Entry>>>,
    updater: Updater,
}

impl History {
    pub fn new(store: Store, updater: Updater) -> History {
        let entries = Arc::new(entries(&store, now()));
        History {
            store: Mutex::new(store),
            entries: Mutex::new(entries),
            updater,
        }
    }

    fn change<T>(&self, f: impl FnOnce(&mut Store, u64) -> Result<T>) -> Result<T> {
        let mut store = self.store.lock().unwrap();
        let now = now();
        let result = f(&mut store, now);
        *self.entries.lock().unwrap() = Arc::new(entries(&store, now));
        drop(store);
        self.updater.updated(Mode::Clipboard);
        result
    }

    pub fn add(&self, content: Content) {
        if let Err(err) = self.change(|s, now| s.add(content, now)) {
            eprintln!("launcher: recording the clipboard: {err:#}");
        }
    }

    pub fn prune(&self) {
        if let Err(err) = self.change(|s, now| s.prune(now)) {
            eprintln!("launcher: pruning the clipboard history: {err:#}");
        }
    }

    pub fn entries(&self) -> Arc<Vec<Entry>> {
        self.entries.lock().unwrap().clone()
    }

    /// Rebuilds the rows so their ages are current.
    fn refresh(&self) {
        let store = self.store.lock().unwrap();
        *self.entries.lock().unwrap() = Arc::new(entries(&store, now()));
    }

    fn offer(&self, id: &str) -> Result<Option<Offer>> {
        let store = self.store.lock().unwrap();
        let Some(record) = store.get(id) else {
            return Ok(None);
        };
        Ok(Some(match &record.kind {
            Kind::Text { text, uri_list } => {
                let mut offer = Offer::text(text);
                if let Some(uris) = uri_list {
                    offer
                        .mimes
                        .push((URI_LIST.into(), Arc::from(uris.as_bytes())));
                }
                offer
            }
            Kind::Image { mime, .. } => {
                let path = store.image_path(record).expect("an image has a file");
                let bytes = std::fs::read(&path)?;
                Offer {
                    mimes: vec![(mime.clone(), Arc::from(bytes))],
                }
            }
        }))
    }

    fn preview(&self, id: &str) -> Option<Preview> {
        let store = self.store.lock().unwrap();
        let record = store.get(id)?;
        Some(match &record.kind {
            Kind::Text { text, .. } => Preview::Text {
                text: text.clone(),
                mono: true,
            },
            Kind::Image { .. } => Preview::Image {
                path: store.image_path(record)?,
            },
        })
    }
}

/// The `clipboard` mode. It copies through the daemon's own clipboard, which records the copy
/// and so moves the entry to the top.
pub struct HistorySource {
    pub history: Arc<History>,
    pub clipboard: Clipboard,
}

impl Source for HistorySource {
    fn mode(&self) -> Mode {
        Mode::Clipboard
    }

    fn open(&mut self, _ctx: &Ctx) {
        self.history.refresh();
    }

    fn entries(&self) -> Arc<Vec<Entry>> {
        self.history.entries()
    }

    fn activate(&mut self, id: &str, action: &str, _ctx: &Ctx) -> Outcome {
        let result = match action {
            "copy" => match self.history.offer(id) {
                Ok(Some(offer)) => {
                    self.clipboard.copy(offer, false);
                    return Outcome::Close;
                }
                Ok(None) => return Outcome::Error("that entry is gone".into()),
                Err(err) => Err(err),
            },
            "pin" | "unpin" => self
                .history
                .change(|s, now| s.set_pinned(id, action == "pin", now))
                .map(drop),
            "delete" => self.history.change(|s, now| s.delete(id, now)).map(drop),
            "clear" => self.history.change(|s, now| s.clear(now)),
            other => return Outcome::Error(format!("no action {other}")),
        };
        match result {
            Ok(()) => Outcome::Stay,
            Err(err) => Outcome::Error(format!("{err:#}")),
        }
    }

    fn preview(&self, id: &str, _ctx: &Ctx) -> Option<Preview> {
        self.history.preview(id)
    }
}

const TITLE_CHARS: usize = 80;
const SUBTITLE_CHARS: usize = 120;
const KEYWORD_CHARS: usize = 2000;

fn actions(pinned: bool) -> Arc<[Action]> {
    let pin = if pinned {
        Action::new("unpin", "Unpin", Some("Alt+Return"))
    } else {
        Action::new("pin", "Pin", Some("Alt+Return"))
    };
    Arc::from(vec![
        Action::new("copy", "Copy", Some("Return")),
        pin,
        Action::new("delete", "Delete", Some("Shift+Delete")),
        Action::new("clear", "Clear history", None),
    ])
}

/// The rows: pinned first, then newest first.
pub fn entries(store: &Store, now: u64) -> Vec<Entry> {
    let (pinned, unpinned) = (actions(true), actions(false));
    let (mut top, mut rest): (Vec<&Record>, Vec<&Record>) =
        store.records().iter().partition(|r| r.pinned);
    top.append(&mut rest);
    top.into_iter()
        .map(|r| {
            let mut e = entry(r, now, if r.pinned { &pinned } else { &unpinned });
            if let Some(path) = store.image_path(r) {
                e.icon = Icon::Path(path);
            }
            e
        })
        .collect()
}

pub fn entry(record: &Record, now: u64, actions: &Arc<[Action]>) -> Entry {
    let mut e = Entry::new(record.id.clone(), String::new(), actions.clone());
    match &record.kind {
        Kind::Text { text, .. } => {
            let mut lines = text.lines().map(str::trim).filter(|l| !l.is_empty());
            e.title = shorten(lines.next().unwrap_or_default(), TITLE_CHARS);
            let rest: Vec<&str> = lines.collect();
            e.subtitle = shorten(&rest.join(" "), SUBTITLE_CHARS);
            e.keywords = shorten(
                &text.split_whitespace().collect::<Vec<_>>().join(" "),
                KEYWORD_CHARS,
            );
            e.icon = Icon::Glyph("clipboard".into());
        }
        Kind::Image {
            mime,
            width,
            height,
        } => {
            let format = mime.strip_prefix("image/").unwrap_or(mime);
            e.title = format!("Image {width}×{height} {format}");
            e.subtitle = mime.clone();
        }
    }
    e.accessory = age(now.saturating_sub(record.time));
    e.section = if record.pinned { "Pinned" } else { "History" }.into();
    e.preview = true;
    e
}

fn shorten(s: &str, max: usize) -> String {
    match s.char_indices().nth(max) {
        Some((i, _)) => format!("{}…", s[..i].trim_end()),
        None => s.to_owned(),
    }
}

pub fn age(seconds: u64) -> String {
    match seconds {
        0..60 => "now".into(),
        60..3600 => format!("{}m", seconds / 60),
        3600..86_400 => format!("{}h", seconds / 3600),
        _ => format!("{}d", seconds / 86_400),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::tests::{png, text};
    use crate::Settings;

    #[test]
    fn ages() {
        assert_eq!(age(5), "now");
        assert_eq!(age(180), "3m");
        assert_eq!(age(7200), "2h");
        assert_eq!(age(5 * 86_400 + 10), "5d");
    }

    #[test]
    fn text_rows() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(dir.path(), Settings::default(), 0).unwrap();
        let long = "x".repeat(200);
        store
            .add(
                text(&format!("\n  first line  \nsecond\n\nthird {long}")),
                0,
            )
            .unwrap();
        let rows = entries(&store, 120);
        let e = &rows[0];
        assert_eq!(e.title, "first line");
        assert!(e.subtitle.starts_with("second third xxx"));
        assert!(e.subtitle.ends_with('…'));
        assert_eq!(e.subtitle.chars().count(), SUBTITLE_CHARS + 1);
        assert!(e.keywords.contains("third") && e.keywords.contains(&long));
        assert_eq!(e.accessory, "2m");
        assert_eq!(e.icon, Icon::Glyph("clipboard".into()));
        assert_eq!(e.section, "History");
        assert!(e.preview);
        assert_eq!(e.actions[0].id, "copy");
        assert_eq!(e.actions[0].key.as_deref(), Some("Return"));
        assert_eq!(e.actions[1].id, "pin");
    }

    #[test]
    fn pinned_rows_come_first_and_images_show_their_file() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(dir.path(), Settings::default(), 0).unwrap();
        let a = store.add(text("a"), 0).unwrap().unwrap();
        let image = Content::Image {
            mime: "image/png".into(),
            bytes: png(),
        };
        let img = store.add(image, 1).unwrap().unwrap();
        store.set_pinned(&a, true, 1).unwrap();
        let rows = entries(&store, 1);
        assert_eq!(
            rows.iter().map(|e| e.id.as_str()).collect::<Vec<_>>(),
            [a.as_str(), img.as_str()]
        );
        assert_eq!(rows[0].section, "Pinned");
        assert_eq!(rows[0].actions[1].id, "unpin");
        assert_eq!(rows[1].title, "Image 2×1 png");
        assert_eq!(rows[1].subtitle, "image/png");
        let path = store.image_path(store.get(&img).unwrap()).unwrap();
        assert_eq!(rows[1].icon, Icon::Path(path));
    }

    #[test]
    fn actions_change_the_history() {
        let dir = tempfile::tempdir().unwrap();
        let config = launcher_core::Config::with_modes(&[Mode::Clipboard]);
        let (ctx, handles) = Ctx::testing(dir.path(), config);
        let store = Store::open(&dir.path().join("clip"), Settings::default(), now()).unwrap();
        let (_tx, updater, _rx) = launcher_core::engine::channel();
        let history = Arc::new(History::new(store, updater));
        history.add(text("one"));
        history.add(text("two"));
        let mut source = HistorySource {
            history: history.clone(),
            clipboard: ctx.clipboard.clone(),
        };
        let ids: Vec<String> = source.entries().iter().map(|e| e.id.clone()).collect();
        assert_eq!(source.activate(&ids[1], "copy", &ctx), Outcome::Close);
        assert_eq!(handles.copies()[0].text(), Some("one"));
        assert_eq!(source.activate(&ids[1], "pin", &ctx), Outcome::Stay);
        assert_eq!(source.entries()[0].title, "one");
        assert_eq!(source.activate(&ids[0], "delete", &ctx), Outcome::Stay);
        assert_eq!(source.entries().len(), 1);
        history.add(text("three"));
        assert_eq!(source.activate(&ids[1], "clear", &ctx), Outcome::Stay);
        let titles: Vec<String> = source.entries().iter().map(|e| e.title.clone()).collect();
        assert_eq!(titles, ["one"]);
        match source.preview(&ids[1], &ctx) {
            Some(Preview::Text { text, mono: true }) => assert_eq!(text, "one"),
            other => panic!("{other:?}"),
        }
    }
}
