//! Firefox's bookmarks, read from a copy of each profile's `places.sqlite` (Firefox keeps the
//! original locked), with favicons from `favicons.sqlite` extracted once to the cache.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use anyhow::{Context, Result};
use rusqlite::Connection;

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Bookmark {
    /// The profile directory's hash.
    pub profile: String,
    pub id: i64,
    pub title: String,
    pub url: String,
    /// Parent folder titles, outermost first, joined with " / ".
    pub folder: String,
    pub icon: Option<PathBuf>,
    pub added: i64,
}

/// FNV-1a: stable across builds, unlike `DefaultHasher`.
pub(crate) fn hash(bytes: &[u8]) -> String {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in bytes {
        h ^= u64::from(*b);
        h = h.wrapping_mul(0x100000001b3);
    }
    format!("{h:016x}")
}

type Stamp = Vec<Option<SystemTime>>;

/// Each profile's bookmarks and the mtimes they were read at.
#[derive(Default)]
pub(crate) struct Loader {
    profiles: HashMap<PathBuf, (Stamp, Vec<Bookmark>)>,
}

const FILES: [&str; 4] = [
    "places.sqlite",
    "places.sqlite-wal",
    "favicons.sqlite",
    "favicons.sqlite-wal",
];

impl Loader {
    /// Rereads the profiles whose databases changed; `None` when none did.
    pub fn load(&mut self, dirs: &[PathBuf], cache: &Path) -> Option<Vec<Bookmark>> {
        let mut changed = self.profiles.len() != dirs.len()
            || !dirs.iter().all(|d| self.profiles.contains_key(d));
        let mut profiles = HashMap::new();
        for dir in dirs {
            let stamp: Stamp = FILES
                .iter()
                .map(|f| fs::metadata(dir.join(f)).and_then(|m| m.modified()).ok())
                .collect();
            match self.profiles.remove(dir) {
                Some((old, bookmarks)) if old == stamp => {
                    profiles.insert(dir.clone(), (stamp, bookmarks));
                }
                _ => {
                    changed = true;
                    // A profile that cannot be read (never used, mid-write) lists nothing until it changes.
                    let bookmarks = read_profile(dir, cache).unwrap_or_default();
                    profiles.insert(dir.clone(), (stamp, bookmarks));
                }
            }
        }
        self.profiles = profiles;
        if !changed {
            return None;
        }
        let mut all: Vec<Bookmark> = dirs
            .iter()
            .flat_map(|d| self.profiles[d].1.iter().cloned())
            .collect();
        all.sort_by_key(|b| std::cmp::Reverse(b.added));
        Some(all)
    }
}

/// Copies `name` (and its WAL) from `dir` into `to`, for a read that does not race Firefox.
pub(crate) fn copy_db(dir: &Path, name: &str, to: &Path) -> Result<Option<PathBuf>> {
    let src = dir.join(name);
    if !src.exists() {
        return Ok(None);
    }
    let dest = to.join(name);
    for suffix in ["", "-wal", "-shm"] {
        let _ = fs::remove_file(to.join(format!("{name}{suffix}")));
    }
    fs::copy(&src, &dest).with_context(|| format!("copying {}", src.display()))?;
    let wal = dir.join(format!("{name}-wal"));
    if wal.exists() {
        fs::copy(&wal, to.join(format!("{name}-wal")))?;
    }
    Ok(Some(dest))
}

fn read_profile(dir: &Path, cache: &Path) -> Result<Vec<Bookmark>> {
    let profile = hash(dir.as_os_str().as_encoded_bytes());
    let to = cache.join("browser").join(&profile);
    fs::create_dir_all(&to)?;
    let Some(places) = copy_db(dir, "places.sqlite", &to)? else {
        return Ok(Vec::new());
    };
    // Opened read-write: it is our copy, and SQLite replays a WAL only on a writable database.
    let db = Connection::open(&places)?;
    let mut bookmarks = read_bookmarks(&db, &profile)?;
    drop(db);
    if let Ok(Some(favicons)) = copy_db(dir, "favicons.sqlite", &to) {
        let icons = cache.join("favicons");
        if let Ok(found) = read_icons(
            &favicons,
            &icons,
            bookmarks.iter().map(|b| b.url.as_str()).collect(),
        ) {
            for b in &mut bookmarks {
                b.icon = found.get(&b.url).cloned();
            }
        }
    }
    Ok(bookmarks)
}

const ROOTS: [&str; 6] = [
    "root________",
    "menu________",
    "toolbar_____",
    "unfiled_____",
    "mobile______",
    "tags________",
];
const TAGS: &str = "tags________";

struct Row {
    id: i64,
    kind: i64,
    parent: i64,
    title: String,
    url: String,
    added: i64,
    guid: String,
}

fn read_bookmarks(db: &Connection, profile: &str) -> Result<Vec<Bookmark>> {
    let mut stmt = db.prepare(
        "SELECT b.id, b.type, b.parent, IFNULL(b.title, ''), IFNULL(p.url, ''), IFNULL(b.dateAdded, 0), IFNULL(b.guid, '')
         FROM moz_bookmarks b LEFT JOIN moz_places p ON p.id = b.fk",
    )?;
    let rows: Vec<Row> = stmt
        .query_map([], |r| {
            Ok(Row {
                id: r.get(0)?,
                kind: r.get(1)?,
                parent: r.get(2)?,
                title: r.get(3)?,
                url: r.get(4)?,
                added: r.get(5)?,
                guid: r.get(6)?,
            })
        })?
        .collect::<rusqlite::Result<_>>()?;
    let by_id: HashMap<i64, &Row> = rows.iter().map(|r| (r.id, r)).collect();

    // Folder titles from just under the roots down to the bookmark's parent; None under tags.
    let folder = |mut id: i64| -> Option<String> {
        let mut path = Vec::new();
        for _ in 0..64 {
            let Some(row) = by_id.get(&id) else { break };
            if row.guid == TAGS {
                return None;
            }
            if ROOTS.contains(&row.guid.as_str()) {
                break;
            }
            path.push(row.title.as_str());
            id = row.parent;
        }
        path.reverse();
        Some(path.join(" / "))
    };

    Ok(rows
        .iter()
        .filter(|r| r.kind == 1 && !r.url.is_empty() && !r.url.starts_with("place:"))
        .filter_map(|r| {
            Some(Bookmark {
                profile: profile.to_owned(),
                id: r.id,
                title: r.title.clone(),
                url: r.url.clone(),
                folder: folder(r.parent)?,
                icon: None,
                added: r.added,
            })
        })
        .collect())
}

fn is_png(data: &[u8]) -> bool {
    data.starts_with(b"\x89PNG\r\n\x1a\n")
}

fn is_svg(data: &[u8]) -> bool {
    let head = String::from_utf8_lossy(&data[..data.len().min(256)]);
    let head = head.trim_start();
    head.starts_with("<svg") || (head.starts_with("<?xml") && head.contains("<svg"))
}

/// The best icon of each of `urls`: an SVG, else the largest PNG up to 64px, written once to
/// `dir/<hash of its bytes>.{png,svg}`.
fn read_icons(db: &Path, dir: &Path, urls: HashSet<&str>) -> Result<HashMap<String, PathBuf>> {
    let db = Connection::open(db)?;
    let mut stmt = db.prepare(
        "SELECT p.page_url, i.width, i.data FROM moz_pages_w_icons p
         JOIN moz_icons_to_pages ip ON ip.page_id = p.id
         JOIN moz_icons i ON i.id = ip.icon_id
         WHERE i.data IS NOT NULL",
    )?;
    let mut best: HashMap<String, (i64, Vec<u8>, &str)> = HashMap::new();
    let mut rows = stmt.query([])?;
    while let Some(row) = rows.next()? {
        let url: String = row.get(0)?;
        if !urls.contains(url.as_str()) {
            continue;
        }
        let width: i64 = row.get(1)?;
        let data: Vec<u8> = row.get(2)?;
        let (score, ext) = if is_svg(&data) {
            (i64::MAX, "svg")
        } else if is_png(&data) && width <= 64 {
            (width, "png")
        } else {
            continue;
        };
        if best.get(&url).is_none_or(|(s, _, _)| score > *s) {
            best.insert(url, (score, data, ext));
        }
    }
    fs::create_dir_all(dir)?;
    let mut out = HashMap::new();
    for (url, (_, data, ext)) in best {
        let path = dir.join(format!("{}.{ext}", hash(&data)));
        if !path.exists() {
            let tmp = path.with_extension("tmp");
            fs::write(&tmp, &data)?;
            fs::rename(&tmp, &path)?;
        }
        out.insert(url, path);
    }
    Ok(out)
}
