//! How often and how lately each entry was picked: points that halve every two weeks, one
//! added per pick. Kept in `$XDG_STATE_HOME/launcher/frecency.json`.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::source::Mode;

const HALF_LIFE_SECS: f64 = 14.0 * 24.0 * 3600.0;
/// Below this an entry is forgotten.
const FORGET: f64 = 0.05;

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
struct Record {
    points: f64,
    /// Unix seconds of the last pick.
    last: u64,
}

impl Record {
    fn at(&self, now: u64) -> f64 {
        let age = now.saturating_sub(self.last) as f64;
        self.points * 0.5f64.powf(age / HALF_LIFE_SECS)
    }
}

#[derive(Default)]
struct Inner {
    path: Option<PathBuf>,
    records: HashMap<String, Record>,
}

#[derive(Clone, Default)]
pub struct Frecency(Arc<Mutex<Inner>>);

fn key(mode: Mode, id: &str) -> String {
    format!("{}:{id}", mode.name())
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

impl Frecency {
    /// Loads the file, or starts empty when it is missing or unreadable.
    pub fn load(path: PathBuf) -> Frecency {
        let records = std::fs::read_to_string(&path)
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default();
        Frecency(Arc::new(Mutex::new(Inner {
            path: Some(path),
            records,
        })))
    }

    /// Not kept on disk, for tests.
    pub fn in_memory() -> Frecency {
        Frecency::default()
    }

    pub fn score(&self, mode: Mode, id: &str) -> f64 {
        self.score_at(mode, id, now())
    }

    fn score_at(&self, mode: Mode, id: &str, now: u64) -> f64 {
        let inner = self.0.lock().unwrap();
        inner.records.get(&key(mode, id)).map_or(0.0, |r| r.at(now))
    }

    pub fn bump(&self, mode: Mode, id: &str) {
        self.bump_at(mode, id, now());
    }

    fn bump_at(&self, mode: Mode, id: &str, now: u64) {
        let mut inner = self.0.lock().unwrap();
        let record = inner.records.entry(key(mode, id)).or_insert(Record {
            points: 0.0,
            last: now,
        });
        *record = Record {
            points: record.at(now) + 1.0,
            last: now,
        };
        inner.records.retain(|_, r| r.at(now) >= FORGET);
        if let Some(path) = &inner.path {
            if let Err(err) = write(path, &inner.records) {
                eprintln!("launcher: saving frecency: {err:#}");
            }
        }
    }
}

fn write(path: &PathBuf, records: &HashMap<String, Record>) -> anyhow::Result<()> {
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec(records)?)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn picks_add_up_and_fade() {
        let f = Frecency::in_memory();
        f.bump_at(Mode::Apps, "a", 1_000);
        f.bump_at(Mode::Apps, "a", 1_000);
        assert!((f.score_at(Mode::Apps, "a", 1_000) - 2.0).abs() < 1e-9);
        let later = 1_000 + HALF_LIFE_SECS as u64;
        assert!((f.score_at(Mode::Apps, "a", later) - 1.0).abs() < 1e-6);
        assert_eq!(f.score_at(Mode::Emoji, "a", 1_000), 0.0);
    }

    #[test]
    fn survives_a_restart() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("frecency.json");
        Frecency::load(path.clone()).bump(Mode::Apps, "firefox.desktop");
        assert!(Frecency::load(path).score(Mode::Apps, "firefox.desktop") > 0.9);
    }
}
