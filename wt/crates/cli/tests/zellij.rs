//! The multiplexer side: a session's server, its tabs, and the root its panes
//! inherit.
//!
//! Attaching replaces the process and needs a terminal, so what is driven here is
//! everything up to that point — which is where all the behaviour is. The fixture's
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
/// Tests each get their own process under nextest, so this does not leak.
fn with_env<T>(f: &Fixture, body: impl FnOnce() -> T) -> T {
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

#[test]
fn a_session_gets_one_tab_per_member_and_keeps_the_root() {
    if !have("zellij") {
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

        let mut added = zellij::ensure_tabs(&session, true).unwrap();
        added.sort();
        assert_eq!(added, vec!["app".to_string(), "lib".to_string()]);

        let mut names: Vec<String> = zellij::tabs("proj-tabs")
            .unwrap()
            .into_iter()
            .map(|t| t.name)
            .collect();
        names.sort();
        assert_eq!(
            names,
            vec!["app".to_string(), "lib".to_string()],
            "zellij's own tab should have been closed once the members had theirs"
        );

        // What the whole session-root mechanism comes down to: the server carries it,
        // so every pane it ever starts inherits it whatever directory it is in.
        let root = server_env("proj-tabs", zellij::ROOT_VAR);
        assert_eq!(root.as_deref(), Some(session.path.display().to_string().as_str()));
    });
}

#[test]
fn tabs_are_only_added_for_members_that_have_none() {
    if !have("zellij") {
        return;
    }
    let f = Fixture::new();
    f.configure(&["app", "docs", "lib"], None);
    f.wt(&["new", "proj-idem", "--repo", "app"]).ok();

    with_env(&f, || {
        let session = load("proj-idem");
        let _live = Live("proj-idem".into());
        zellij::start_detached("proj-idem", &session.path).unwrap();
        zellij::ensure_tabs(&session, true).unwrap();

        assert!(
            zellij::ensure_tabs(&session, false).unwrap().is_empty(),
            "re-attaching should add nothing"
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

        assert!(zellij::ensure_tabs(&session, true).unwrap().is_empty());
        let names: Vec<String> = zellij::tabs("proj-empty")
            .unwrap()
            .into_iter()
            .map(|t| t.name)
            .collect();
        assert_eq!(names.len(), 1, "a session must never be left without a tab");
        assert!(zellij::is_default_tab_name(&names[0]));
    });
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
