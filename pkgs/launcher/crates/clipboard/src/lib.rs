//! The clipboard manager: the Wayland watcher, the history, and the selection the daemon serves.

mod history;
mod pipe;
mod store;
mod wayland;

#[cfg(test)]
mod e2e;

use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use launcher_core::engine::Updater;
use launcher_core::{Clipboard, Config, Dirs, Mode, Source};
use serde::Deserialize;

use crate::history::{History, HistorySource};
use crate::store::Store;
use crate::wayland::{Limits, WaylandSink};

pub struct Service {
    /// What sources copy through.
    pub clipboard: Clipboard,
    /// The history mode, when the config enables it.
    pub source: Option<Box<dyn Source>>,
    /// Says why once the compositor connection is gone; nothing works without it after that.
    pub lost: Receiver<String>,
}

/// The `clipboard` section of the config.
#[derive(Debug, Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Settings {
    pub max_entries: usize,
    pub max_age_days: u64,
    pub max_text_bytes: usize,
    pub max_image_bytes: usize,
    pub secret_clear_seconds: u64,
}

impl Default for Settings {
    fn default() -> Settings {
        Settings {
            max_entries: 1000,
            max_age_days: 30,
            max_text_bytes: 1 << 20,
            max_image_bytes: 20 << 20,
            secret_clear_seconds: 30,
        }
    }
}

/// Connects to the compositor (`$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY`) and starts watching the
/// selection.
pub fn start(config: &Config, dirs: &Dirs, updater: Updater) -> Result<Service> {
    let socket = std::env::var_os("WAYLAND_DISPLAY").map(|display| {
        let display = PathBuf::from(display);
        if display.is_absolute() {
            display
        } else {
            dirs.runtime.join(display)
        }
    });
    start_on(socket.as_deref(), config, dirs, updater)
}

fn start_on(
    socket: Option<&Path>,
    config: &Config,
    dirs: &Dirs,
    updater: Updater,
) -> Result<Service> {
    let settings: Settings = config.section(Mode::Clipboard)?;
    let limits = Limits {
        max_text_bytes: settings.max_text_bytes,
        max_image_bytes: settings.max_image_bytes,
        secret_clear: Duration::from_secs(settings.secret_clear_seconds),
    };
    let history = if config.enabled(Mode::Clipboard) {
        let store = Store::open(&dirs.data.join("clipboard"), settings, history::now())
            .context("opening the clipboard history")?;
        let history = Arc::new(History::new(store, updater));
        let daily = Arc::downgrade(&history);
        std::thread::Builder::new()
            .name("clipboard-prune".into())
            .spawn(move || loop {
                std::thread::sleep(Duration::from_secs(86_400));
                match daily.upgrade() {
                    Some(history) => history.prune(),
                    None => break,
                }
            })?;
        Some(history)
    } else {
        None
    };
    let socket = socket.context("WAYLAND_DISPLAY is not set")?;
    let (lost_tx, lost) = mpsc::channel();
    let wayland = wayland::connect(socket, history.clone(), limits, true, Some(lost_tx))?;
    let clipboard = Clipboard::new(Arc::new(WaylandSink(wayland)));
    let source = history.map(|history| {
        Box::new(HistorySource {
            history,
            clipboard: clipboard.clone(),
        }) as Box<dyn Source>
    });
    Ok(Service {
        clipboard,
        source,
        lost,
    })
}
