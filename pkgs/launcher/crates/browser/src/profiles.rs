//! Firefox's profiles: their directories, from the `profiles.ini` files, and their names. The
//! profile manager of recent Firefox names its profiles in the group database the ini's
//! `StoreID` points at (`Profile Groups/<StoreID>.sqlite`); the ini's own `Name` is the old
//! manager's, used for a profile the database does not list.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::Result;
use rusqlite::Connection;

use crate::bookmarks::copy_db;

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Profile {
    /// Canonical.
    pub dir: PathBuf,
    pub name: String,
}

#[derive(Default)]
struct Section {
    path: Option<String>,
    relative: bool,
    name: String,
    store: Option<String>,
}

/// Each profile the `profiles.ini` files name, once, in the order they first appear. A group
/// database is read from a copy under `cache`: Firefox holds the original open.
pub(crate) fn profiles(inis: &[PathBuf], cache: &Path) -> Vec<Profile> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for ini in inis {
        let Ok(text) = fs::read_to_string(ini) else {
            continue;
        };
        let base = ini.parent().unwrap_or(Path::new("/"));
        let sections = sections(&text);
        let mut names = HashMap::new();
        let stores: HashSet<&str> = sections.iter().filter_map(|s| s.store.as_deref()).collect();
        for store in stores {
            // A database that cannot be read leaves the ini's names.
            if let Ok(group) = group_names(base, store, cache) {
                names.extend(group);
            }
        }
        for s in &sections {
            let Some(path) = &s.path else { continue };
            let dir = canonical(if s.relative {
                base.join(path)
            } else {
                PathBuf::from(path)
            });
            if seen.insert(dir.clone()) {
                let name = names.get(&dir).cloned().unwrap_or_else(|| s.name.clone());
                out.push(Profile { dir, name });
            }
        }
    }
    out
}

fn canonical(dir: PathBuf) -> PathBuf {
    fs::canonicalize(&dir).unwrap_or(dir)
}

/// The `[Profile*]` sections.
fn sections(ini: &str) -> Vec<Section> {
    let mut out = Vec::new();
    let mut current: Option<Section> = None;
    for line in ini.lines().map(str::trim) {
        if let Some(header) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
            out.extend(current.take());
            current = header.starts_with("Profile").then(|| Section {
                relative: true,
                ..Section::default()
            });
        } else if let (Some((key, value)), Some(cur)) = (line.split_once('='), current.as_mut()) {
            let value = value.trim();
            match key.trim() {
                "Path" => cur.path = Some(value.to_owned()),
                "IsRelative" => cur.relative = value == "1",
                "Name" => cur.name = value.to_owned(),
                "StoreID" => cur.store = Some(value.to_owned()),
                _ => {}
            }
        }
    }
    out.extend(current);
    out
}

/// The names the group database `store` gives, by canonical profile directory.
fn group_names(base: &Path, store: &str, cache: &Path) -> Result<HashMap<PathBuf, String>> {
    let to = cache.join("browser").join("groups");
    fs::create_dir_all(&to)?;
    let Some(db) = copy_db(
        &base.join("Profile Groups"),
        &format!("{store}.sqlite"),
        &to,
    )?
    else {
        return Ok(HashMap::new());
    };
    // Read-write, so SQLite replays the copied WAL.
    let db = Connection::open(db)?;
    let mut stmt = db.prepare("SELECT path, name FROM Profiles")?;
    let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
    let mut names = HashMap::new();
    for row in rows {
        let (path, name) = row?;
        names.insert(canonical(base.join(path)), name);
    }
    Ok(names)
}
