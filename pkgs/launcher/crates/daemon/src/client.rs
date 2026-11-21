//! A client of the daemon's socket, speaking what the panel speaks.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use serde_json::{json, Value};

struct Conn {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
}

impl Conn {
    fn open(socket: &Path) -> Result<Conn> {
        let stream = UnixStream::connect(socket)
            .with_context(|| format!("connecting to {}", socket.display()))?;
        let mut conn = Conn {
            reader: BufReader::new(stream.try_clone()?),
            writer: stream,
        };
        let hello = conn
            .next(None)?
            .context("the daemon closed the connection")?;
        if hello["type"] != "hello" {
            bail!("expected hello, got {hello}");
        }
        Ok(conn)
    }

    fn send(&mut self, request: Value) -> Result<()> {
        let mut line = serde_json::to_vec(&request)?;
        line.push(b'\n');
        self.writer.write_all(&line)?;
        Ok(())
    }

    /// The next event, or None once `timeout` passes without one.
    fn next(&mut self, timeout: Option<Duration>) -> Result<Option<Value>> {
        self.reader.get_ref().set_read_timeout(timeout)?;
        let mut line = String::new();
        match self.reader.read_line(&mut line) {
            Ok(0) => bail!("the daemon closed the connection"),
            Ok(_) => Ok(Some(serde_json::from_str(&line)?)),
            Err(err)
                if matches!(
                    err.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                Ok(None)
            }
            Err(err) => Err(err.into()),
        }
    }

    /// The results answering `seq`, then whatever newer results arrive within `wait`.
    fn results(&mut self, seq: u64, wait: Duration) -> Result<Value> {
        let mut last = loop {
            let event = self.next(None)?.context("no results")?;
            match event["type"].as_str() {
                Some("results") if event["seq"] == seq => break event,
                Some("error") => bail!("{}", event["message"]),
                _ => {}
            }
        };
        let deadline = Instant::now() + wait;
        while let Some(left) = deadline
            .checked_duration_since(Instant::now())
            .filter(|d| !d.is_zero())
        {
            match self.next(Some(left))? {
                Some(event) if event["type"] == "results" => last = event,
                Some(_) => {}
                None => break,
            }
        }
        Ok(last)
    }

    fn open_mode(&mut self, mode: &str, text: &str, wait: Duration) -> Result<Value> {
        self.send(json!({"op": "open", "mode": mode}))?;
        if text.is_empty() {
            return self.results(0, wait);
        }
        self.results(0, Duration::ZERO)?;
        self.send(json!({"op": "query", "text": text, "seq": 1}))?;
        self.results(1, wait)
    }
}

/// The results for `text` in `mode`, as the daemon sent them.
pub fn query(socket: &Path, mode: &str, text: &str, wait_ms: u64) -> Result<String> {
    let mut conn = Conn::open(socket)?;
    let results = conn.open_mode(mode, text, Duration::from_millis(wait_ms))?;
    Ok(results.to_string())
}

/// Activates `id` after querying `text`, and prints the event that answers it.
pub fn activate(
    socket: &Path,
    mode: &str,
    text: &str,
    id: &str,
    action: Option<&str>,
) -> Result<String> {
    let mut conn = Conn::open(socket)?;
    conn.open_mode(mode, text, Duration::ZERO)?;
    let mut request = json!({"op": "activate", "id": id});
    if let Some(action) = action {
        request["action"] = json!(action);
    }
    conn.send(request)?;
    loop {
        let event = conn.next(None)?.context("no answer")?;
        if matches!(event["type"].as_str(), Some("done" | "error" | "switch")) {
            return Ok(event.to_string());
        }
    }
}
