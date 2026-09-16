//! Single niri IPC tap feeding the whole left side of the bar.
//!
//! Emits one JSON line per change:
//!   {"workspaces": [...], "by_output": {"<name>": {"title": ..., "strip": {...}}}}
//!
//! The strip is a scale model of the active workspace's scrolling layout: one
//! block per column, width proportional to the column's real width, plus a frame
//! marking the part of the workspace that is on screen. Geometry is emitted in
//! final pixels, so the yuck does no arithmetic and the invariants that matter
//! hold in one place.
//!
//! It talks to $NIRI_SOCKET directly and keeps the model in memory, so no process
//! is forked and nothing is re-queried; snapshots are printed only when they
//! differ, since the cost downstream is eww re-laying out its widget tree. Idle
//! cost is one process blocked on a socket read.
//!
//! niri does not report the scroll position: `tile_pos_in_workspace_view` is set
//! for floating tiles only, and is None for every tiled one, so the view is
//! reconstructed from the rule niri guarantees — the focused column is fully on
//! screen. A free scroll (touchpad swipe) can leave the frame a few pixels off
//! until the next focus change re-anchors it.

mod emit;
mod icons;
mod json;
mod model;
mod strip;

use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;

use crate::emit::snapshot;
use crate::icons::Icons;
use crate::json::{Json, Parser};
use crate::model::State;

fn request(socket: &str, request: &str) -> std::io::Result<Json> {
    let mut stream = UnixStream::connect(socket)?;
    writeln!(stream, "\"{request}\"")?;
    stream.shutdown(std::net::Shutdown::Write)?;
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line)?;
    Ok(Parser::parse(&line).unwrap_or(Json::Null))
}

fn outputs(socket: &str) -> BTreeMap<String, f64> {
    let Ok(reply) = request(socket, "Outputs") else {
        return BTreeMap::new();
    };
    reply
        .get("Ok")
        .get("Outputs")
        .fields()
        .iter()
        .filter_map(|(name, output)| {
            Some((name.clone(), output.get("logical").get("width").num()?))
        })
        .collect()
}

fn main() -> std::io::Result<()> {
    let socket = std::env::var("NIRI_SOCKET")
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::NotFound, "NIRI_SOCKET is not set"))?;

    let mut state = State {
        outputs: outputs(&socket),
        icons: Icons::from_env(),
        ..State::default()
    };

    let stream = UnixStream::connect(&socket)?;
    writeln!(&stream, "\"EventStream\"")?;
    let mut events = BufReader::new(stream);

    let stdout = std::io::stdout();
    let mut last = String::new();
    let mut line = String::new();
    let mut dirty = false;
    loop {
        line.clear();
        if events.read_line(&mut line)? == 0 {
            return Ok(());
        }
        if let Some(event) = Parser::parse(&line) {
            dirty |= state.apply(&event);
        }
        // niri emits bursts: the startup dump, or a drag moving every column.
        // Fold everything already buffered into one snapshot. `dirty` outlives
        // events carrying no state, so one of those ending a burst cannot swallow
        // the repaint.
        if !dirty || !events.buffer().is_empty() {
            continue;
        }
        dirty = false;
        let next = snapshot(&state);
        if next != last {
            let mut handle = stdout.lock();
            handle.write_all(next.as_bytes())?;
            handle.write_all(b"\n")?;
            handle.flush()?;
            last = next;
        }
    }
}
