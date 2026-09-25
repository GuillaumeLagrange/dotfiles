//! The multiplexer side: a session's server, its tabs, and the root its panes
//! inherit.
//!
//! A client is attached where the behaviour needs one — zellij sizes a new tab
//! against the attached client, so a session nobody is looking at cannot be given
//! a tab that works. `script` provides the terminal it insists on. The fixture's
//! `XDG_RUNTIME_DIR` and `XDG_CACHE_HOME` keep these sessions invisible to the
//! machine's own, and each one is killed on the way out.

mod common;

use common::{have, Fixture};

use wt_core::config::Config;
use wt_core::registry::Registry;
use wt_core::session::Session;
use wt_core::zellij;

/// Run a closure with the fixture's environment applied to this process, since the
/// library talks to zellij through plain `Command`s that inherit it.
///
/// The environment is per-process, and `cargo test` runs a binary's tests as threads
/// of one process: without the lock, two fixtures would overwrite each other's
/// `XDG_RUNTIME_DIR` and look for their servers in the wrong socket directory. Under
/// nextest, where each test is its own process, the lock is free.
fn with_env<T>(f: &Fixture, body: impl FnOnce() -> T) -> T {
    static ENV: std::sync::Mutex<()> = std::sync::Mutex::new(());
    // A panicking test poisons the lock; the next one should still report its own
    // failure rather than the poisoning.
    let _guard = ENV.lock().unwrap_or_else(|poisoned| poisoned.into_inner());

    for var in [
        "HOME",
        "XDG_STATE_HOME",
        "XDG_CONFIG_HOME",
        "XDG_CACHE_HOME",
        "XDG_DATA_HOME",
        "XDG_RUNTIME_DIR",
    ] {
        std::env::set_var(var, f.env_var(var));
    }
    body()
}

fn load(id: &str) -> Session {
    let cfg = Config::load().expect("config");
    let (reg, _) = Registry::open(&cfg).expect("registry");
    Session::from_registry(&reg, id).expect("session")
}

struct Live(String);

impl Drop for Live {
    fn drop(&mut self) {
        let _ = std::process::Command::new("zellij")
            .args(["delete-session", "--force", &self.0])
            .output();
    }
}

/// A real client on a session, the way a user's terminal is one.
///
/// Its stdin is held open for as long as the guard lives: `script` ends when its
/// input does, and the client with it.
struct Attached(std::process::Child);

impl Attached {
    fn to(session: &str) -> Self {
        let child = std::process::Command::new("script")
            .args(["-q", "-c", &format!("zellij attach {session}"), "/dev/null"])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("script should run");
        let attached = Self(child);
        assert!(
            zellij::wait_for_client(session).unwrap(),
            "no client reached `{session}`"
        );
        attached
    }
}

impl Drop for Attached {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[test]
fn a_session_gets_one_tab_per_member_and_keeps_the_root() {
    if !have("zellij") || !have("script") {
        return;
    }
    let f = Fixture::new();
    f.wt(&["new", "proj-tabs", "--repo", "app", "--repo", "lib"]).ok();

    with_env(&f, || {
        let session = load("proj-tabs");
        let _live = Live("proj-tabs".into());

        assert!(!zellij::is_live("proj-tabs").unwrap(), "nothing should be up yet");
        zellij::start_detached("proj-tabs", &session.path).unwrap();
        assert!(zellij::is_live("proj-tabs").unwrap());
        assert!(
            !zellij::has_client("proj-tabs").unwrap(),
            "a session started this way is one nobody is on yet"
        );

        let _attached = Attached::to("proj-tabs");
        let mut added = zellij::ensure_tabs(&session).unwrap();
        added.sort();
        assert_eq!(added, vec!["app".to_string(), "lib".to_string()]);

        let tabs = zellij::tabs("proj-tabs").unwrap();
        let mut names: Vec<String> = tabs.iter().map(|t| t.name.clone()).collect();
        names.sort();
        assert_eq!(
            names,
            vec!["app".to_string(), "lib".to_string()],
            "zellij's own tab should have been closed once the members had theirs"
        );
        for tab in &tabs {
            assert!(!tab.is_empty(), "`{}` came up with no pane", tab.name);
        }

        // What the whole session-root mechanism comes down to: the server carries it,
        // so every pane it ever starts inherits it whatever directory it is in.
        let root = server_env("proj-tabs", zellij::ROOT_VAR);
        assert_eq!(root.as_deref(), Some(session.path.display().to_string().as_str()));
    });
}

#[test]
fn tabs_are_only_added_for_members_that_have_none() {
    if !have("zellij") || !have("script") {
        return;
    }
    let f = Fixture::new();
    f.configure(&["app", "docs", "lib"], None);
    f.wt(&["new", "proj-idem", "--repo", "app"]).ok();

    with_env(&f, || {
        let session = load("proj-idem");
        let _live = Live("proj-idem".into());
        zellij::start_detached("proj-idem", &session.path).unwrap();
        let _attached = Attached::to("proj-idem");
        zellij::ensure_tabs(&session).unwrap();

        assert!(
            zellij::ensure_tabs(&session).unwrap().is_empty(),
            "a second pass should add nothing"
        );
        assert!(zellij::untabbed(&session).unwrap().is_empty());

        // Nor should the shell having renamed a tab to the repo behind an icon.
        let app = zellij::tabs("proj-idem")
            .unwrap()
            .into_iter()
            .find(|t| t.name == "app")
            .expect("app tab");
        rename_tab("proj-idem", app.tab_id, "\u{e702} app");
        assert!(
            zellij::ensure_tabs(&session).unwrap().is_empty(),
            "a decorated tab is still its member's"
        );
        assert!(zellij::untabbed(&session).unwrap().is_empty());

        // A member gained while the session was up is the drift `sync` reports.
        f.wt(&["add", "docs", "--session", "proj-idem"]).ok();
        let session = load("proj-idem");
        assert_eq!(zellij::untabbed(&session).unwrap(), Vec::<String>::new());

        // And one whose tab was closed comes back.
        let docs = zellij::tabs("proj-idem")
            .unwrap()
            .into_iter()
            .find(|t| t.name == "docs")
            .expect("docs tab");
        zellij::close_tab("proj-idem", docs.tab_id).unwrap();
        assert_eq!(zellij::untabbed(&session).unwrap(), vec!["docs".to_string()]);

        f.wt(&["sync", "proj-idem"]).ok().says("`docs` has no tab");
        f.wt(&["sync", "proj-idem", "--fix"]).ok();
        assert!(zellij::untabbed(&session).unwrap().is_empty());
    });
}

/// Tabs are the one thing that cannot be prepared ahead of the client (see
/// `zellij::has_client`), so nothing touches them until someone is on the
/// session — `sync` included.
#[test]
fn tabs_wait_for_a_client() {
    if !have("zellij") || !have("script") {
        return;
    }
    let f = Fixture::new();
    f.wt(&["new", "proj-wait", "--repo", "app"]).ok();

    with_env(&f, || {
        let session = load("proj-wait");
        let _live = Live("proj-wait".into());
        zellij::start_detached("proj-wait", &session.path).unwrap();

        assert!(!zellij::has_client("proj-wait").unwrap());
        f.wt(&["sync", "proj-wait"]).ok().silent_about("has no tab");

        let _attached = Attached::to("proj-wait");
        assert_eq!(
            zellij::ensure_tabs(&session).unwrap(),
            vec!["app".to_string()],
            "the client is what the member's tab was waiting for"
        );
        let app = zellij::tabs("proj-wait")
            .unwrap()
            .into_iter()
            .find(|t| t.name == "app")
            .expect("app tab");
        assert!(!app.is_empty(), "`app` came up with no pane");
    });
}

#[test]
fn a_session_with_no_members_keeps_the_tab_zellij_made() {
    if !have("zellij") {
        return;
    }
    let f = Fixture::new();
    f.wt(&["new", "proj-empty", "--empty"]).ok();

    with_env(&f, || {
        let session = load("proj-empty");
        let _live = Live("proj-empty".into());
        zellij::start_detached("proj-empty", &session.path).unwrap();

        assert!(zellij::ensure_tabs(&session).unwrap().is_empty());
        let names: Vec<String> = zellij::tabs("proj-empty")
            .unwrap()
            .into_iter()
            .map(|t| t.name)
            .collect();
        assert_eq!(names.len(), 1, "a session must never be left without a tab");
        assert!(zellij::is_default_tab_name(&names[0]));
    });
}

/// From inside, the only way to free the terminal is to delete the session, which
/// takes the process asking down with it. So what makes it a rebuild rather than
/// an exit has to survive on disk.
#[test]
fn recreate_from_inside_deletes_the_session_and_leaves_the_request_behind() {
    if !have("zellij") || !have("script") {
        return;
    }
    let f = Fixture::new();
    f.wt(&["new", "proj-inside", "--repo", "app"]).ok();

    with_env(&f, || {
        let session = load("proj-inside");
        let _live = Live("proj-inside".into());
        zellij::start_detached("proj-inside", &session.path).unwrap();
        let _attached = Attached::to("proj-inside");

        // No id and a cwd outside the session: the pane's own session is the one
        // meant, and its name is the registry key.
        f.wt_with(
            &["recreate"],
            &[("ZELLIJ", "0"), ("ZELLIJ_SESSION_NAME", "proj-inside")],
        )
        .ok();

        assert!(
            wait_for(|| !zellij::is_live("proj-inside").unwrap_or(true)),
            "the client was left sitting on the session it asked to replace"
        );
        assert!(
            session.path.join(wt_core::session::RECREATE).is_file(),
            "nothing was left for the next attach to act on"
        );
    });
}

/// End to end: the terminal comes back to a session that was built again, not to
/// the one that was there. A tab the old session had is the evidence — a
/// resurrected session would still carry it.
#[test]
fn recreate_hands_the_terminal_back_to_a_new_session() {
    if !have("zellij") || !have("script") {
        return;
    }
    let f = Fixture::new();
    f.wt(&["new", "proj-fresh", "--repo", "app"]).ok();

    with_env(&f, || {
        let _live = Live("proj-fresh".into());
        let _supervisor = Supervised::on("proj-fresh");
        assert!(
            wait_for(|| tab_names("proj-fresh") == ["app"]),
            "the member never got its tab: {:?}",
            tab_names("proj-fresh")
        );

        zellij::new_tab("proj-fresh", &f.workspace, "scratch").unwrap();
        assert!(tab_names("proj-fresh").contains(&"scratch".to_string()));

        f.wt_with(
            &["recreate"],
            &[("ZELLIJ", "0"), ("ZELLIJ_SESSION_NAME", "proj-fresh")],
        )
        .ok();

        assert!(
            wait_for(|| zellij::has_client("proj-fresh").unwrap_or(false)),
            "nobody was handed the terminal back"
        );
        assert!(
            wait_for(|| tab_names("proj-fresh") == ["app"]),
            "the old session came back instead of a new one: {:?}",
            tab_names("proj-fresh")
        );
        // Consumed, not merely acted on: a request left behind would throw the
        // session away again the next time anyone attaches.
        assert!(
            !f.session("proj-fresh")
                .join(wt_core::session::RECREATE)
                .exists(),
            "the request outlived the rebuild"
        );
    });
}

/// The `wt` a user's terminal is given to, which is also what rebuilds the session
/// between two clients.
struct Supervised(std::process::Child);

impl Supervised {
    fn on(session: &str) -> Self {
        let child = std::process::Command::new("script")
            .args([
                "-q",
                "-c",
                &format!("{} {session}", env!("CARGO_BIN_EXE_wt")),
                "/dev/null",
            ])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            // The test suite may well be running inside zellij itself, and a `wt`
            // that believes it is in a session switches to the target instead of
            // attaching to it.
            .env_remove("ZELLIJ")
            .env_remove("ZELLIJ_SESSION_NAME")
            .spawn()
            .expect("script should run");
        let supervised = Self(child);
        // Not `wait_for_client`: the session does not exist yet — this `wt` is what
        // creates it — and asking about one that is not there is an error, which
        // that helper reads as "nobody came".
        assert!(
            wait_for(|| zellij::has_client(session).unwrap_or(false)),
            "no client reached `{session}`"
        );
        supervised
    }
}

impl Drop for Supervised {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn tab_names(session: &str) -> Vec<String> {
    zellij::tabs(session)
        .map(|tabs| tabs.into_iter().map(|t| t.name).collect())
        .unwrap_or_default()
}

/// Poll a state the multiplexer reaches on its own time. False once it has had
/// long enough that waiting longer would only hide a failure.
fn wait_for(mut cond: impl FnMut() -> bool) -> bool {
    for _ in 0..200 {
        if cond() {
            return true;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    false
}

/// Stand in for what the shell's rename hook does to a tab. wt has no reason to
/// rename one, so this is a test-only reach for `zellij action`.
fn rename_tab(session: &str, id: u32, name: &str) {
    let out = std::process::Command::new("zellij")
        .args([
            "--session",
            session,
            "action",
            "rename-tab-by-id",
            &id.to_string(),
            name,
        ])
        .output()
        .expect("zellij should run");
    assert!(
        out.status.success(),
        "could not rename tab {id}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

/// A variable as the session's server process holds it, which is what its panes
/// inherit.
fn server_env(session: &str, var: &str) -> Option<String> {
    let out = std::process::Command::new("pgrep")
        .args(["-f", &format!("zellij --server .*{session}")])
        .output()
        .ok()?;
    let prefix = format!("{var}=");
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|pid| std::fs::read(format!("/proc/{pid}/environ")).ok())
        .find_map(|environ| {
            String::from_utf8_lossy(&environ)
                .split('\0')
                .find_map(|entry| entry.strip_prefix(&prefix).map(str::to_string))
        })
}
