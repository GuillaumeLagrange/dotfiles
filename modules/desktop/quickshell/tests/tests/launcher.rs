//! The launcher panel against a stub daemon: a unix socket at the fixture's
//! `$XDG_RUNTIME_DIR/launcher.sock` that speaks the protocol of
//! `pkgs/launcher/AGENTS.md` from a fixture table and records every request.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use quickshell_tests::Session;
use serde_json::{json, Value};

#[derive(Default)]
struct State {
    requests: Vec<Value>,
    writer: Option<UnixStream>,
    mode: String,
    query: String,
    seq: u64,
    /// What `done` answers an activation with.
    stay: bool,
    /// Queries are kept unanswered until `release`, as a slow source keeps them.
    hold: bool,
    held: Vec<Value>,
    /// Activations are answered with `working` saying this, their end left to `finish`.
    work: Option<String>,
}

struct Stub {
    path: PathBuf,
    state: Arc<Mutex<State>>,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

fn action(id: &str, label: &str, key: Option<&str>) -> Value {
    json!({ "id": id, "label": label, "key": key })
}

fn item(id: &str, title: &str, query: &str, preview: bool) -> Value {
    let hl = match title.to_lowercase().find(&query.to_lowercase()) {
        Some(at) if !query.is_empty() => json!([[at, at + query.len()]]),
        _ => json!([]),
    };
    json!({
        "id": id, "title": title, "subtitle": format!("{title} subtitle"), "hl": hl, "shl": [],
        "icon": { "kind": "glyph", "value": "apps" }, "accessory": "", "color": null, "section": "",
        "actions": [
            action("open", "Open", Some("Return")),
            action("new-window", "New window", Some("Alt+Return")),
            action("terminal", "Run in terminal", Some("Ctrl+Return")),
            action("copy-path", "Copy path", None),
        ],
        "preview": preview,
    })
}

/// The fixture table: each mode's rows matching `query`.
fn items(mode: &str, query: &str) -> Vec<Value> {
    if mode == "windows" {
        return windows(query);
    }
    let rows: &[(&str, &str)] = match mode {
        "apps" => &[("alpha", "Alpha"), ("beta", "Beta"), ("gamma", "Gamma")],
        "clipboard" => &[("c:1", "hello world"), ("c:2", "second clip")],
        _ => &[],
    };
    rows.iter()
        .filter(|(_, t)| t.to_lowercase().contains(&query.to_lowercase()))
        .map(|(id, t)| item(id, t, query, mode == "clipboard"))
        .collect()
}

/// More rows than the panel shows. Each character of a query ranks nine new rows above all
/// the others, which stay: the way typing on brings better matches over the ones listed.
fn windows(query: &str) -> Vec<Value> {
    let n = query.chars().count();
    let top = (0..n * 9)
        .rev()
        .map(|i| item(&format!("t{i}"), &format!("Top {i}"), "", false));
    let rest = (0..30).map(|i| item(&format!("w{i}"), &format!("Window {i}"), "", false));
    top.chain(rest).collect()
}

/// The cursor's row is wholly on screen and the list starts at its first row.
fn at_top(st: &Value, cursor: &str) -> bool {
    st["cursor"] == cursor && st["top"] == 0 && st["cursorVisible"] == true
}

fn results(seq: u64, mode: &str, query: &str, items: Vec<Value>) -> Value {
    json!({
        "type": "results", "seq": seq, "mode": mode, "query": query,
        "total": items.len(), "status": null, "items": items,
    })
}

fn send(state: &mut State, event: &Value) {
    if let Some(w) = state.writer.as_mut() {
        let _ = writeln!(w, "{event}");
    }
}

fn answer(state: &mut State, req: &Value) {
    match req["op"].as_str().unwrap_or("") {
        "open" => {
            state.mode = req["mode"].as_str().unwrap().into();
            state.query.clear();
            state.seq = 0;
            let ev = results(0, &state.mode, "", items(&state.mode, ""));
            send(state, &ev);
        }
        "query" => {
            state.query = req["text"].as_str().unwrap().into();
            state.seq = req["seq"].as_u64().unwrap();
            let ev = results(
                state.seq,
                &state.mode,
                &state.query,
                items(&state.mode, &state.query),
            );
            send(state, &ev);
            // A late answer to the previous query, which the panel must drop.
            if state.seq > 1 {
                let stale = vec![item("stale", "Stale", "", false)];
                let ev = results(state.seq - 1, &state.mode.clone(), "", stale);
                send(state, &ev);
            }
        }
        "preview" => {
            let id = req["id"].as_str().unwrap();
            let ev = json!({ "type": "preview", "id": id,
                "preview": { "kind": "text", "text": format!("preview of {id}"), "mono": true } });
            send(state, &ev);
        }
        "activate" => {
            let ev = match &state.work {
                Some(text) => json!({ "type": "working", "text": text }),
                None => json!({ "type": "done", "close": !state.stay }),
            };
            send(state, &ev);
        }
        _ => {}
    }
}

impl Stub {
    fn start(s: &Session) -> Self {
        Self::listen(s.path("run/launcher.sock"), Arc::default())
    }

    fn listen(path: PathBuf, state: Arc<Mutex<State>>) -> Self {
        let _ = std::fs::remove_file(&path);
        let listener = UnixListener::bind(&path).unwrap();
        listener.set_nonblocking(true).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let thread = {
            let (state, stop) = (state.clone(), stop.clone());
            std::thread::spawn(move || {
                while !stop.load(Ordering::Relaxed) {
                    let Ok((stream, _)) = listener.accept() else {
                        std::thread::sleep(Duration::from_millis(20));
                        continue;
                    };
                    stream.set_nonblocking(false).unwrap();
                    {
                        let mut st = state.lock().unwrap();
                        st.writer = Some(stream.try_clone().unwrap());
                        let hello = json!({ "type": "hello", "modes": [
                            { "mode": "apps", "short": "a", "title": "Apps", "glyph": "apps" },
                            { "mode": "clipboard", "short": "c", "title": "Clipboard", "glyph": "clipboard" },
                            { "mode": "windows", "short": "w", "title": "Windows", "glyph": "windows" },
                        ]});
                        send(&mut st, &hello);
                    }
                    let state = state.clone();
                    std::thread::spawn(move || {
                        for line in BufReader::new(stream).lines() {
                            let Ok(line) = line else { break };
                            let req: Value = serde_json::from_str(&line).unwrap();
                            let mut st = state.lock().unwrap();
                            st.requests.push(req.clone());
                            if st.hold && req["op"] == "query" {
                                st.held.push(req);
                            } else {
                                answer(&mut st, &req);
                            }
                        }
                    });
                }
            })
        };
        Stub {
            path,
            state,
            stop,
            thread: Some(thread),
        }
    }

    fn shutdown(&mut self) {
        // Once only: the old stub a restart replaced must leave the new socket alone.
        let Some(thread) = self.thread.take() else {
            return;
        };
        self.stop.store(true, Ordering::Relaxed);
        thread.join().unwrap();
        if let Some(w) = self.state.lock().unwrap().writer.take() {
            let _ = w.shutdown(std::net::Shutdown::Both);
        }
        let _ = std::fs::remove_file(&self.path);
    }

    /// The daemon going away and coming back on the same socket.
    fn restart(mut self) -> Self {
        self.shutdown();
        std::thread::sleep(Duration::from_millis(300));
        Self::listen(self.path.clone(), self.state.clone())
    }

    fn requests(&self) -> Vec<Value> {
        self.state.lock().unwrap().requests.clone()
    }

    fn ops(&self, op: &str) -> Vec<Value> {
        self.requests()
            .into_iter()
            .filter(|r| r["op"] == op)
            .collect()
    }

    fn stay(&self) {
        self.state.lock().unwrap().stay = true;
    }

    fn hold(&self) {
        self.state.lock().unwrap().hold = true;
    }

    /// Answers the queries held so far, and the next ones at once.
    fn release(&self) {
        let mut st = self.state.lock().unwrap();
        st.hold = false;
        for req in std::mem::take(&mut st.held) {
            answer(&mut st, &req);
        }
    }

    fn work(&self, text: &str) {
        self.state.lock().unwrap().work = Some(text.into());
    }

    /// Ends the work of the last activation: `done`, or its error.
    fn finish(&self, error: Option<&str>) {
        let mut st = self.state.lock().unwrap();
        let ev = match error {
            Some(message) => json!({ "type": "error", "message": message }),
            None => json!({ "type": "done", "close": true }),
        };
        send(&mut st, &ev);
    }

    /// Results sent unprompted, with the last seq, as when a source's entries change.
    fn resend(&self, rows: &[(&str, &str)]) {
        let mut st = self.state.lock().unwrap();
        let items = rows.iter().map(|(id, t)| item(id, t, "", false)).collect();
        let ev = results(st.seq, &st.mode.clone(), &st.query.clone(), items);
        send(&mut st, &ev);
    }

    fn wait_for(&self, s: &Session, what: &str, pred: impl Fn(&[Value]) -> bool) {
        s.wait_until(what, || pred(&self.requests()));
    }
}

impl Drop for Stub {
    fn drop(&mut self) {
        self.shutdown();
    }
}

/// The harness waits for the reviews pill: one review asked of me shows it.
fn reviews() -> Value {
    let pr = json!({
        "kind": "pr", "place": "alone", "number": 1, "title": "t", "repo": "app",
        "url": "https://github.com/acme/app/pull/1", "branch": "b", "state": "Open",
        "draft": false, "updated_at": 1_700_000_000, "listed": true, "additions": 1,
        "deletions": 1, "author": "a", "avatar": null, "decision": null, "checks": "Success"
    });
    let tab =
        |rows: Vec<Value>| json!({ "count": rows.len(), "stale": 0, "rows": rows, "all": rows });
    json!({
        "snapshot": "", "fetched_at": 1_700_000_000,
        "requested": tab(vec![pr]), "reviewed": tab(vec![]), "mine": tab(vec![]),
    })
}

fn start() -> Option<(Session, Stub)> {
    let s = Session::start(&reviews())?;
    let stub = Stub::start(&s);
    Some((s, stub))
}

fn ids(st: &Value) -> Vec<String> {
    st["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["id"].as_str().unwrap().to_owned())
        .collect()
}

/// Opens the launcher in `mode` and waits for its rows and keyboard focus.
fn open(s: &Session, mode: &str) -> Value {
    s.wait_for_launcher("the daemon's hello", |st| {
        st["connected"] == true && !st["modes"].as_array().unwrap().is_empty()
    });
    s.ipc_args("launcher", "open", &[mode]);
    s.wait_for_launcher("the launcher to open", |st| {
        st["open"] == true && st["focused"] == true && st["mode"] == mode && !ids(st).is_empty()
    })
}

fn ctrl(s: &Session, key: &str) {
    s.wtype(&["-M", "ctrl", "-k", key, "-m", "ctrl"]);
}

#[test]
fn opening_sends_open_and_shows_the_rows() {
    let Some((s, stub)) = start() else { return };
    let st = open(&s, "apps");
    assert_eq!(ids(&st), ["alpha", "beta", "gamma"]);
    assert_eq!(st["cursor"], "alpha");
    assert_eq!(stub.ops("open"), [json!({"op": "open", "mode": "apps"})]);
}

#[test]
fn typing_sends_queries_with_increasing_seqs_and_drops_stale_results() {
    let Some((s, stub)) = start() else { return };
    open(&s, "apps");
    s.wtype(&["al"]);
    s.wait_for_launcher("the query", |st| {
        st["query"] == "al" && ids(st) == ["alpha"]
    });
    stub.wait_for(&s, "both queries", |r| {
        r.iter().filter(|r| r["op"] == "query").count() == 2
    });
    let queries = stub.ops("query");
    assert_eq!(queries[0], json!({"op": "query", "text": "a", "seq": 1}));
    assert_eq!(queries[1], json!({"op": "query", "text": "al", "seq": 2}));
    // The stub answered seq 1 again after seq 2.
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(ids(&s.launcher()), ["alpha"]);
}

#[test]
fn the_loading_bar_shows_once_an_answer_is_late_and_goes_with_it() {
    let Some((s, stub)) = start() else { return };
    let st = open(&s, "apps");
    // Answered within milliseconds: no bar.
    assert_eq!(st["loading"], false);
    stub.hold();
    s.wtype(&["b"]);
    stub.wait_for(&s, "the held query", |r| {
        r.iter().any(|r| r["op"] == "query")
    });
    s.wait_for_launcher("the loading bar", |st| st["loading"] == true);
    stub.release();
    s.wait_for_launcher("the answer, and no bar", |st| {
        st["loading"] == false && ids(st) == ["beta"]
    });
}

#[test]
fn ctrl_n_and_ctrl_p_move_the_cursor_and_wrap() {
    let Some((s, _stub)) = start() else { return };
    open(&s, "apps");
    for want in ["beta", "gamma", "alpha"] {
        ctrl(&s, "n");
        s.wait_for_launcher(want, |st| st["cursor"] == want);
    }
    ctrl(&s, "p");
    s.wait_for_launcher("the wrap back", |st| st["cursor"] == "gamma");
    s.key("Up");
    s.wait_for_launcher("Up", |st| st["cursor"] == "beta");
}

#[test]
fn enter_alt_enter_and_ctrl_enter_run_their_actions() {
    let Some((s, stub)) = start() else { return };
    stub.stay();
    open(&s, "apps");
    ctrl(&s, "n");
    s.wait_for_launcher("the cursor on beta", |st| st["cursor"] == "beta");
    s.key("Return");
    s.wtype(&["-M", "alt", "-k", "Return", "-m", "alt"]);
    ctrl(&s, "Return");
    stub.wait_for(&s, "three activations", |r| {
        r.iter().filter(|r| r["op"] == "activate").count() == 3
    });
    let ids: Vec<_> = ["open", "new-window", "terminal"]
        .iter()
        .map(|a| json!({"op": "activate", "id": "beta", "action": a}))
        .collect();
    assert_eq!(stub.ops("activate"), ids);
    assert_eq!(s.launcher()["open"], true);
}

#[test]
fn done_with_close_hides_the_panel() {
    let Some((s, stub)) = start() else { return };
    open(&s, "apps");
    s.key("Return");
    s.wait_for_launcher("the panel to close", |st| st["open"] == false);
    stub.wait_for(&s, "close", |r| r.iter().any(|r| r["op"] == "close"));
}

#[test]
fn slow_work_keeps_the_panel_until_it_ends_and_takes_no_key_but_escape() {
    let Some((s, stub)) = start() else { return };
    stub.work("Copying the password…");
    open(&s, "apps");
    s.key("Return");
    s.wait_for_launcher("the work shown", |st| {
        st["open"] == true && st["statusLine"] == "Copying the password…" && st["loading"] == true
    });
    stub.finish(None);
    s.wait_for_launcher("the panel to close", |st| st["open"] == false);

    // Failed: the panel stays, says why, and takes keys again.
    open(&s, "apps");
    s.key("Return");
    s.wait_for_launcher("the work shown", |st| {
        st["statusLine"] == "Copying the password…"
    });
    stub.finish(Some("Copying the password failed: nope"));
    s.wait_for_launcher("the error", |st| {
        st["open"] == true && st["statusLine"] == "Copying the password failed: nope"
    });
    s.wtype(&["a"]);
    s.wait_for_launcher("the query", |st| st["query"] == "a");

    // Meanwhile only Escape counts. Keys are taken in order, so once it closed the panel, the
    // typing and the Enter before it had been dropped.
    s.key("Return");
    s.wait_for_launcher("the work shown", |st| {
        st["statusLine"] == "Copying the password…"
    });
    let queries = stub.ops("query").len();
    s.wtype(&["b"]);
    s.key("Return");
    s.key("Escape");
    s.wait_for_launcher("the panel to close", |st| st["open"] == false);
    assert_eq!(stub.ops("query").len(), queries);
    assert_eq!(stub.ops("activate").len(), 3);
}

#[test]
fn escape_clears_the_query_then_closes() {
    let Some((s, stub)) = start() else { return };
    open(&s, "apps");
    s.wtype(&["be"]);
    s.wait_for_launcher("the query", |st| st["query"] == "be");
    s.key("Escape");
    let st = s.wait_for_launcher("the query to clear", |st| st["query"] == "");
    assert_eq!(st["open"], true);
    assert_eq!(ids(&st), ["alpha", "beta", "gamma"]);
    s.key("Escape");
    s.wait_for_launcher("the panel to close", |st| st["open"] == false);
    stub.wait_for(&s, "close", |r| r.iter().any(|r| r["op"] == "close"));
}

#[test]
fn slash_short_and_space_switches_mode() {
    let Some((s, stub)) = start() else { return };
    open(&s, "apps");
    s.wtype(&["/c "]);
    let st = s.wait_for_launcher("the clipboard mode", |st| {
        st["mode"] == "clipboard" && ids(st) == ["c:1", "c:2"]
    });
    assert_eq!(st["query"], "");
    assert_eq!(
        stub.ops("open").last().unwrap(),
        &json!({"op": "open", "mode": "clipboard"})
    );
}

#[test]
fn ctrl_k_lists_the_actions_and_runs_the_one_picked() {
    let Some((s, stub)) = start() else { return };
    stub.stay();
    open(&s, "apps");
    ctrl(&s, "k");
    let st = s.wait_for_launcher("the actions menu", |st| st["menu"] == true);
    assert_eq!(
        st["menuActions"],
        json!(["open", "new-window", "terminal", "copy-path"])
    );
    s.wtype(&["path"]);
    s.wait_for_launcher("the filtered menu", |st| {
        st["menuActions"] == json!(["copy-path"])
    });
    s.key("Return");
    stub.wait_for(&s, "the activation", |r| {
        r.iter().any(|r| r["op"] == "activate")
    });
    assert_eq!(
        stub.ops("activate"),
        [json!({"op": "activate", "id": "alpha", "action": "copy-path"})]
    );
    assert_eq!(s.launcher()["menu"], false);
}

#[test]
fn the_cursor_stays_on_its_item_across_unprompted_results() {
    let Some((s, stub)) = start() else { return };
    open(&s, "apps");
    ctrl(&s, "n");
    s.wait_for_launcher("the cursor on beta", |st| st["cursor"] == "beta");
    stub.resend(&[
        ("new", "New"),
        ("alpha", "Alpha"),
        ("beta", "Beta"),
        ("gamma", "Gamma"),
    ]);
    let st = s.wait_for_launcher("the new row", |st| ids(st).len() == 4);
    assert_eq!(st["cursor"], "beta");
    stub.resend(&[("alpha", "Alpha"), ("gamma", "Gamma")]);
    let st = s.wait_for_launcher("beta gone", |st| ids(st).len() == 2);
    assert_eq!(st["cursor"], "alpha");
}

#[test]
fn the_cursor_stays_on_the_first_row_until_moved_and_typing_brings_it_back() {
    let Some((s, stub)) = start() else { return };
    let st = open(&s, "apps");
    assert_eq!(st["cursor"], "alpha");
    // Not moved: the cursor follows the first row, as when typing reranks the rows.
    stub.resend(&[("new", "New"), ("alpha", "Alpha"), ("beta", "Beta")]);
    let st = s.wait_for_launcher("the new first row", |st| ids(st).len() == 3);
    assert_eq!(st["cursor"], "new");
    ctrl(&s, "n");
    s.wait_for_launcher("the cursor on alpha", |st| st["cursor"] == "alpha");
    // Typing ends the hand selection, though alpha is still listed.
    s.wtype(&["a"]);
    let st = s.wait_for_launcher("the query's rows", |st| {
        st["query"] == "a" && ids(st) == ["alpha", "beta", "gamma"]
    });
    assert_eq!(st["cursor"], "alpha");
    ctrl(&s, "n");
    s.wait_for_launcher("the cursor on beta", |st| st["cursor"] == "beta");
    s.wtype(&["m"]);
    let st = s.wait_for_launcher("the narrowed rows", |st| {
        st["query"] == "am" && ids(st) == ["gamma"]
    });
    assert_eq!(st["cursor"], "gamma");
    s.key("BackSpace");
    let st = s.wait_for_launcher("the rows again", |st| {
        st["query"] == "a" && ids(st) == ["alpha", "beta", "gamma"]
    });
    assert_eq!(st["cursor"], "alpha");
}

#[test]
fn the_first_rows_and_the_cursor_stay_in_view_as_matches_change() {
    let Some((s, _stub)) = start() else { return };
    open(&s, "windows");
    s.wait_for_launcher("the first row in view", |st| at_top(st, "w0"));
    // Each character ranks new rows above the listed ones: the list shows them, not the
    // rows that were on screen.
    for (query, first) in [("x", "t8"), ("xy", "t17")] {
        s.wtype(&[&query[query.len() - 1..]]);
        s.wait_for_launcher("the new first row in view", |st| {
            st["query"] == query && at_top(st, first)
        });
    }
    // Walking down scrolls with the cursor.
    for _ in 0..12 {
        ctrl(&s, "n");
    }
    s.wait_for_launcher("the cursor in view below", |st| {
        st["cursor"] == "t5" && st["cursorVisible"] == true && st["top"] != 0
    });
    // Scrolled down, typing brings the list back to its first row.
    s.wtype(&["z"]);
    s.wait_for_launcher("the first row in view again", |st| {
        st["query"] == "xyz" && at_top(st, "t26")
    });
}

#[test]
fn a_preview_is_asked_for_once_the_cursor_rests() {
    let Some((s, stub)) = start() else { return };
    open(&s, "clipboard");
    s.wait_for_launcher("the preview", |st| st["preview"] == "text");
    ctrl(&s, "n");
    s.wait_for_launcher("c:2", |st| st["cursor"] == "c:2" && st["preview"] == "text");
    ctrl(&s, "p");
    s.wait_for_launcher("c:1", |st| st["cursor"] == "c:1" && st["preview"] == "text");
    // c:1 came from the cache.
    assert_eq!(
        stub.ops("preview"),
        [
            json!({"op": "preview", "id": "c:1"}),
            json!({"op": "preview", "id": "c:2"})
        ]
    );
}

#[test]
fn the_panel_reconnects_when_the_daemon_restarts() {
    let Some((s, stub)) = start() else { return };
    open(&s, "apps");
    s.wtype(&["ga"]);
    s.wait_for_launcher("the query", |st| ids(st) == ["gamma"]);
    let stub = stub.restart();
    stub.wait_for(&s, "the panel to open again", |r| {
        r.iter().filter(|r| r["op"] == "open").count() == 2
    });
    let st = s.wait_for_launcher("the rows again", |st| {
        st["connected"] == true && ids(st) == ["gamma"]
    });
    assert_eq!(st["query"], "ga");
    let requests = stub.requests();
    let reopened = requests.iter().rposition(|r| r["op"] == "open").unwrap();
    assert_eq!(
        requests[reopened + 1],
        json!({"op": "query", "text": "ga", "seq": 1})
    );
}
