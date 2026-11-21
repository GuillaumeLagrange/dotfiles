//! A context for source tests: directories under a temporary root, a clipboard that records
//! what it is asked to copy, and the modes the source reported updated.

use std::path::Path;
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::clipboard::{Clipboard, Offer, Sink};
use crate::config::Config;
use crate::engine::{self, Msg};
use crate::frecency::Frecency;
use crate::source::{Ctx, Dirs, Mode};

#[derive(Debug, Clone, PartialEq)]
pub struct Copied {
    pub offer: Offer,
    pub secret: bool,
}

impl Copied {
    pub fn text(&self) -> Option<&str> {
        self.offer.as_text()
    }
}

#[derive(Default)]
struct Recorder(Mutex<Vec<Copied>>);

impl Sink for Recorder {
    fn copy(&self, offer: Offer, secret: bool) {
        self.0.lock().unwrap().push(Copied { offer, secret });
    }
}

pub struct Handles {
    rx: Receiver<Msg>,
    recorder: Arc<Recorder>,
}

impl Handles {
    /// What sources copied, oldest first.
    pub fn copies(&self) -> Vec<Copied> {
        self.recorder.0.lock().unwrap().clone()
    }

    /// Waits until `mode` is reported updated, for at most `timeout`.
    pub fn wait_updated(&self, mode: Mode, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match self.rx.recv_timeout(left) {
                Ok(Msg::Updated(m)) if m == mode => return true,
                Ok(_) => {}
                Err(_) => return false,
            }
        }
    }

    /// The next end of an `Outcome::Wait`'s work, for the engine's tests to hand it.
    #[cfg(test)]
    pub(crate) fn wait_finished(&self, timeout: Duration) -> Option<Msg> {
        let deadline = Instant::now() + timeout;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match self.rx.recv_timeout(left) {
                Ok(msg @ Msg::Finished { .. }) => return Some(msg),
                Ok(_) => {}
                Err(_) => return None,
            }
        }
    }
}

pub(crate) fn ctx(root: &Path, config: Config) -> (Ctx, Handles) {
    let dirs = Dirs::under(root).expect("test directories");
    let recorder = Arc::new(Recorder::default());
    let (_tx, updater, rx) = engine::channel();
    let ctx = Ctx::new(
        Arc::new(config),
        Arc::new(dirs),
        Clipboard::new(recorder.clone()),
        Frecency::in_memory(),
        updater,
    );
    (ctx, Handles { rx, recorder })
}
