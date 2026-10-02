//! What the omp extension (`ai/omp/extensions/omp-panel.ts`) publishes, and what
//! the panel makes of it.
//!
//! Each omp writes `<root>/<session>/<pane>.json`. The panel owns the
//! `<pane>.viewed` file next to it: the time the pane was last looked at, which is
//! what turns a finished turn from "done" back into "idle".

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

#[derive(Deserialize, Serialize, Clone, Copy, PartialEq, Eq, Debug)]
#[serde(rename_all = "lowercase")]
pub enum AgentState {
    Working,
    Idle,
    Blocked,
}

/// Ordered by urgency: a session shows the most urgent of its panes.
#[derive(Serialize, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    Idle,
    Done,
    Working,
    Blocked,
}

#[derive(Deserialize, Clone, Debug)]
pub struct PaneFile {
    pub pane_id: u32,
    pub pid: Option<u32>,
    pub state: AgentState,
    pub blocked_reason: Option<String>,
    pub last_message: Option<String>,
    pub session_file: Option<String>,
    pub cwd: String,
    pub updated_at: u64,
    pub finished_at: Option<u64>,
}

impl PaneFile {
    pub fn status(&self, viewed_at: Option<u64>) -> Status {
        match self.state {
            AgentState::Blocked => Status::Blocked,
            AgentState::Working => Status::Working,
            AgentState::Idle => match self.finished_at {
                Some(finished) if viewed_at.is_none_or(|viewed| viewed < finished) => Status::Done,
                _ => Status::Idle,
            },
        }
    }
}

/// A terminal pane as zellij reports it.
#[derive(Clone, Debug, Default)]
pub struct PaneInfo {
    pub tab_name: String,
    pub tab_position: u32,
}

/// The zellij side of a refresh: which sessions are up, their terminal panes, and
/// the panes a client is looking at right now.
#[derive(Default, Debug)]
pub struct Live {
    pub sessions: HashMap<String, LiveSession>,
}

#[derive(Default, Debug)]
pub struct LiveSession {
    pub panes: HashMap<u32, PaneInfo>,
    pub focused: HashSet<u32>,
}

#[derive(Serialize, Debug)]
pub struct Row {
    pub pane_id: u32,
    pub tab: String,
    #[serde(skip)]
    pub tab_position: u32,
    pub status: Status,
    pub blocked_reason: Option<String>,
    pub last_message: Option<String>,
    pub title: Option<String>,
    pub cwd: String,
    pub updated_at: u64,
}

#[derive(Serialize, Debug)]
pub struct Group {
    pub session: String,
    pub status: Status,
    pub panes: Vec<Row>,
}

pub struct Store {
    root: PathBuf,
}

impl Store {
    pub fn new(root: PathBuf) -> Self {
        Self { root }
    }

    /// Where the extension writes, which it resolves the same way.
    pub fn from_env() -> Self {
        let root = std::env::var_os("OMP_PANEL_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                let runtime = std::env::var_os("XDG_RUNTIME_DIR")
                    .map(PathBuf::from)
                    .unwrap_or_else(std::env::temp_dir);
                runtime.join("omp-panel")
            });
        Self::new(root)
    }

    fn pane_path(&self, session: &str, pane: u32, ext: &str) -> PathBuf {
        self.root.join(session).join(format!("{pane}.{ext}"))
    }

    pub fn viewed_at(&self, session: &str, pane: u32) -> Option<u64> {
        fs::read_to_string(self.pane_path(session, pane, "viewed"))
            .ok()?
            .trim()
            .parse()
            .ok()
    }

    pub fn mark_viewed(&self, session: &str, pane: u32, now: u64) -> std::io::Result<()> {
        let dir = self.root.join(session);
        fs::create_dir_all(&dir)?;
        fs::write(self.pane_path(session, pane, "viewed"), now.to_string())
    }

    fn forget(&self, session: &str, pane: u32) {
        for ext in ["json", "viewed"] {
            let _ = fs::remove_file(self.pane_path(session, pane, ext));
        }
    }

    /// Every pane file on disk, by session. Files that do not parse are skipped:
    /// the extension replaces them atomically, so one is never half-written.
    fn scan(&self) -> Vec<(String, PaneFile)> {
        let mut out = Vec::new();
        let Ok(sessions) = fs::read_dir(&self.root) else {
            return out;
        };
        for session in sessions.flatten() {
            let Some(name) = session.file_name().to_str().map(str::to_owned) else {
                continue;
            };
            let Ok(files) = fs::read_dir(session.path()) else {
                continue;
            };
            for file in files.flatten() {
                let path = file.path();
                if path.extension().is_some_and(|ext| ext == "json") {
                    if let Some(parsed) = read_pane(&path) {
                        out.push((name.clone(), parsed));
                    }
                }
            }
        }
        out
    }

    pub fn sessions(&self) -> Vec<String> {
        fs::read_dir(&self.root)
            .map(|dirs| {
                dirs.flatten()
                    .filter_map(|d| d.file_name().to_str().map(str::to_owned))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Build the panel's view, dropping every file whose omp is gone.
    ///
    /// A pane a client is focused on counts as viewed now, so a turn that finished
    /// while someone was watching it never shows as done.
    pub fn collect(&self, live: &Live, now: u64) -> Vec<Group> {
        let mut groups: HashMap<String, Vec<Row>> = HashMap::new();
        for (session, file) in self.scan() {
            let info = live
                .sessions
                .get(&session)
                .and_then(|s| s.panes.get(&file.pane_id));
            let alive = file.pid.is_none_or(pid_alive);
            let Some(info) = info.filter(|_| alive) else {
                self.forget(&session, file.pane_id);
                continue;
            };
            let focused = live.sessions[&session].focused.contains(&file.pane_id);
            let mut viewed_at = self.viewed_at(&session, file.pane_id);
            if focused && file.status(viewed_at) == Status::Done {
                let _ = self.mark_viewed(&session, file.pane_id, now);
                viewed_at = Some(now);
            }
            groups.entry(session).or_default().push(Row {
                pane_id: file.pane_id,
                tab: info.tab_name.clone(),
                tab_position: info.tab_position,
                status: file.status(viewed_at),
                blocked_reason: file.blocked_reason,
                last_message: file.last_message,
                title: file.session_file.as_deref().and_then(session_title),
                cwd: file.cwd,
                updated_at: file.updated_at,
            });
        }
        self.remove_dead_dirs(live);

        let mut out: Vec<Group> = groups
            .into_iter()
            .map(|(session, mut panes)| {
                panes.sort_by_key(|row| (row.tab_position, row.pane_id));
                let status = panes
                    .iter()
                    .map(|row| row.status)
                    .max()
                    .unwrap_or(Status::Idle);
                Group {
                    session,
                    status,
                    panes,
                }
            })
            .collect();
        // By name, not urgency: rows that reorder under the cursor get the wrong one
        // picked. The rollup is on the header instead.
        out.sort_by(|a, b| a.session.cmp(&b.session));
        out
    }

    /// Only sessions that are gone: a live one's omp may be about to write into
    /// the directory it just created.
    fn remove_dead_dirs(&self, live: &Live) {
        let Ok(sessions) = fs::read_dir(&self.root) else {
            return;
        };
        for session in sessions.flatten() {
            let is_live = session
                .file_name()
                .to_str()
                .is_some_and(|name| live.sessions.contains_key(name));
            if !is_live {
                let _ = fs::remove_dir_all(session.path());
            }
        }
    }
}

fn read_pane(path: &Path) -> Option<PaneFile> {
    serde_json::from_str(&fs::read_to_string(path).ok()?).ok()
}

/// The title omp keeps on the first line of a session file: a fixed-width
/// `{"type":"title",…}` slot rewritten in place on every rename, or on older
/// files the session header itself. A session is not on disk until its first
/// reply, and has no title before then either.
fn session_title(path: &str) -> Option<String> {
    use std::io::{BufRead, Read};
    let mut line = String::new();
    std::io::BufReader::new(fs::File::open(path).ok()?.take(64 * 1024))
        .read_line(&mut line)
        .ok()?;
    let first: serde_json::Value = serde_json::from_str(&line).ok()?;
    if !matches!(first["type"].as_str(), Some("title" | "session")) {
        return None;
    }
    let title = first["title"].as_str()?.trim();
    (!title.is_empty()).then(|| title.to_owned())
}

/// Without procfs (macOS) a pid cannot be checked, and the pane check has to do.
fn pid_alive(pid: u32) -> bool {
    let proc = Path::new("/proc");
    !proc.join("self").exists() || proc.join(pid.to_string()).exists()
}

pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(
        root: &Path,
        session: &str,
        pane: u32,
        state: &str,
        finished_at: Option<u64>,
        pid: u32,
    ) {
        let dir = root.join(session);
        fs::create_dir_all(&dir).unwrap();
        let body = serde_json::json!({
            "session": session,
            "pane_id": pane,
            "pid": pid,
            "state": state,
            "blocked_reason": null,
            "last_message": format!("msg {pane}"),
            "cwd": "/tmp",
            "updated_at": 1,
            "finished_at": finished_at,
        });
        fs::write(dir.join(format!("{pane}.json")), body.to_string()).unwrap();
    }

    fn live(sessions: &[(&str, &[u32])]) -> Live {
        Live {
            sessions: sessions
                .iter()
                .map(|(name, panes)| {
                    let panes = panes
                        .iter()
                        .map(|&id| {
                            let info = PaneInfo {
                                tab_name: format!("tab{id}"),
                                tab_position: id,
                            };
                            (id, info)
                        })
                        .collect();
                    (
                        name.to_string(),
                        LiveSession {
                            panes,
                            focused: HashSet::new(),
                        },
                    )
                })
                .collect(),
        }
    }

    fn dead_pid() -> u32 {
        let mut child = std::process::Command::new("true").spawn().unwrap();
        let pid = child.id();
        child.wait().unwrap();
        pid
    }

    #[test]
    fn a_finished_turn_is_done_until_viewed_after_it_finished() {
        let file = PaneFile {
            pane_id: 1,
            pid: None,
            state: AgentState::Idle,
            blocked_reason: None,
            last_message: None,
            session_file: None,
            cwd: String::new(),
            updated_at: 0,
            finished_at: Some(100),
        };
        assert_eq!(file.status(None), Status::Done);
        assert_eq!(
            file.status(Some(99)),
            Status::Done,
            "viewed before it finished"
        );
        assert_eq!(file.status(Some(100)), Status::Idle);
        let fresh = PaneFile {
            finished_at: None,
            ..file
        };
        assert_eq!(fresh.status(None), Status::Idle, "nothing has run yet");
    }

    #[test]
    fn a_session_rolls_up_its_most_urgent_pane() {
        let dir = tempfile::tempdir().unwrap();
        let me = std::process::id();
        write(dir.path(), "a", 1, "idle", None, me);
        write(dir.path(), "a", 2, "idle", Some(5), me);
        write(dir.path(), "b", 3, "working", None, me);
        write(dir.path(), "b", 4, "blocked", None, me);
        write(dir.path(), "b", 5, "idle", Some(5), me);
        write(dir.path(), "c", 6, "idle", None, me);
        let store = Store::new(dir.path().into());

        let groups = store.collect(&live(&[("a", &[1, 2]), ("b", &[3, 4, 5]), ("c", &[6])]), 10);
        let rollup: Vec<(&str, Status)> = groups
            .iter()
            .map(|g| (g.session.as_str(), g.status))
            .collect();
        assert_eq!(
            rollup,
            [
                ("a", Status::Done),
                ("b", Status::Blocked),
                ("c", Status::Idle)
            ]
        );

        store.mark_viewed("a", 2, 10).unwrap();
        let groups = store.collect(&live(&[("a", &[1, 2]), ("b", &[3, 4, 5]), ("c", &[6])]), 10);
        assert_eq!(
            groups[0].status,
            Status::Idle,
            "viewing the done pane clears it"
        );
    }

    #[test]
    fn a_focused_pane_is_viewed() {
        let dir = tempfile::tempdir().unwrap();
        write(dir.path(), "a", 1, "idle", Some(5), std::process::id());
        let store = Store::new(dir.path().into());
        let mut state = live(&[("a", &[1])]);
        state.sessions.get_mut("a").unwrap().focused.insert(1);

        assert_eq!(store.collect(&state, 10)[0].status, Status::Idle);
        state.sessions.get_mut("a").unwrap().focused.clear();
        assert_eq!(
            store.collect(&state, 11)[0].status,
            Status::Idle,
            "and stays viewed"
        );
    }

    #[test]
    fn files_whose_omp_is_gone_are_pruned() {
        let dir = tempfile::tempdir().unwrap();
        let me = std::process::id();
        write(dir.path(), "a", 1, "working", None, me);
        write(dir.path(), "a", 2, "working", None, me); // pane closed
        write(dir.path(), "a", 3, "working", None, dead_pid()); // omp crashed
        write(dir.path(), "gone", 4, "working", None, me); // session killed
        let store = Store::new(dir.path().into());
        store.mark_viewed("gone", 4, 1).unwrap();

        let groups = store.collect(&live(&[("a", &[1, 2 + 100, 3])]), 10);
        let panes: Vec<u32> = groups
            .iter()
            .flat_map(|g| g.panes.iter().map(|r| r.pane_id))
            .collect();
        assert_eq!(panes, [1]);
        assert!(dir.path().join("a/1.json").exists());
        assert!(!dir.path().join("a/2.json").exists());
        assert!(!dir.path().join("a/3.json").exists());
        assert!(
            !dir.path().join("gone").exists(),
            "an emptied session dir goes too"
        );
    }

    #[test]
    fn the_title_is_read_from_the_session_file_as_omp_leaves_it() {
        let dir = tempfile::tempdir().unwrap();
        let session_file = dir.path().join("sess.jsonl");
        let pane = serde_json::json!({
            "pane_id": 1, "pid": null, "state": "idle", "cwd": "/tmp", "updated_at": 1,
            "session_file": session_file,
        });
        fs::create_dir_all(dir.path().join("a")).unwrap();
        fs::write(dir.path().join("a/1.json"), pane.to_string()).unwrap();
        let store = Store::new(dir.path().into());
        let title = |store: &Store| {
            store.collect(&live(&[("a", &[1])]), 10)[0].panes[0]
                .title
                .clone()
        };

        assert_eq!(title(&store), None, "not on disk before the first reply");

        // omp's slot: padded to a fixed width so a rename rewrites it in place.
        let slot = |title: &str| {
            let json =
                format!(r#"{{"type":"title","v":1,"title":"{title}","source":"auto","pad":"#);
            format!("{json}\"{}\"}}\n", " ".repeat(200 - json.len()))
        };
        let header = "{\"type\":\"session\",\"version\":3,\"id\":\"x\"}\n";
        fs::write(
            &session_file,
            format!("{}{header}", slot("Fix the zellij test")),
        )
        .unwrap();
        assert_eq!(title(&store).as_deref(), Some("Fix the zellij test"));

        fs::write(&session_file, format!("{}{header}", slot("Renamed"))).unwrap();
        assert_eq!(title(&store).as_deref(), Some("Renamed"));

        let legacy =
            "{\"type\":\"session\",\"id\":\"x\",\"title\":\"Old style\"}\n{\"type\":\"message\"}\n";
        fs::write(&session_file, legacy).unwrap();
        assert_eq!(title(&store).as_deref(), Some("Old style"));
    }
}
