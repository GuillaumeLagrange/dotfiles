//! The history on disk: `history.json` plus one file per image, named by content hash.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result};
use launcher_core::clipboard::{Offer, TEXT_MIMES};
use serde::{Deserialize, Serialize};

use crate::Settings;

pub const URI_LIST: &str = "text/uri-list";
pub const IMAGE_MIMES: [&str; 4] = ["image/png", "image/jpeg", "image/webp", "image/gif"];
const HISTORY: &str = "history.json";
const DAY: u64 = 86_400;

/// What a copy is recorded as.
#[derive(Debug, Clone, PartialEq)]
pub enum Content {
    Text {
        text: String,
        uri_list: Option<String>,
    },
    Image {
        mime: String,
        bytes: Vec<u8>,
    },
}

impl Content {
    /// The content worth keeping from an offer's types, text first.
    pub fn from_offer(offer: &Offer) -> Option<Content> {
        let find = |mime: &str| offer.mimes.iter().find(|(m, _)| m == mime).map(|(_, b)| b);
        let utf8 = |b: &Arc<[u8]>| String::from_utf8(b.to_vec()).ok();
        let text = TEXT_MIMES.iter().find_map(|m| find(m)).and_then(utf8);
        let uri_list = find(URI_LIST).and_then(utf8);
        if let Some(text) = text.clone().or_else(|| uri_list.clone()) {
            return Some(Content::Text { text, uri_list });
        }
        IMAGE_MIMES.iter().find_map(|m| {
            find(m).map(|b| Content::Image {
                mime: (*m).to_owned(),
                bytes: b.to_vec(),
            })
        })
    }

    fn id(&self) -> String {
        let hash = match self {
            Content::Text { text, .. } => blake3::hash(text.as_bytes()),
            Content::Image { bytes, .. } => blake3::hash(bytes),
        };
        hash.to_hex()[..32].to_owned()
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Kind {
    Text {
        text: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        uri_list: Option<String>,
    },
    Image {
        mime: String,
        width: u32,
        height: u32,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Record {
    pub id: String,
    /// Unix seconds of the last copy.
    pub time: u64,
    #[serde(default)]
    pub pinned: bool,
    #[serde(flatten)]
    pub kind: Kind,
}

#[derive(Default, Serialize, Deserialize)]
struct File {
    entries: Vec<Record>,
}

pub struct Store {
    dir: PathBuf,
    settings: Settings,
    /// Newest first.
    records: Vec<Record>,
}

impl Store {
    pub fn open(dir: &Path, settings: Settings, now: u64) -> Result<Store> {
        std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
        let path = dir.join(HISTORY);
        let records = match std::fs::read(&path) {
            Ok(bytes) => match serde_json::from_slice::<File>(&bytes) {
                Ok(file) => file.entries,
                Err(err) => {
                    eprintln!("launcher: ignoring {}: {err}", path.display());
                    Vec::new()
                }
            },
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(err) => return Err(err).with_context(|| format!("reading {}", path.display())),
        };
        let mut store = Store {
            dir: dir.to_owned(),
            settings,
            records,
        };
        store.records.sort_by_key(|r| std::cmp::Reverse(r.time));
        store.prune(now)?;
        Ok(store)
    }

    pub fn records(&self) -> &[Record] {
        &self.records
    }

    pub fn get(&self, id: &str) -> Option<&Record> {
        self.records.iter().find(|r| r.id == id)
    }

    pub fn image_path(&self, record: &Record) -> Option<PathBuf> {
        match &record.kind {
            Kind::Image { mime, .. } => Some(self.dir.join(image_file(&record.id, mime))),
            Kind::Text { .. } => None,
        }
    }

    /// Records a copy, or moves the same content back to the top. None when it is too big.
    pub fn add(&mut self, content: Content, now: u64) -> Result<Option<String>> {
        let id = content.id();
        let kind = match content {
            Content::Text { text, uri_list } => {
                if text.len() > self.settings.max_text_bytes || text.trim().is_empty() {
                    return Ok(None);
                }
                Kind::Text { text, uri_list }
            }
            Content::Image { mime, bytes } => {
                if bytes.len() > self.settings.max_image_bytes {
                    return Ok(None);
                }
                let Ok(size) = imagesize::blob_size(&bytes) else {
                    return Ok(None);
                };
                let path = self.dir.join(image_file(&id, &mime));
                if !path.exists() {
                    write_atomic(&path, &bytes)?;
                }
                Kind::Image {
                    mime,
                    width: size.width as u32,
                    height: size.height as u32,
                }
            }
        };
        let pinned = match self.records.iter().position(|r| r.id == id) {
            Some(i) => self.records.remove(i).pinned,
            None => false,
        };
        self.records.insert(
            0,
            Record {
                id: id.clone(),
                time: now,
                pinned,
                kind,
            },
        );
        self.prune(now)?;
        Ok(Some(id))
    }

    pub fn set_pinned(&mut self, id: &str, pinned: bool, now: u64) -> Result<bool> {
        let Some(record) = self.records.iter_mut().find(|r| r.id == id) else {
            return Ok(false);
        };
        record.pinned = pinned;
        self.prune(now)?;
        Ok(true)
    }

    pub fn delete(&mut self, id: &str, now: u64) -> Result<bool> {
        let before = self.records.len();
        self.records.retain(|r| r.id != id);
        if self.records.len() == before {
            return Ok(false);
        }
        self.prune(now)?;
        Ok(true)
    }

    /// Drops every unpinned entry.
    pub fn clear(&mut self, now: u64) -> Result<()> {
        self.records.retain(|r| r.pinned);
        self.prune(now)
    }

    /// Keeps the pinned entries and the newest `max_entries` of the rest not older than
    /// `max_age_days`, deletes the image files no entry names, and saves.
    pub fn prune(&mut self, now: u64) -> Result<()> {
        let oldest = now.saturating_sub(self.settings.max_age_days.saturating_mul(DAY));
        let mut kept = 0;
        let max = self.settings.max_entries;
        self.records.retain(|r| {
            if r.pinned {
                return true;
            }
            if r.time < oldest || kept >= max {
                return false;
            }
            kept += 1;
            true
        });
        let files: HashSet<String> = self
            .records
            .iter()
            .filter_map(|r| match &r.kind {
                Kind::Image { mime, .. } => Some(image_file(&r.id, mime)),
                Kind::Text { .. } => None,
            })
            .collect();
        for entry in std::fs::read_dir(&self.dir)?.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name != HISTORY && !files.contains(&name) {
                let _ = std::fs::remove_file(entry.path());
            }
        }
        self.save()
    }

    fn save(&self) -> Result<()> {
        let file = File {
            entries: self.records.clone(),
        };
        write_atomic(&self.dir.join(HISTORY), &serde_json::to_vec(&file)?)
    }
}

fn image_file(id: &str, mime: &str) -> String {
    let ext = mime.strip_prefix("image/").unwrap_or("bin");
    format!("{id}.{ext}")
}

fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    let tmp = path.with_file_name(format!(
        ".{}.tmp",
        path.file_name().unwrap_or_default().to_string_lossy()
    ));
    std::fs::write(&tmp, bytes).with_context(|| format!("writing {}", tmp.display()))?;
    std::fs::rename(&tmp, path).with_context(|| format!("renaming to {}", path.display()))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub fn text(s: &str) -> Content {
        Content::Text {
            text: s.into(),
            uri_list: None,
        }
    }

    /// A 2×1 png.
    pub fn png() -> Vec<u8> {
        let mut png = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
        png.extend_from_slice(&2u32.to_be_bytes());
        png.extend_from_slice(&1u32.to_be_bytes());
        png.extend_from_slice(&[8, 6, 0, 0, 0, 0, 0, 0, 0]);
        png
    }

    fn settings() -> Settings {
        Settings {
            max_entries: 3,
            max_age_days: 2,
            max_text_bytes: 10,
            max_image_bytes: 1000,
            ..Settings::default()
        }
    }

    fn titles(store: &Store) -> Vec<String> {
        store
            .records()
            .iter()
            .map(|r| match &r.kind {
                Kind::Text { text, .. } => text.clone(),
                Kind::Image { mime, .. } => mime.clone(),
            })
            .collect()
    }

    #[test]
    fn copying_again_moves_to_top_without_duplicate() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(dir.path(), settings(), 100).unwrap();
        let a = store.add(text("a"), 100).unwrap().unwrap();
        store.add(text("b"), 101).unwrap();
        assert_eq!(store.add(text("a"), 102).unwrap().unwrap(), a);
        assert_eq!(titles(&store), ["a", "b"]);
        assert_eq!(store.records()[0].time, 102);
    }

    #[test]
    fn max_entries_keeps_the_newest_and_pinned_survive() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(dir.path(), settings(), 0).unwrap();
        let first = store.add(text("1"), 1).unwrap().unwrap();
        store.set_pinned(&first, true, 1).unwrap();
        for (i, t) in ["2", "3", "4", "5"].iter().enumerate() {
            store.add(text(t), 2 + i as u64).unwrap();
        }
        assert_eq!(titles(&store), ["5", "4", "3", "1"]);
        store.clear(10).unwrap();
        assert_eq!(titles(&store), ["1"]);
    }

    #[test]
    fn old_entries_are_dropped_unless_pinned() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(dir.path(), settings(), 0).unwrap();
        let old = store.add(text("old"), 0).unwrap().unwrap();
        store.add(text("older"), 0).unwrap();
        store.set_pinned(&old, true, 0).unwrap();
        store.add(text("new"), 3 * DAY).unwrap();
        assert_eq!(titles(&store), ["new", "old"]);
    }

    #[test]
    fn persists_across_reload() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(dir.path(), settings(), 0).unwrap();
        let a = store.add(text("a"), 1).unwrap().unwrap();
        store
            .add(
                Content::Text {
                    text: "b".into(),
                    uri_list: Some("file:///b".into()),
                },
                2,
            )
            .unwrap();
        store.set_pinned(&a, true, 2).unwrap();
        let records = store.records().to_vec();
        let reloaded = Store::open(dir.path(), settings(), 3).unwrap();
        assert_eq!(reloaded.records(), records);
    }

    #[test]
    fn oversized_and_blank_content_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(dir.path(), settings(), 0).unwrap();
        assert_eq!(store.add(text("01234567890"), 0).unwrap(), None);
        assert_eq!(store.add(text("  \n"), 0).unwrap(), None);
        let mut big = png();
        big.resize(1001, 0);
        let image = Content::Image {
            mime: "image/png".into(),
            bytes: big,
        };
        assert_eq!(store.add(image, 0).unwrap(), None);
        assert!(store.records().is_empty());
    }

    #[test]
    fn images_are_stored_and_orphans_removed() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(dir.path(), settings(), 0).unwrap();
        let image = Content::Image {
            mime: "image/png".into(),
            bytes: png(),
        };
        let id = store.add(image, 0).unwrap().unwrap();
        let record = store.get(&id).unwrap().clone();
        assert_eq!(
            record.kind,
            Kind::Image {
                mime: "image/png".into(),
                width: 2,
                height: 1
            }
        );
        let path = store.image_path(&record).unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), png());
        std::fs::write(dir.path().join("stray.png"), b"x").unwrap();
        store.delete(&id, 1).unwrap();
        assert!(!path.exists());
        assert!(!dir.path().join("stray.png").exists());
        assert!(dir.path().join(HISTORY).exists());
    }

    #[test]
    fn offers_prefer_text_then_images() {
        let png: Arc<[u8]> = Arc::from(png());
        let mut offer = Offer::text("hi");
        offer.mimes.push(("image/png".into(), png.clone()));
        assert_eq!(Content::from_offer(&offer), Some(text("hi")));
        let image = Offer {
            mimes: vec![("image/png".into(), png)],
        };
        assert!(matches!(
            Content::from_offer(&image),
            Some(Content::Image { .. })
        ));
        let uris = Offer {
            mimes: vec![(URI_LIST.into(), Arc::from(&b"file:///x"[..]))],
        };
        assert_eq!(
            Content::from_offer(&uris),
            Some(Content::Text {
                text: "file:///x".into(),
                uri_list: Some("file:///x".into())
            })
        );
    }
}
