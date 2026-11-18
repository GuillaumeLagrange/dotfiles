//! Each zellij session's look: a colour from the palette, its place in the order
//! sessions are listed in, and whether it is collapsed there. Set from the UIs
//! (omp-panel), never declared.
//!
//! Files, all derived from the state but `palette.json`:
//!
//!   $XDG_CONFIG_HOME/zellij-sessions/palette.json   [{"name","color"}], from home-manager
//!   $XDG_STATE_HOME/zellij-sessions/sessions.json   {"sessions":[{"name","color","collapsed"}]}
//!   $XDG_STATE_HOME/zellij-sessions/zellij/<name>.kdl
//!       zellij's config plus `theme "session-<color>"`: a session started with
//!       `--config` on it takes its colour, and live-reloads it when it changes
//!   $XDG_STATE_HOME/zellij-sessions/niri.kdl
//!       a window rule per session, bordering its terminal windows in its colour
//!
//! Without a palette (a machine with no desktop) nothing is coloured.

use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

#[derive(Deserialize, Serialize, Clone, Debug, PartialEq, Eq)]
pub struct Swatch {
    pub name: String,
    /// `#rrggbb`.
    pub color: String,
}

impl Swatch {
    pub fn rgb(&self) -> Option<(u8, u8, u8)> {
        let hex = self.color.strip_prefix('#')?;
        let byte = |i: usize| u8::from_str_radix(hex.get(i..i + 2)?, 16).ok();
        Some((byte(0)?, byte(2)?, byte(4)?))
    }

    pub fn theme(&self) -> String {
        format!("session-{}", self.name)
    }
}

#[derive(Deserialize, Serialize, Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub name: String,
    /// A palette swatch's name.
    pub color: Option<String>,
    #[serde(default)]
    pub collapsed: bool,
}

/// Every session ever seen, in the order they are listed.
#[derive(Deserialize, Serialize, Clone, Debug, Default, PartialEq, Eq)]
pub struct Registry {
    pub sessions: Vec<Entry>,
}

impl Registry {
    pub fn get(&self, name: &str) -> Option<&Entry> {
        self.sessions.iter().find(|e| e.name == name)
    }

    fn get_mut(&mut self, name: &str) -> Option<&mut Entry> {
        self.sessions.iter_mut().find(|e| e.name == name)
    }

    pub fn swatch<'a>(&self, name: &str, palette: &'a [Swatch]) -> Option<&'a Swatch> {
        let color = self.get(name)?.color.as_deref()?;
        palette.iter().find(|s| s.name == color)
    }

    pub fn collapsed(&self, name: &str) -> bool {
        self.get(name).is_some_and(|e| e.collapsed)
    }

    /// Add the names it lacks at the end, and give every one of them without a
    /// colour of the palette the colour fewest of the `live` sessions have, so
    /// sessions open side by side stay apart. Ties go to palette order.
    pub fn ensure(&mut self, names: &[&str], palette: &[Swatch], live: &[String]) {
        for name in names {
            if self.get(name).is_none() {
                self.sessions.push(Entry {
                    name: (*name).to_owned(),
                    color: None,
                    collapsed: false,
                });
            }
            let has_color = self
                .get(name)
                .and_then(|e| e.color.as_deref())
                .is_some_and(|c| palette.iter().any(|s| s.name == c));
            if has_color || palette.is_empty() {
                continue;
            }
            let live: HashSet<&str> = live.iter().map(String::as_str).collect();
            let mut used: HashMap<&str, usize> = HashMap::new();
            for entry in &self.sessions {
                if entry.name != *name && (live.is_empty() || live.contains(entry.name.as_str())) {
                    if let Some(color) = &entry.color {
                        *used.entry(color.as_str()).or_default() += 1;
                    }
                }
            }
            let pick = palette
                .iter()
                .min_by_key(|s| used.get(s.name.as_str()).copied().unwrap_or(0))
                .map(|s| s.name.clone());
            if let Some(entry) = self.get_mut(name) {
                entry.color = pick;
            }
        }
    }

    /// The next (or previous) colour of the palette.
    pub fn cycle_color(&mut self, name: &str, palette: &[Swatch], step: isize) {
        if palette.is_empty() {
            return;
        }
        self.ensure(&[name], palette, &[]);
        let Some(entry) = self.get_mut(name) else {
            return;
        };
        let at = entry
            .color
            .as_deref()
            .and_then(|c| palette.iter().position(|s| s.name == c))
            .unwrap_or(0) as isize;
        let next = (at + step).rem_euclid(palette.len() as isize) as usize;
        entry.color = Some(palette[next].name.clone());
    }

    pub fn set_color(&mut self, name: &str, color: &str, palette: &[Swatch]) -> bool {
        if !palette.iter().any(|s| s.name == color) {
            return false;
        }
        self.ensure(&[name], palette, &[]);
        if let Some(entry) = self.get_mut(name) {
            entry.color = Some(color.to_owned());
        }
        true
    }

    pub fn toggle_collapsed(&mut self, name: &str) {
        if self.get(name).is_none() {
            self.ensure(&[name], &[], &[]);
        }
        if let Some(entry) = self.get_mut(name) {
            entry.collapsed = !entry.collapsed;
        }
    }

    /// Swap `name` with its neighbour `delta` places away among `shown`, the
    /// sessions on screen in their current order: the ones that are not (gone,
    /// or filtered out) keep their place in the registry.
    pub fn move_among(&mut self, name: &str, delta: isize, shown: &[String]) {
        let names: Vec<&str> = shown.iter().map(String::as_str).collect();
        self.ensure(&names, &[], &[]);
        let Some(at) = shown.iter().position(|s| s == name) else {
            return;
        };
        let to = at as isize + delta;
        if to < 0 || to as usize >= shown.len() {
            return;
        }
        let other = &shown[to as usize];
        let a = self.sessions.iter().position(|e| e.name == name);
        let b = self.sessions.iter().position(|e| &e.name == other);
        if let (Some(a), Some(b)) = (a, b) {
            self.sessions.swap(a, b);
        }
    }

    /// Sort names by their place in the registry; unknown ones last, by name.
    pub fn sort(&self, names: &mut [String]) {
        let place: HashMap<&str, usize> = self
            .sessions
            .iter()
            .enumerate()
            .map(|(i, e)| (e.name.as_str(), i))
            .collect();
        names.sort_by(|a, b| {
            let key = |n: &String| place.get(n.as_str()).copied().unwrap_or(usize::MAX);
            key(a).cmp(&key(b)).then_with(|| a.cmp(b))
        });
    }
}

pub struct Store {
    config_dir: PathBuf,
    state_dir: PathBuf,
}

fn xdg(var: &str, fallback: &str) -> PathBuf {
    std::env::var_os(var)
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(fallback)))
        .unwrap_or_else(std::env::temp_dir)
}

impl Store {
    /// `config_dir` is `$XDG_CONFIG_HOME`, where zellij's config and the palette are.
    pub fn new(config_dir: PathBuf, state_dir: PathBuf) -> Self {
        Self {
            config_dir,
            state_dir,
        }
    }

    pub fn from_env() -> Self {
        Self::new(
            xdg("XDG_CONFIG_HOME", ".config"),
            xdg("XDG_STATE_HOME", ".local/state").join("zellij-sessions"),
        )
    }

    pub fn palette(&self) -> Vec<Swatch> {
        fs::read_to_string(self.config_dir.join("zellij-sessions/palette.json"))
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default()
    }

    fn registry_path(&self) -> PathBuf {
        self.state_dir.join("sessions.json")
    }

    pub fn zellij_config_path(&self, name: &str) -> PathBuf {
        self.state_dir.join("zellij").join(format!("{name}.kdl"))
    }

    pub fn niri_path(&self) -> PathBuf {
        self.state_dir.join("niri.kdl")
    }

    pub fn load(&self) -> Registry {
        fs::read_to_string(self.registry_path())
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default()
    }

    /// Change the registry under a lock, then bring every file derived from it up
    /// to date.
    pub fn update<R>(&self, change: impl FnOnce(&mut Registry, &[Swatch]) -> R) -> io::Result<R> {
        fs::create_dir_all(&self.state_dir)?;
        let lock = File::create(self.state_dir.join("lock"))?;
        lock.lock()?;
        let palette = self.palette();
        let mut registry = self.load();
        let before = registry.clone();
        let out = change(&mut registry, &palette);
        if registry != before {
            // In place, as every file here: the bar watches it by path.
            write_if_changed(
                &self.registry_path(),
                &serde_json::to_string_pretty(&registry)?,
            )?;
        }
        self.derive(&registry, &palette)?;
        Ok(out)
    }

    /// The zellij config a session should be started with: assigns it a colour
    /// first. None without a palette.
    pub fn zellij_config(&self, name: &str, live: &[String]) -> io::Result<Option<PathBuf>> {
        if self.palette().is_empty() {
            return Ok(None);
        }
        self.update(|registry, palette| registry.ensure(&[name], palette, live))?;
        let path = self.zellij_config_path(name);
        if !path.exists() {
            let registry = self.load();
            if let Some(swatch) = registry.swatch(name, &self.palette()) {
                write_if_changed(&path, &self.zellij_config_text(swatch))?;
            }
        }
        Ok(Some(path))
    }

    /// zellij looks for themes and layouts next to the config it was given.
    fn zellij_config_text(&self, swatch: &Swatch) -> String {
        let dir = self.config_dir.join("zellij");
        let base = fs::read_to_string(dir.join("config.kdl")).unwrap_or_default();
        format!(
            "{base}\ntheme_dir {}\nlayout_dir {}\ntheme \"{}\"\n",
            kdl_string(&dir.join("themes").to_string_lossy()),
            kdl_string(&dir.join("layouts").to_string_lossy()),
            swatch.theme()
        )
    }

    /// Rewrite what follows from the registry, each file only when it changes:
    /// zellij and niri reload on every write. A session's zellij config is only
    /// kept up to date once it exists, i.e. once the session was started on it.
    fn derive(&self, registry: &Registry, palette: &[Swatch]) -> io::Result<()> {
        if palette.is_empty() {
            return Ok(());
        }
        for entry in &registry.sessions {
            let path = self.zellij_config_path(&entry.name);
            if !path.exists() {
                continue;
            }
            if let Some(swatch) = registry.swatch(&entry.name, palette) {
                write_if_changed(&path, &self.zellij_config_text(swatch))?;
            }
        }
        write_if_changed(&self.niri_path(), &niri_rules(registry, palette))
    }
}

fn write_if_changed(path: &Path, text: &str) -> io::Result<()> {
    if fs::read_to_string(path).is_ok_and(|old| old == text) {
        return Ok(());
    }
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    // In place: zellij watches the file itself, and loses a file renamed over it.
    fs::write(path, text)
}

fn regex_escape(text: &str) -> String {
    let mut out = String::new();
    for c in text.chars() {
        if r"\.+*?()|[]{}^$#&-~".contains(c) {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

fn kdl_string(text: &str) -> String {
    format!("\"{}\"", text.replace('\\', "\\\\").replace('"', "\\\""))
}

/// zellij titles its terminal `<session> | <pane>`, or just the session.
pub fn session_of_title(title: &str) -> &str {
    title
        .split_once(" | ")
        .map_or(title, |(session, _)| session)
}

fn niri_rules(registry: &Registry, palette: &[Swatch]) -> String {
    let mut out =
        String::from("// Written by zellij-sessions: each session's terminals in its colour.\n");
    for entry in &registry.sessions {
        let Some(swatch) = registry.swatch(&entry.name, palette) else {
            continue;
        };
        let title = format!("^{}( \\| |$)", regex_escape(&entry.name));
        out.push_str(&format!(
            "window-rule {{\n    match app-id=\"^(zellij-session|kitty)$\" title={}\n    border {{\n        on\n        width 2\n        active-color \"{c}\"\n        inactive-color \"{c}80\"\n    }}\n}}\n",
            kdl_string(&title),
            c = swatch.color,
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn palette() -> Vec<Swatch> {
        ["red", "green", "blue"]
            .iter()
            .enumerate()
            .map(|(i, name)| Swatch {
                name: (*name).into(),
                color: format!("#00000{i}"),
            })
            .collect()
    }

    fn names(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn new_sessions_take_the_colour_fewest_live_ones_have() {
        let mut r = Registry::default();
        let p = palette();
        r.ensure(&["a", "b", "c"], &p, &[]);
        let colors: Vec<_> = r
            .sessions
            .iter()
            .map(|e| e.color.clone().unwrap())
            .collect();
        assert_eq!(colors, ["red", "green", "blue"]);

        // b is gone: its colour is free again.
        r.ensure(&["d"], &p, &names(&["a", "c", "d"]));
        assert_eq!(r.get("d").unwrap().color.as_deref(), Some("green"));
    }

    #[test]
    fn a_colour_the_palette_dropped_is_reassigned() {
        let mut r = Registry::default();
        r.sessions.push(Entry {
            name: "a".into(),
            color: Some("pink".into()),
            collapsed: true,
        });
        r.ensure(&["a"], &palette(), &[]);
        assert_eq!(r.get("a").unwrap().color.as_deref(), Some("red"));
        assert!(r.get("a").unwrap().collapsed, "the rest is kept");
    }

    #[test]
    fn moving_swaps_with_the_neighbour_on_screen_only() {
        let mut r = Registry::default();
        r.ensure(&["a", "gone", "b", "c"], &[], &[]);
        let shown = names(&["a", "b", "c"]);
        r.move_among("a", 1, &shown);
        let order: Vec<_> = r.sessions.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(order, ["b", "gone", "a", "c"]);
        r.move_among("c", 1, &names(&["b", "a", "c"]));
        assert_eq!(r.sessions.last().unwrap().name, "c", "already last");

        let mut live = names(&["c", "z", "a", "b"]);
        r.sort(&mut live);
        assert_eq!(live, ["b", "a", "c", "z"]);
    }

    #[test]
    fn colours_follow_through_to_zellij_and_niri() {
        let dir = tempfile::tempdir().unwrap();
        let config = dir.path().join("config");
        fs::create_dir_all(config.join("zellij-sessions")).unwrap();
        fs::create_dir_all(config.join("zellij")).unwrap();
        fs::write(
            config.join("zellij-sessions/palette.json"),
            serde_json::to_string(&palette()).unwrap(),
        )
        .unwrap();
        fs::write(config.join("zellij/config.kdl"), "pane_frames false\n").unwrap();
        let store = Store::new(config, dir.path().join("state"));

        let path = store.zellij_config("my.session", &[]).unwrap().unwrap();
        let text = fs::read_to_string(&path).unwrap();
        assert!(text.starts_with("pane_frames false\n"));
        assert!(text.ends_with("theme \"session-red\"\n"));
        let niri = fs::read_to_string(store.niri_path()).unwrap();
        assert!(niri.contains(r#"title="^my\\.session( \\| |$)""#), "{niri}");

        store
            .update(|r, p| r.cycle_color("my.session", p, 1))
            .unwrap();
        assert!(fs::read_to_string(&path)
            .unwrap()
            .ends_with("theme \"session-green\"\n"));
        assert!(fs::read_to_string(store.niri_path())
            .unwrap()
            .contains("#000001"));
    }

    #[test]
    fn without_a_palette_nothing_is_written() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::new(dir.path().join("config"), dir.path().join("state"));
        assert_eq!(store.zellij_config("a", &[]).unwrap(), None);
        assert!(!store.niri_path().exists());
    }

    #[test]
    fn the_session_is_the_title_up_to_its_first_separator() {
        assert_eq!(session_of_title("work | vim | x"), "work");
        assert_eq!(session_of_title("work"), "work");
    }
}
