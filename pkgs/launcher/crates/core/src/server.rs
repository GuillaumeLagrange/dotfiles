//! The socket panels connect to: one reader and one writer thread per connection, feeding the
//! engine's inbox and draining what it sends back.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Sender};

use anyhow::{bail, Context, Result};

use crate::engine::Msg;
use crate::protocol::{Event, Request};

/// Binds `path`, replacing a socket nobody listens on, and refusing one another daemon serves.
pub fn bind(path: &Path) -> Result<UnixListener> {
    if path.exists() {
        if UnixStream::connect(path).is_ok() {
            bail!("another launcher is listening on {}", path.display());
        }
        std::fs::remove_file(path).with_context(|| format!("removing stale {}", path.display()))?;
    }
    let listener =
        UnixListener::bind(path).with_context(|| format!("binding {}", path.display()))?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    Ok(listener)
}

/// Accepts connections forever.
pub fn serve(listener: UnixListener, engine: Sender<Msg>) {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        let id = NEXT.fetch_add(1, Ordering::Relaxed);
        if let Err(err) = connect(id, stream, engine.clone()) {
            eprintln!("launcher: connection {id}: {err:#}");
        }
    }
}

fn connect(id: u64, stream: UnixStream, engine: Sender<Msg>) -> Result<()> {
    let (tx, rx) = mpsc::channel::<Event>();
    let mut writer = stream.try_clone()?;
    std::thread::spawn(move || {
        for event in rx {
            let mut line = match serde_json::to_vec(&event) {
                Ok(line) => line,
                Err(err) => {
                    eprintln!("launcher: encoding an event: {err}");
                    continue;
                }
            };
            line.push(b'\n');
            if writer.write_all(&line).is_err() {
                break;
            }
        }
    });
    engine.send(Msg::Connected(id, tx))?;
    std::thread::spawn(move || {
        for line in BufReader::new(stream).lines() {
            let Ok(line) = line else { break };
            if line.trim().is_empty() {
                continue;
            }
            match serde_json::from_str::<Request>(&line) {
                Ok(request) => {
                    if engine.send(Msg::Request(id, request)).is_err() {
                        break;
                    }
                }
                Err(err) => eprintln!("launcher: connection {id}: bad request {line:?}: {err}"),
            }
        }
        let _ = engine.send(Msg::Gone(id));
    });
    Ok(())
}
