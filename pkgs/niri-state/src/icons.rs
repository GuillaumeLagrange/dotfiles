//! Resolves a window's `app_id` to an icon file, following the XDG basedir and
//! icon-theme specs.
//!
//! An `app_id` is rarely the icon name — `Spotify` ships `spotify-client`, `signal`
//! ships `signal-desktop` — so `.desktop` entries provide the name and the icon
//! directories are then probed for a file with it.

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::xicons::XIcons;

/// Probed in order, so a mid-size raster is preferred over an upscale of a small
/// one or a rasterised SVG.
const SIZES: [&str; 8] = [
    "48x48", "64x64", "32x32", "96x96", "128x128", "256x256", "512x512", "scalable",
];
const THEMES: [&str; 3] = ["hicolor", "Adwaita", "gnome"];
const EXTENSIONS: [&str; 2] = ["png", "svg"];

/// What Proton gives every window of a game it runs outside Steam (a Lutris or
/// umu launch), so the window title is all that tells them apart.
const PROTON_SHARED_ID: &str = "steam_app_default";

#[derive(Default)]
pub struct Icons {
    /// Lowercased `app_id` candidates to the `Icon=` value of their entry.
    names: BTreeMap<String, String>,
    /// Lowercased `Name=` of each entry to its `Icon=`.
    titles: BTreeMap<String, String>,
    data_dirs: Vec<PathBuf>,
    /// `path_for` results by `app_id` (and title, for Proton's shared id): a title
    /// change re-sends the whole window, and a lookup is hundreds of `stat` calls.
    resolved: RefCell<BTreeMap<String, String>>,
    x: RefCell<XIcons>,
}

impl Icons {
    pub fn from_env() -> Icons {
        let home = std::env::var("HOME").unwrap_or_default();
        let mut dirs: Vec<PathBuf> = Vec::new();
        if let Ok(data_home) = std::env::var("XDG_DATA_HOME") {
            dirs.push(PathBuf::from(data_home));
        } else if !home.is_empty() {
            dirs.push(Path::new(&home).join(".local/share"));
        }
        let data_dirs =
            std::env::var("XDG_DATA_DIRS").unwrap_or_else(|_| "/usr/local/share:/usr/share".into());
        dirs.extend(
            data_dirs
                .split(':')
                .filter(|d| !d.is_empty())
                .map(PathBuf::from),
        );
        let mut icons = Icons::new(dirs);
        let cache = match std::env::var("XDG_CACHE_HOME") {
            Ok(dir) => PathBuf::from(dir),
            Err(_) => Path::new(&home).join(".cache"),
        };
        icons.x = RefCell::new(XIcons::new(cache.join("niri-state/icons")));
        icons
    }

    pub fn new(data_dirs: Vec<PathBuf>) -> Icons {
        let mut names = BTreeMap::new();
        let mut titles = BTreeMap::new();
        for dir in &data_dirs {
            let Ok(entries) = std::fs::read_dir(dir.join("applications")) else {
                continue;
            };
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().is_none_or(|e| e != "desktop") {
                    continue;
                }
                let Ok(text) = std::fs::read_to_string(&path) else {
                    continue;
                };
                let field = |key: &str| {
                    text.lines()
                        .find_map(|l| l.strip_prefix(key))
                        .map(|v| v.trim().to_string())
                };
                let Some(icon) = field("Icon=") else { continue };
                // StartupWMClass is what the window announces, so it wins over the
                // file name when both are present.
                if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                    names
                        .entry(stem.to_lowercase())
                        .or_insert_with(|| icon.clone());
                }
                if let Some(class) = field("StartupWMClass=") {
                    names.insert(class.to_lowercase(), icon.clone());
                }
                // A Steam game's window is `steam_app_<id>`, its entry only
                // launches `steam://rungameid/<id>`.
                if let Some(id) = field("Exec=").and_then(|exec| {
                    let (_, rest) = exec.split_once("steam://rungameid/")?;
                    let id: String = rest.chars().take_while(char::is_ascii_digit).collect();
                    (!id.is_empty()).then_some(id)
                }) {
                    names.insert(format!("steam_app_{id}"), icon.clone());
                }
                if let Some(name) = field("Name=") {
                    titles.entry(name.to_lowercase()).or_insert(icon);
                }
            }
        }
        Icons {
            names,
            titles,
            data_dirs,
            resolved: RefCell::default(),
            x: RefCell::default(),
        }
    }

    /// Absolute path of the icon file, or an empty string when nothing matches.
    /// An X11 window no entry resolves falls back to the icon it publishes.
    pub fn path_for(&self, app_id: &str, title: &str, pid: u32) -> String {
        let key = if app_id == PROTON_SHARED_ID {
            format!("{app_id}\n{title}")
        } else {
            app_id.to_string()
        };
        let cached = self.resolved.borrow().get(&key).cloned();
        let path = cached.unwrap_or_else(|| {
            let path = self.resolve(app_id, title);
            self.resolved.borrow_mut().insert(key, path.clone());
            path
        });
        if path.is_empty() {
            return self.x.borrow_mut().path_for(pid, app_id, title);
        }
        path
    }

    fn resolve(&self, app_id: &str, title: &str) -> String {
        if app_id.is_empty() {
            return String::new();
        }
        let id = app_id.to_lowercase();
        // Reverse-DNS ids (`md.Obsidian`) are filed under their last part by some
        // toolkits and under the whole id by others, so try both.
        let tail = id.rsplit('.').next().unwrap_or(&id).to_string();
        let name = if app_id == PROTON_SHARED_ID {
            match self.titles.get(&title.to_lowercase()) {
                Some(name) => name.clone(),
                None => return String::new(),
            }
        } else {
            self.names
                .get(&id)
                .or_else(|| self.names.get(&tail))
                .cloned()
                .unwrap_or(tail)
        };

        // `Icon=` may already be a path rather than a themed name.
        if name.starts_with('/') {
            return if Path::new(&name).exists() {
                name
            } else {
                String::new()
            };
        }
        self.find_file(&name).unwrap_or_default()
    }

    fn find_file(&self, name: &str) -> Option<String> {
        let candidates = self.data_dirs.iter().flat_map(|dir| {
            let themed = THEMES.iter().flat_map(move |theme| {
                SIZES.iter().flat_map(move |size| {
                    EXTENSIONS.iter().map(move |ext| {
                        dir.join("icons")
                            .join(theme)
                            .join(size)
                            .join("apps")
                            .join(format!("{name}.{ext}"))
                    })
                })
            });
            let pixmaps = EXTENSIONS
                .iter()
                .map(move |ext| dir.join("pixmaps").join(format!("{name}.{ext}")));
            themed.chain(pixmaps)
        });
        candidates
            .filter(|path| path.exists())
            .find_map(|path| path.to_str().map(str::to_string))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A data directory holding one application entry and its icon file.
    fn fixture(dir: &Path, desktop: &str, entry: &str, icon_file: &str) {
        let apps = dir.join("applications");
        std::fs::create_dir_all(&apps).unwrap();
        std::fs::write(apps.join(format!("{desktop}.desktop")), entry).unwrap();
        let icons = dir.join("icons/hicolor/48x48/apps");
        std::fs::create_dir_all(&icons).unwrap();
        std::fs::write(icons.join(icon_file), b"").unwrap();
    }

    /// A data directory of this process's own, removed when the test is done.
    struct Scratch(PathBuf);

    impl std::ops::Deref for Scratch {
        type Target = Path;
        fn deref(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn scratch(name: &str) -> Scratch {
        let dir =
            std::env::temp_dir().join(format!("niri-state-icons-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        Scratch(dir)
    }

    #[test]
    fn resolves_through_startup_wm_class() {
        // The case a plain name lookup cannot reach: the window announces `Spotify`
        // while the icon is filed as `spotify-client`.
        let dir = scratch("wmclass");
        fixture(
            &dir,
            "spotify",
            "[Desktop Entry]\nIcon=spotify-client\nStartupWMClass=Spotify\n",
            "spotify-client.png",
        );
        let icons = Icons::new(vec![dir.to_path_buf()]);
        assert_eq!(
            icons.path_for("Spotify", "", 0),
            dir.join("icons/hicolor/48x48/apps/spotify-client.png")
                .to_str()
                .unwrap()
        );
    }

    #[test]
    fn resolves_reverse_dns_ids_by_their_last_part() {
        let dir = scratch("reverse-dns");
        fixture(
            &dir,
            "obsidian",
            "[Desktop Entry]\nIcon=obsidian\n",
            "obsidian.png",
        );
        let icons = Icons::new(vec![dir.to_path_buf()]);
        assert!(icons
            .path_for("md.Obsidian", "", 0)
            .ends_with("obsidian.png"));
    }

    #[test]
    fn falls_back_to_the_app_id_as_an_icon_name() {
        let dir = scratch("no-entry");
        let icons_dir = dir.join("icons/hicolor/48x48/apps");
        std::fs::create_dir_all(&icons_dir).unwrap();
        std::fs::write(icons_dir.join("kitty.png"), b"").unwrap();
        assert!(Icons::new(vec![dir.to_path_buf()])
            .path_for("kitty", "", 0)
            .ends_with("kitty.png"));
    }

    #[test]
    fn unknown_apps_resolve_to_nothing() {
        let dir = scratch("unknown");
        fixture(
            &dir,
            "firefox",
            "[Desktop Entry]\nIcon=firefox\n",
            "firefox.png",
        );
        let icons = Icons::new(vec![dir.to_path_buf()]);
        assert_eq!(icons.path_for("com.example.Nothing", "", 0), "");
        assert_eq!(icons.path_for("", "", 0), "");
    }

    #[test]
    fn resolves_steam_games_through_their_launch_url() {
        let dir = scratch("steam");
        fixture(
            &dir,
            "Deadlock",
            "[Desktop Entry]\nName=Deadlock\nExec=steam steam://rungameid/1422450\nIcon=steam_icon_1422450\n",
            "steam_icon_1422450.png",
        );
        let icons = Icons::new(vec![dir.to_path_buf()]);
        assert!(icons
            .path_for("steam_app_1422450", "Deadlock", 0)
            .ends_with("steam_icon_1422450.png"));
        assert_eq!(icons.path_for("steam_app_142245", "Deadlock", 0), "");
    }

    #[test]
    fn proton_games_outside_steam_resolve_by_title() {
        let dir = scratch("proton");
        fixture(
            &dir,
            "net.lutris.battlenet-1",
            "[Desktop Entry]\nName=Battle.net\nIcon=lutris_battlenet\n",
            "lutris_battlenet.png",
        );
        let icons = Icons::new(vec![dir.to_path_buf()]);
        assert!(icons
            .path_for("steam_app_default", "Battle.net", 0)
            .ends_with("lutris_battlenet.png"));
        // Another game sharing the id must not take the first one's cached icon.
        assert_eq!(
            icons.path_for("steam_app_default", "World of Warcraft", 0),
            ""
        );
    }
}
