//! The actor at the centre: it owns the sources and the panels connected to the socket, and
//! answers each request on one thread, so sources need no locking against the engine.

use std::collections::{BTreeMap, HashMap};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::Arc;

use crate::matcher::{self, Prepared};
use crate::protocol::{Event, Item, ModeInfo, Request};
use crate::source::{Action, Ctx, Entry, Icon, Mode, Outcome, Source};

/// The most rows a `results` carries.
pub const LIMIT: usize = 100;

pub type ClientId = u64;

pub enum Msg {
    Connected(ClientId, Sender<Event>),
    Request(ClientId, Request),
    Gone(ClientId),
    Updated(Mode),
    /// The work of an `Outcome::Wait` ended.
    Finished {
        client: ClientId,
        wait: u64,
        result: Result<(), String>,
    },
}

/// How sources and their threads tell the engine their entries changed.
#[derive(Clone)]
pub struct Updater(Sender<Msg>);

impl Updater {
    pub fn updated(&self, mode: Mode) {
        // The engine is gone only while the daemon exits.
        let _ = self.0.send(Msg::Updated(mode));
    }

    fn finished(&self, client: ClientId, wait: u64, result: Result<(), String>) {
        let _ = self.0.send(Msg::Finished {
            client,
            wait,
            result,
        });
    }
}

/// The engine's inbox: the server sends panel messages to it, sources their updates.
pub fn channel() -> (Sender<Msg>, Updater, Receiver<Msg>) {
    let (tx, rx) = mpsc::channel();
    (tx.clone(), Updater(tx), rx)
}

struct Client {
    tx: Sender<Event>,
    mode: Option<Mode>,
    query: String,
    seq: u64,
    /// The `Outcome::Wait` the panel waits for, until it closes or opens a mode.
    waiting: Option<u64>,
}

pub struct Engine {
    ctx: Ctx,
    sources: BTreeMap<Mode, Box<dyn Source>>,
    prepared: HashMap<Mode, Prepared>,
    clients: HashMap<ClientId, Client>,
    waits: u64,
}

impl Engine {
    pub fn new(ctx: Ctx, sources: Vec<Box<dyn Source>>) -> Engine {
        Engine {
            ctx,
            sources: sources.into_iter().map(|s| (s.mode(), s)).collect(),
            prepared: HashMap::new(),
            clients: HashMap::new(),
            waits: 0,
        }
    }

    pub fn modes(&self) -> Vec<Mode> {
        self.sources.keys().copied().collect()
    }

    /// Answers messages until every sender is gone.
    pub fn run(mut self, rx: Receiver<Msg>) {
        while let Ok(msg) = rx.recv() {
            self.handle(msg);
        }
    }

    pub fn handle(&mut self, msg: Msg) {
        match msg {
            Msg::Connected(id, tx) => {
                let modes = self.modes().into_iter().map(ModeInfo::from).collect();
                let _ = tx.send(Event::Hello { modes });
                self.clients.insert(
                    id,
                    Client {
                        tx,
                        mode: None,
                        query: String::new(),
                        seq: 0,
                        waiting: None,
                    },
                );
            }
            Msg::Gone(id) => {
                if let Some(client) = self.clients.remove(&id) {
                    if let Some(mode) = client.mode {
                        self.left(mode);
                    }
                }
            }
            Msg::Updated(mode) => {
                let ids: Vec<ClientId> = self
                    .clients
                    .iter()
                    .filter(|(_, c)| c.mode == Some(mode))
                    .map(|(id, _)| *id)
                    .collect();
                for id in ids {
                    self.send_results(id);
                }
            }
            Msg::Request(id, request) => self.request(id, request),
            Msg::Finished {
                client,
                wait,
                result,
            } => {
                let waited = match self.clients.get_mut(&client) {
                    Some(c) if c.waiting == Some(wait) => {
                        c.waiting = None;
                        true
                    }
                    _ => false,
                };
                match result {
                    Ok(()) if waited => self.send(client, Event::Done { close: true }),
                    Err(message) if waited => self.error(client, message),
                    // The panel left before the work ended.
                    Err(message) => self.ctx.notify("Launcher", &message),
                    Ok(()) => {}
                }
            }
        }
    }

    fn send(&self, id: ClientId, event: Event) {
        if let Some(client) = self.clients.get(&id) {
            let _ = client.tx.send(event);
        }
    }

    fn error(&self, id: ClientId, message: impl Into<String>) {
        self.send(
            id,
            Event::Error {
                message: message.into(),
            },
        );
    }

    /// A panel left `mode`: the source closes once no panel is on it.
    fn left(&mut self, mode: Mode) {
        if self.clients.values().any(|c| c.mode == Some(mode)) {
            return;
        }
        if let Some(source) = self.sources.get_mut(&mode) {
            source.close(&self.ctx);
        }
        // Big vectors (files) are not kept for nothing.
        self.prepared.remove(&mode);
    }

    fn request(&mut self, id: ClientId, request: Request) {
        if !self.clients.contains_key(&id) {
            return;
        }
        match request {
            Request::Open { mode } => {
                if !self.sources.contains_key(&mode) {
                    return self.error(id, format!("{} is not enabled", mode.name()));
                }
                let client = self.clients.get_mut(&id).unwrap();
                let previous = client.mode.replace(mode);
                client.query.clear();
                client.seq = 0;
                client.waiting = None;
                if let Some(previous) = previous.filter(|p| *p != mode) {
                    self.left(previous);
                }
                self.sources.get_mut(&mode).unwrap().open(&self.ctx);
                self.send_results(id);
            }
            Request::Query { text, seq } => {
                let client = self.clients.get_mut(&id).unwrap();
                if client.mode.is_none() {
                    return self.error(id, "no mode is open");
                }
                client.query = text;
                client.seq = seq;
                self.send_results(id);
            }
            Request::Activate { id: entry, action } => self.activate(id, &entry, action),
            Request::Preview { id: entry } => {
                let Some(mode) = self.clients[&id].mode else {
                    return self.error(id, "no mode is open");
                };
                let preview = self.sources[&mode].preview(&entry, &self.ctx);
                self.send(id, Event::Preview { id: entry, preview });
            }
            Request::Close => {
                let client = self.clients.get_mut(&id).unwrap();
                client.query.clear();
                client.waiting = None;
                if let Some(mode) = client.mode.take() {
                    self.left(mode);
                }
            }
        }
    }

    fn activate(&mut self, id: ClientId, entry: &str, action: Option<String>) {
        let client = &self.clients[&id];
        let Some(mode) = client.mode else {
            return self.error(id, "no mode is open");
        };
        if let Some(name) = entry.strip_prefix("mode:") {
            return match Mode::from_token(name).filter(|m| self.sources.contains_key(m)) {
                Some(mode) => self.send(id, Event::Switch { mode }),
                None => self.error(id, format!("no mode {name}")),
            };
        }
        let query = client.query.clone();
        let source = self.sources.get_mut(&mode).unwrap();
        let entries = source.entries();
        let found = entries
            .iter()
            .find(|e| e.id == entry)
            .cloned()
            .or_else(|| source.extra(&query).into_iter().find(|e| e.id == entry));
        let Some(found) = found else {
            return self.error(id, "that entry is gone");
        };
        let action = match action {
            Some(action) if found.actions.iter().any(|a| a.id == action) => action,
            Some(action) => return self.error(id, format!("no action {action}")),
            None => match found.actions.first() {
                Some(first) => first.id.clone(),
                None => return self.error(id, "nothing to do"),
            },
        };
        let outcome = source.activate(entry, &action, &self.ctx);
        if source.frecency()
            && matches!(
                outcome,
                Outcome::Close | Outcome::Stay | Outcome::Wait { .. }
            )
        {
            self.ctx.frecency.bump(mode, entry);
        }
        match outcome {
            Outcome::Close => self.send(id, Event::Done { close: true }),
            Outcome::Stay => {
                self.send(id, Event::Done { close: false });
                self.send_results(id);
            }
            Outcome::Switch(mode) => self.send(id, Event::Switch { mode }),
            Outcome::Error(message) => self.error(id, message),
            Outcome::Wait { status, work } => {
                self.waits += 1;
                let wait = self.waits;
                self.clients.get_mut(&id).unwrap().waiting = Some(wait);
                self.send(id, Event::Working { text: status });
                let updater = self.ctx.updater();
                std::thread::spawn(move || updater.finished(id, wait, work.run()));
            }
        }
    }

    fn send_results(&mut self, id: ClientId) {
        let client = &self.clients[&id];
        let Some(mode) = client.mode else { return };
        let (query, seq) = (client.query.clone(), client.seq);
        let event = self.results(mode, &query, seq);
        self.send(id, event);
    }

    fn results(&mut self, mode: Mode, query: &str, seq: u64) -> Event {
        let source = &self.sources[&mode];
        let status = source.status();
        if let Some(rest) = query.strip_prefix('/') {
            let (items, total) = self.mode_rows(rest);
            return Event::Results {
                seq,
                mode,
                query: query.to_owned(),
                total,
                status: None,
                items,
            };
        }

        let entries = source.entries();
        let prepared = match self.prepared.remove(&mode) {
            Some(p) if p.is(&entries) => p,
            _ => Prepared::new(entries),
        };
        let frecency = self.ctx.frecency.clone();
        let use_frecency = source.frecency();
        let score = move |e: &Entry| {
            if use_frecency {
                frecency.score(mode, &e.id)
            } else {
                0.0
            }
        };
        let (ranked, mut total) = matcher::rank(&prepared, query, source.paths(), &score, LIMIT);
        let empty = query.trim().is_empty();
        let mut items: Vec<Item> = ranked
            .into_iter()
            .map(|r| {
                let e = &prepared.entries[r.index];
                item(e, r.hl, r.shl, empty)
            })
            .collect();
        let extra = source.extra(query);
        total += extra.len();
        items.extend(extra.iter().map(|e| item(e, Vec::new(), Vec::new(), empty)));
        self.prepared.insert(mode, prepared);
        Event::Results {
            seq,
            mode,
            query: query.to_owned(),
            total,
            status,
            items,
        }
    }

    /// The rows a `/` query lists: the enabled modes, filtered by what follows the slash.
    fn mode_rows(&self, rest: &str) -> (Vec<Item>, usize) {
        let actions: Arc<[Action]> =
            Arc::from(vec![Action::new("switch", "Switch", Some("Return"))]);
        let entries: Vec<Entry> = self
            .modes()
            .into_iter()
            .map(|m| {
                let mut e = Entry::new(format!("mode:{}", m.name()), m.title(), actions.clone());
                e.subtitle = format!("/{} · /{}", m.name(), m.short());
                e.keywords = format!("{} {}", m.name(), m.short());
                e.icon = Icon::Glyph(m.glyph().into());
                e
            })
            .collect();
        let prepared = Prepared::new(Arc::new(entries));
        let (ranked, total) = matcher::rank(&prepared, rest, false, &|_| 0.0, LIMIT);
        let items = ranked
            .into_iter()
            .map(|r| item(&prepared.entries[r.index], r.hl, r.shl, false))
            .collect();
        (items, total)
    }
}

fn item(e: &Entry, hl: Vec<[u32; 2]>, shl: Vec<[u32; 2]>, sections: bool) -> Item {
    Item {
        id: e.id.clone(),
        title: e.title.clone(),
        subtitle: e.subtitle.clone(),
        hl,
        shl,
        icon: e.icon.clone(),
        accessory: e.accessory.clone(),
        color: e.color.clone(),
        section: if sections {
            e.section.clone()
        } else {
            String::new()
        },
        actions: e.actions.clone(),
        preview: e.preview,
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::*;
    use crate::config::Config;
    use crate::source::{Preview, Status, Work};
    use crate::testing::Handles;

    /// A source over fixed entries that records what it is asked.
    struct Fixed {
        mode: Mode,
        entries: Arc<Vec<Entry>>,
        log: Arc<Mutex<Vec<String>>>,
        frecency: bool,
    }

    impl Source for Fixed {
        fn mode(&self) -> Mode {
            self.mode
        }
        fn open(&mut self, _: &Ctx) {
            self.log
                .lock()
                .unwrap()
                .push(format!("open {}", self.mode.name()));
        }
        fn close(&mut self, _: &Ctx) {
            self.log
                .lock()
                .unwrap()
                .push(format!("close {}", self.mode.name()));
        }
        fn entries(&self) -> Arc<Vec<Entry>> {
            self.entries.clone()
        }
        fn extra(&self, query: &str) -> Vec<Entry> {
            if query.is_empty() {
                return Vec::new();
            }
            vec![Entry::new(
                format!("new:{query}"),
                format!("New {query}"),
                actions(),
            )]
        }
        fn status(&self) -> Option<Status> {
            Some(Status::info("fixed"))
        }
        fn frecency(&self) -> bool {
            self.frecency
        }
        fn activate(&mut self, id: &str, action: &str, _: &Ctx) -> Outcome {
            self.log
                .lock()
                .unwrap()
                .push(format!("activate {id} {action}"));
            match action {
                "delete" => {
                    let kept: Vec<Entry> = self
                        .entries
                        .iter()
                        .filter(|e| e.id != id)
                        .cloned()
                        .collect();
                    self.entries = Arc::new(kept);
                    Outcome::Stay
                }
                "fail" => Outcome::Error("nope".into()),
                "wait" => {
                    let fails = id == "Files";
                    Outcome::Wait {
                        status: format!("Waiting for {id}"),
                        work: Work::new(move || {
                            if fails {
                                Err("Files failed".into())
                            } else {
                                Ok(())
                            }
                        }),
                    }
                }
                _ => Outcome::Close,
            }
        }
        fn preview(&self, id: &str, _: &Ctx) -> Option<Preview> {
            Some(Preview::Text {
                text: id.to_owned(),
                mono: false,
            })
        }
    }

    fn actions() -> Arc<[Action]> {
        Arc::from(vec![
            Action::new("open", "Open", Some("Return")),
            Action::new("delete", "Delete", Some("Shift+Delete")),
            Action::new("fail", "Fail", None),
            Action::new("wait", "Wait", None),
        ])
    }

    struct Rig {
        engine: Engine,
        rx: Receiver<Event>,
        log: Arc<Mutex<Vec<String>>>,
        handles: Handles,
        _dir: tempfile::TempDir,
    }

    fn rig(frecency: bool) -> Rig {
        let dir = tempfile::tempdir().unwrap();
        let (ctx, handles) =
            Ctx::testing(dir.path(), Config::with_modes(&[Mode::Apps, Mode::Emoji]));
        let log = Arc::new(Mutex::new(Vec::new()));
        let make = |mode, titles: &[&str]| -> Box<dyn Source> {
            Box::new(Fixed {
                mode,
                entries: Arc::new(
                    titles
                        .iter()
                        .map(|t| Entry::new(*t, *t, actions()))
                        .collect(),
                ),
                log: log.clone(),
                frecency,
            })
        };
        let mut engine = Engine::new(
            ctx,
            vec![
                make(Mode::Apps, &["Firefox", "Files", "Kitty"]),
                make(Mode::Emoji, &["grinning"]),
            ],
        );
        let (tx, rx) = mpsc::channel();
        engine.handle(Msg::Connected(1, tx));
        Rig {
            engine,
            rx,
            log,
            handles,
            _dir: dir,
        }
    }

    impl Rig {
        fn ask(&mut self, request: Request) {
            self.engine.handle(Msg::Request(1, request));
        }
        fn next(&self) -> Event {
            self.rx.try_recv().expect("an event")
        }
        fn titles(&self) -> Vec<String> {
            match self.next() {
                Event::Results { items, .. } => items.into_iter().map(|i| i.title).collect(),
                other => panic!("expected results, got {other:?}"),
            }
        }
        /// Hands the engine the end of the work its last `Outcome::Wait` started.
        fn finish(&mut self) {
            let msg = self
                .handles
                .wait_finished(std::time::Duration::from_secs(10))
                .expect("the work to end");
            self.engine.handle(msg);
        }
    }

    #[test]
    fn hello_lists_the_enabled_modes() {
        let rig = rig(false);
        match rig.next() {
            Event::Hello { modes } => {
                assert_eq!(
                    modes.iter().map(|m| m.mode).collect::<Vec<_>>(),
                    [Mode::Apps, Mode::Emoji]
                );
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn open_query_and_results() {
        let mut rig = rig(false);
        rig.next();
        rig.ask(Request::Open { mode: Mode::Apps });
        assert_eq!(rig.titles(), ["Firefox", "Files", "Kitty"]);
        rig.ask(Request::Query {
            text: "fi".into(),
            seq: 7,
        });
        match rig.next() {
            Event::Results {
                seq,
                total,
                items,
                status,
                ..
            } => {
                assert_eq!(seq, 7);
                assert_eq!(total, 3);
                assert_eq!(items[2].title, "New fi");
                assert_eq!(status, Some(Status::info("fixed")));
            }
            other => panic!("{other:?}"),
        }
        assert_eq!(*rig.log.lock().unwrap(), ["open apps"]);
    }

    #[test]
    fn switching_modes_closes_the_one_left() {
        let mut rig = rig(false);
        rig.next();
        rig.ask(Request::Open { mode: Mode::Apps });
        rig.ask(Request::Open { mode: Mode::Emoji });
        rig.ask(Request::Close);
        assert_eq!(
            *rig.log.lock().unwrap(),
            ["open apps", "close apps", "open emoji", "close emoji"]
        );
    }

    #[test]
    fn activation_outcomes() {
        let mut rig = rig(false);
        rig.next();
        rig.ask(Request::Open { mode: Mode::Apps });
        rig.next();
        rig.ask(Request::Activate {
            id: "Kitty".into(),
            action: None,
        });
        assert_eq!(rig.next(), Event::Done { close: true });
        rig.ask(Request::Activate {
            id: "Files".into(),
            action: Some("delete".into()),
        });
        assert_eq!(rig.next(), Event::Done { close: false });
        assert_eq!(rig.titles(), ["Firefox", "Kitty"]);
        rig.ask(Request::Activate {
            id: "Firefox".into(),
            action: Some("fail".into()),
        });
        assert_eq!(
            rig.next(),
            Event::Error {
                message: "nope".into()
            }
        );
        rig.ask(Request::Activate {
            id: "Firefox".into(),
            action: Some("bogus".into()),
        });
        assert!(matches!(rig.next(), Event::Error { .. }));
        rig.ask(Request::Activate {
            id: "Files".into(),
            action: None,
        });
        assert_eq!(
            rig.next(),
            Event::Error {
                message: "that entry is gone".into()
            }
        );
    }

    #[test]
    fn the_panel_waits_for_slow_work_and_hears_its_end_only_while_still_open() {
        let mut rig = rig(false);
        rig.next();
        rig.ask(Request::Open { mode: Mode::Apps });
        rig.next();
        let wait = |id: &str| Request::Activate {
            id: id.into(),
            action: Some("wait".into()),
        };
        rig.ask(wait("Kitty"));
        assert_eq!(
            rig.next(),
            Event::Working {
                text: "Waiting for Kitty".into()
            }
        );
        rig.finish();
        assert_eq!(rig.next(), Event::Done { close: true });

        rig.ask(wait("Files"));
        rig.next();
        rig.finish();
        assert_eq!(
            rig.next(),
            Event::Error {
                message: "Files failed".into()
            }
        );

        // Closed and opened again meanwhile: the work's end would close the new panel.
        rig.ask(wait("Kitty"));
        rig.next();
        rig.ask(Request::Close);
        rig.ask(Request::Open { mode: Mode::Apps });
        rig.next();
        rig.finish();
        assert!(rig.rx.try_recv().is_err());
    }

    #[test]
    fn extra_rows_can_be_activated() {
        let mut rig = rig(false);
        rig.next();
        rig.ask(Request::Open { mode: Mode::Apps });
        rig.next();
        rig.ask(Request::Query {
            text: "zzz".into(),
            seq: 1,
        });
        rig.next();
        rig.ask(Request::Activate {
            id: "new:zzz".into(),
            action: None,
        });
        assert_eq!(rig.next(), Event::Done { close: true });
        assert!(rig
            .log
            .lock()
            .unwrap()
            .contains(&"activate new:zzz open".to_string()));
    }

    #[test]
    fn a_slash_lists_modes_and_picking_one_switches() {
        let mut rig = rig(false);
        rig.next();
        rig.ask(Request::Open { mode: Mode::Apps });
        rig.next();
        rig.ask(Request::Query {
            text: "/e".into(),
            seq: 2,
        });
        assert_eq!(rig.titles(), ["Emoji"]);
        rig.ask(Request::Activate {
            id: "mode:emoji".into(),
            action: None,
        });
        assert_eq!(rig.next(), Event::Switch { mode: Mode::Emoji });
    }

    #[test]
    fn frecency_reorders_after_picks() {
        let mut rig = rig(true);
        rig.next();
        rig.ask(Request::Open { mode: Mode::Apps });
        rig.next();
        rig.ask(Request::Activate {
            id: "Kitty".into(),
            action: None,
        });
        rig.next();
        rig.ask(Request::Open { mode: Mode::Apps });
        assert_eq!(rig.titles(), ["Kitty", "Firefox", "Files"]);
    }

    #[test]
    fn updates_reach_the_panels_on_that_mode_only() {
        let mut rig = rig(false);
        rig.next();
        rig.ask(Request::Open { mode: Mode::Apps });
        rig.next();
        rig.engine.handle(Msg::Updated(Mode::Emoji));
        assert!(rig.rx.try_recv().is_err());
        rig.engine.handle(Msg::Updated(Mode::Apps));
        assert_eq!(rig.titles().len(), 3);
    }

    #[test]
    fn sections_are_only_sent_for_an_empty_query() {
        let dir = tempfile::tempdir().unwrap();
        let (ctx, _h) = Ctx::testing(dir.path(), Config::with_modes(&[Mode::Browser]));
        let mut e = Entry::new("t", "GitHub", actions());
        e.section = "Open tabs".into();
        let mut engine = Engine::new(
            ctx,
            vec![Box::new(Fixed {
                mode: Mode::Browser,
                entries: Arc::new(vec![e]),
                log: Arc::default(),
                frecency: false,
            })],
        );
        let (tx, rx) = mpsc::channel();
        engine.handle(Msg::Connected(1, tx));
        rx.recv().unwrap();
        engine.handle(Msg::Request(
            1,
            Request::Open {
                mode: Mode::Browser,
            },
        ));
        let section = |event| match event {
            Event::Results { items, .. } => items[0].section.clone(),
            other => panic!("{other:?}"),
        };
        assert_eq!(section(rx.recv().unwrap()), "Open tabs");
        engine.handle(Msg::Request(
            1,
            Request::Query {
                text: "git".into(),
                seq: 1,
            },
        ));
        assert_eq!(section(rx.recv().unwrap()), "");
    }
}
