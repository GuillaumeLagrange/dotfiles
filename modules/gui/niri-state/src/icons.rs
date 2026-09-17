//! Resolves a window's `app_id` to an icon file, following the XDG basedir and
//! icon-theme specs.
//!
//! An `app_id` is rarely the icon name — `Spotify` ships `spotify-client`, `signal`
//! ships `signal-desktop` — so `.desktop` entries provide the name and the icon
//! directories are then probed for a file with it.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// Probed in order, so a mid-size raster is preferred over an upscale of a small
/// one or a rasterised SVG.
const SIZES: [&str; 8] = [
    "48x48", "64x64", "32x32", "96x96", "128x128", "256x256", "512x512", "scalable",
];
const THEMES: [&str; 3] = ["hicolor", "Adwaita", "gnome"];
const EXTENSIONS: [&str; 2] = ["png", "svg"];

#[derive(Default)]
pub struct Icons {
    /// Lowercased `app_id` candidates to the `Icon=` value of their entry.
    names: BTreeMap<String, String>,
    data_dirs: Vec<PathBuf>,
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
        Icons::new(dirs)
    }

    pub fn new(data_dirs: Vec<PathBuf>) -> Icons {
        let mut names = BTreeMap::new();
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
                    names.insert(class.to_lowercase(), icon);
                }
            }
        }
        Icons { names, data_dirs }
    }

    /// Absolute path of the icon file, or an empty string when nothing matches.
    pub fn path_for(&self, app_id: &str) -> String {
        if app_id.is_empty() {
            return String::new();
        }
        let id = app_id.to_lowercase();
        // Reverse-DNS ids (`md.Obsidian`) are filed under their last part by some
        // toolkits and under the whole id by others, so try both.
        let tail = id.rsplit('.').next().unwrap_or(&id).to_string();
        let name = self
            .names
            .get(&id)
            .or_else(|| self.names.get(&tail))
            .cloned()
            .unwrap_or(tail);

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

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("niri-state-icons-{name}"));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
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
        let icons = Icons::new(vec![dir.clone()]);
        assert_eq!(
            icons.path_for("Spotify"),
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
        let icons = Icons::new(vec![dir]);
        assert!(icons.path_for("md.Obsidian").ends_with("obsidian.png"));
    }

    #[test]
    fn falls_back_to_the_app_id_as_an_icon_name() {
        let dir = scratch("no-entry");
        let icons_dir = dir.join("icons/hicolor/48x48/apps");
        std::fs::create_dir_all(&icons_dir).unwrap();
        std::fs::write(icons_dir.join("kitty.png"), b"").unwrap();
        assert!(Icons::new(vec![dir])
            .path_for("kitty")
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
        let icons = Icons::new(vec![dir]);
        assert_eq!(icons.path_for("com.example.Nothing"), "");
        assert_eq!(icons.path_for(""), "");
    }
}
