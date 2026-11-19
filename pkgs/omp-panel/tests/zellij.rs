//! The panel against real zellij servers.
//!
//! Each fixture has its own `XDG_RUNTIME_DIR` (zellij's sockets and the pane
//! files), cache and config, so its sessions are invisible to the machine's own
//! and everything is torn down with it. omp itself is not run: the pane files it
//! would write are written directly, in the extension's format. niri is a script
//! on `PATH` that logs what it is asked and answers from a canned window list.
//! Clients are real, attached through `script` for the terminal zellij insists on.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::time::Duration;

struct Fixture {
    dir: tempfile::TempDir,
    env: HashMap<&'static str, String>,
    clients: Vec<Child>,
}

fn wait_for(mut cond: impl FnMut() -> bool) -> bool {
    // Generous: every suite of the repo may be running at once.
    for _ in 0..600 {
        if cond() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    false
}

impl Fixture {
    fn new() -> Self {
        // Servers of fixtures already gone: a test nextest killed never dropped
        // its own, and an orphan of zellij's race can outlive the sweep in `drop`.
        // Gone means without its marker: such a server makes its directories again.
        let tmp = std::env::temp_dir();
        kill_servers(|socket| {
            socket
                .strip_prefix(&tmp)
                .ok()
                .and_then(|rest| rest.iter().next())
                .is_some_and(|dir| {
                    dir.to_string_lossy().starts_with("omp-panel")
                        && !tmp.join(dir).join(MARKER).exists()
                })
        });
        let dir = tempfile::Builder::new()
            .prefix("omp-panel")
            .tempdir()
            .unwrap();
        let root = dir.path();
        std::fs::write(root.join(MARKER), "").unwrap();
        let mut env = HashMap::new();
        for (var, rel) in [
            ("HOME", "home"),
            ("XDG_RUNTIME_DIR", "run"),
            ("XDG_CACHE_HOME", "cache"),
            ("XDG_DATA_HOME", "data"),
            ("XDG_CONFIG_HOME", "config"),
            ("ZELLIJ_CONFIG_DIR", "config/zellij"),
            // zellij's log, which the machine's own sessions write to as well.
            ("TMPDIR", "tmp"),
        ] {
            std::fs::create_dir_all(root.join(rel)).unwrap();
            env.insert(var, root.join(rel).display().to_string());
        }
        std::fs::write(
            root.join("config/zellij/config.kdl"),
            "show_startup_tips false\nshow_release_notes false\nsession_serialization false\n",
        )
        .unwrap();

        let bin = root.join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        let path = format!(
            "{}:{}",
            bin.display(),
            std::env::var("PATH").unwrap_or_default()
        );
        env.insert("PATH", path);
        env.insert("TERM", "xterm-256color".into());
        // `script` runs its command through $SHELL, and zsh on NixOS resets PATH.
        env.insert("SHELL", "/bin/sh".into());
        // What the panel opens a window with: no terminal, just the attach, so the
        // fake niri can run it under `script`.
        env.insert("OMP_PANEL_TERM_EXEC", "[]".into());
        let attach = bin.join("attach");
        // As zellij-attach does: an attach that finds no session is tried again,
        // zellij's check that it is up failing now and then on a live one.
        write_script(
            &attach,
            r#"for _ in 1 2 3 4 5; do
  err=$( { zellij attach "$1" 2>&1 1>&3; } 3>&1 ) && exit 0
  case "$err" in *"No session with the name"*) ;; *) exit 1 ;; esac
done
exit 1
"#,
        );
        env.insert("OMP_PANEL_ATTACH", attach.display().to_string());

        Self {
            dir,
            env,
            clients: Vec::new(),
        }
    }

    fn root(&self) -> &Path {
        self.dir.path()
    }

    fn command(&self, program: impl AsRef<std::ffi::OsStr>) -> Command {
        let mut cmd = Command::new(program);
        cmd.env_clear().envs(&self.env);
        cmd
    }

    /// A zellij command, run again while zellij says the session is not there:
    /// its check that the session is up fails now and then on a live one, before
    /// anything was sent (see `run` in `src/zellij.rs`). With other sessions up,
    /// it says so on stderr and lists them, exiting 0: still a failure here.
    fn zellij(&self, args: &[&str]) -> Output {
        let unsent = |out: &Output| {
            let stderr = String::from_utf8_lossy(&out.stderr);
            stderr.contains("There is no active session!")
                || stderr.contains("not found. The following sessions are active")
        };
        let mut out = self.command("zellij").args(args).output().unwrap();
        for _ in 0..4 {
            if !unsent(&out) {
                return out;
            }
            out = self.command("zellij").args(args).output().unwrap();
        }
        if unsent(&out) {
            use std::os::unix::process::ExitStatusExt;
            out.status = std::process::ExitStatus::from_raw(1 << 8);
            out.stdout.clear();
        }
        out
    }

    /// A query action's answer, parsed; None when the action fails. zellij can
    /// hand a CLI client an unblock or an answer meant for the client before it
    /// (see `zellij::query`), so an answer that does not parse is asked again.
    fn query<T>(
        &self,
        session: &str,
        action: &[&str],
        parse: impl Fn(&str) -> Option<T>,
    ) -> Option<T> {
        let mut args = vec!["-s", session, "action"];
        args.extend(action);
        for _ in 0..20 {
            let out = self.zellij(&args);
            if !out.status.success() {
                return None;
            }
            if let Some(answer) = parse(&String::from_utf8_lossy(&out.stdout)) {
                return Some(answer);
            }
        }
        panic!("`zellij {}` never gave a usable answer", args.join(" "));
    }

    /// `list-panes --json`, with `extra` flags.
    fn list_panes(&self, session: &str, extra: &[&str]) -> Vec<serde_json::Value> {
        let mut action = vec!["list-panes", "--json"];
        action.extend(extra);
        self.query(session, &action, |out| serde_json::from_str(out).ok())
            .unwrap_or_default()
    }

    fn panel(&self, args: &[&str], extra: &[(&str, &str)]) -> Output {
        self.command(env!("CARGO_BIN_EXE_omp-panel"))
            .args(args)
            .envs(extra.iter().copied())
            .output()
            .unwrap()
    }

    fn start(&self, session: &str) {
        let out = self.zellij(&["attach", "--create-background", session]);
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        // The server answers before its layout has made the first pane.
        assert!(wait_for(|| self
            .list_panes(session, &[])
            .iter()
            .any(|p| p["is_plugin"] == false)));
        // And the client that created it can still be listed for a moment, which
        // `attach` would take for its own.
        assert!(wait_for(|| self.client_panes(session).is_empty()));
    }

    /// A real client on a session, the way a user's terminal is one.
    ///
    /// Its input is /dev/null, not a pipe held open: a client behind a silent pipe
    /// does not follow `focus-pane-id` to another tab.
    fn attach(&mut self, session: &str) {
        let spawn = |f: &Self| {
            f.command("script")
                .args([
                    "-q",
                    "-c",
                    &format!("stty rows 40 cols 120; zellij attach {session}"),
                    "/dev/null",
                ])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap()
        };
        let mut child = spawn(self);
        // A server still loading its plugins can drop a client the moment it
        // arrives ("lost connection"), and a user would attach again.
        let reached = wait_for(|| {
            if matches!(child.try_wait(), Ok(Some(_))) {
                child = spawn(self);
            }
            !self.client_panes(session).is_empty()
        });
        self.clients.push(child);
        assert!(reached, "no client reached `{session}`");
    }

    fn new_pane(&self, session: &str) -> u32 {
        let before = self.terminal_panes(session);
        let out = self.zellij(&["-s", session, "action", "new-pane"]);
        let id = String::from_utf8_lossy(&out.stdout);
        if let Some(id) = id.trim().strip_prefix("terminal_") {
            return id.parse().unwrap();
        }
        // Zellij sometimes opens the pane and prints nothing (see `query`): it is
        // the one that was not there before.
        let mut new = None;
        let found = wait_for(|| {
            new = self
                .terminal_panes(session)
                .into_iter()
                .find(|id| !before.contains(id));
            new.is_some()
        });
        assert!(
            found,
            "no new pane in `{session}`: new-pane said {out:?}, panes were {before:?}, now {:?}; sessions: {:?}",
            self.zellij(&["-s", session, "action", "list-panes", "--json"]),
            self.zellij(&["list-sessions", "--no-formatting"]),
        );
        new.unwrap()
    }

    fn terminal_panes(&self, session: &str) -> Vec<u32> {
        self.list_panes(session, &[])
            .iter()
            .filter(|p| p["is_plugin"] == false)
            .filter_map(|p| p["id"].as_u64())
            .map(|id| id as u32)
            .collect()
    }

    fn client_panes(&self, session: &str) -> Vec<String> {
        self.query(session, &["list-clients"], |out| {
            let mut lines = out.lines();
            lines.next()?.starts_with("CLIENT_ID").then(|| {
                lines
                    .filter_map(|l| l.split_whitespace().nth(1).map(str::to_owned))
                    .collect()
            })
        })
        .unwrap_or_default()
    }

    fn state_dir(&self) -> PathBuf {
        self.root().join("run/omp-panel")
    }

    /// What the extension would write for an omp in that pane.
    fn omp(&self, session: &str, pane: u32, state: &str, finished_at: Option<u64>) {
        let dir = self.state_dir().join(session);
        std::fs::create_dir_all(&dir).unwrap();
        let body = serde_json::json!({
            "session": session,
            "pane_id": pane,
            "pid": std::process::id(),
            "state": state,
            "blocked_reason": null,
            "last_message": format!("reply from {pane}"),
            "cwd": "/tmp",
            "updated_at": 1,
            "finished_at": finished_at,
        });
        std::fs::write(dir.join(format!("{pane}.json")), body.to_string()).unwrap();
    }

    /// A niri whose windows are `windows`, logging every call.
    fn fake_niri(&mut self, windows: &str) -> PathBuf {
        let log = self.root().join("niri.log");
        let script = format!(
            r#"echo "$*" >> '{log}'
[ "$1" = msg ] && shift
case "$1 $2" in
  "-j windows") echo '{windows}' ;;
  "action spawn") shift 3; script -q -c "stty rows 40 cols 120; $*" /dev/null < /dev/null > /dev/null 2>&1 & ;;
esac
"#,
            log = log.display()
        );
        write_script(&self.root().join("bin/niri"), &script);
        self.env.insert(
            "NIRI_SOCKET",
            self.root().join("niri.sock").display().to_string(),
        );
        log
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.zellij(&["kill-all-sessions", "--yes"]);
        for child in &mut self.clients {
            let _ = child.kill();
            let _ = child.wait();
        }
        // A server whose name zellij gave to another (see the switch test) has no
        // socket left for kill-all-sessions to reach.
        kill_servers(|socket| socket.starts_with(self.root()));
    }
}

/// Written in a fixture's directory while it lives.
const MARKER: &str = ".fixture";

/// SIGKILLs the zellij servers whose socket `matches` (zellij catches SIGTERM).
fn kill_servers(matches: impl Fn(&Path) -> bool) {
    for entry in std::fs::read_dir("/proc").into_iter().flatten().flatten() {
        let Ok(cmdline) = std::fs::read(entry.path().join("cmdline")) else {
            continue;
        };
        let argv: Vec<String> = cmdline
            .split(|&b| b == 0)
            .map(|a| String::from_utf8_lossy(a).into_owned())
            .collect();
        if argv.get(1).is_some_and(|a| a == "--server")
            && argv.get(2).is_some_and(|s| matches(Path::new(s)))
        {
            let _ = Command::new("kill")
                .arg("-KILL")
                .arg(entry.file_name())
                .status();
        }
    }
}

fn write_script(path: &Path, body: &str) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::write(path, format!("#!/bin/sh\n{body}")).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

fn json(out: &Output) -> serde_json::Value {
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    serde_json::from_slice(&out.stdout).unwrap()
}

#[test]
fn list_shows_live_panes_rolled_up_and_prunes_the_rest() {
    let f = Fixture::new();
    f.start("alpha");
    let second = f.new_pane("alpha");
    f.omp("alpha", 0, "working", None);
    f.omp("alpha", second, "idle", Some(5));
    f.omp("alpha", 99, "working", None); // its pane was closed
    f.omp("ghost", 0, "blocked", None); // its session is gone

    let groups = json(&f.panel(&["list", "--json"], &[]));
    let groups = groups.as_array().unwrap();
    assert_eq!(groups.len(), 1, "{groups:?}");
    assert_eq!(groups[0]["session"], "alpha");
    assert_eq!(
        groups[0]["status"], "working",
        "working outranks done: {groups:?}"
    );
    let panes: Vec<(u64, &str)> = groups[0]["panes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| {
            (
                p["pane_id"].as_u64().unwrap(),
                p["status"].as_str().unwrap(),
            )
        })
        .collect();
    assert_eq!(panes, [(0, "working"), (second as u64, "done")]);
    assert_eq!(
        groups[0]["panes"][1]["last_message"],
        format!("reply from {second}")
    );

    assert!(!f.state_dir().join("alpha/99.json").exists());
    assert!(!f.state_dir().join("ghost").exists());
}

#[test]
fn panes_lists_what_runs_in_each_pane() {
    let f = Fixture::new();
    f.start("panes-test");
    let busy = f.new_pane("panes-test");
    let target = format!("terminal_{busy}");
    f.zellij(&[
        "-s",
        "panes-test",
        "action",
        "write-chars",
        "-p",
        &target,
        "cd /tmp && sleep 4242\n",
    ]);

    let rows = || {
        json(&f.panel(&["panes", "list", "--json"], &[]))
            .as_array()
            .unwrap()
            .iter()
            .filter(|r| r["session"] == "panes-test")
            .map(|r| (r["pane_id"].as_u64().unwrap() as u32, r.clone()))
            .collect::<HashMap<_, _>>()
    };
    let mut seen = HashMap::new();
    assert!(
        wait_for(|| {
            seen = rows();
            seen.contains_key(&0)
                && seen
                    .get(&busy)
                    .is_some_and(|r| r["command"] == "sleep 4242")
        }),
        "{seen:?}"
    );
    assert_eq!(seen[&busy]["idle"], false);
    assert_eq!(seen[&busy]["cwd"], "/tmp", "the foreground process's cwd");
    assert_eq!(seen[&0]["idle"], true, "{:?}", seen[&0]);
}

#[test]
fn jump_focuses_the_window_showing_the_session_then_the_pane() {
    let mut f = Fixture::new();
    f.start("alpha");
    f.attach("alpha");
    let out = f.zellij(&["-s", "alpha", "action", "new-tab"]);
    assert!(out.status.success());
    let target = f.new_pane("alpha");
    f.zellij(&["-s", "alpha", "action", "focus-pane-id", "terminal_0"]);
    assert!(wait_for(|| f.client_panes("alpha") == ["terminal_0"]));
    f.omp("alpha", target, "idle", Some(5));
    let log = f.fake_niri(r#"[{"id":3,"title":"other | x"},{"id":7,"title":"alpha | Pane #1"}]"#);

    let out = f.panel(&["jump", "alpha", &target.to_string()], &[]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );

    let calls = std::fs::read_to_string(log).unwrap();
    assert!(calls.contains("msg action focus-window --id 7"), "{calls}");
    assert!(!calls.contains("spawn"), "{calls}");
    let expected = format!("terminal_{target}");
    assert!(
        wait_for(|| f.client_panes("alpha") == [expected.as_str()]),
        "{:?}",
        f.client_panes("alpha")
    );
    let groups = json(&f.panel(&["list", "--json"], &[]));
    assert_eq!(
        groups[0]["panes"][0]["status"], "idle",
        "a jump counts as viewing it"
    );
}

#[test]
fn jump_opens_a_window_for_a_session_nobody_shows() {
    let mut f = Fixture::new();
    f.start("beta");
    let other = f.new_pane("beta");
    let log = f.fake_niri(r#"[{"id":3,"title":"alpha | x"}]"#);
    // Whichever pane the new client lands on, jump to the other one.
    let focused = f
        .list_panes("beta", &["--state"])
        .iter()
        .find(|p| p["is_plugin"] == false && p["is_focused"] == true)
        .and_then(|p| p["id"].as_u64())
        .unwrap() as u32;
    let target = if focused == other { 0 } else { other };

    let out = f.panel(&["jump", "beta", &target.to_string()], &[]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );

    let calls = std::fs::read_to_string(log).unwrap();
    let attach = &f.env["OMP_PANEL_ATTACH"];
    assert!(
        calls.contains(&format!("msg action spawn -- {attach} beta")),
        "{calls}"
    );
    let expected = format!("terminal_{target}");
    assert!(
        wait_for(|| f.client_panes("beta") == [expected.as_str()]),
        "{:?}",
        f.client_panes("beta")
    );
}

#[test]
fn jump_without_niri_moves_this_client_to_the_other_session() {
    // zellij's own switch reconnects with `attach --create`, which now and then
    // takes a live session for gone and starts a new one under its name, and the
    // race behind it can lose the switch altogether (see AGENTS.md). A run where
    // either happened says nothing of the panel, and is run again.
    for _ in 0..3 {
        let mut f = Fixture::new();
        f.start("alpha");
        f.start("beta");
        let target = f.new_pane("beta");
        f.zellij(&["-s", "beta", "action", "focus-pane-id", "terminal_0"]);
        f.attach("alpha");
        assert!(f.client_panes("beta").is_empty());

        // From a pane of alpha, the way the floating picker runs, keeping what
        // `jump` said and how it exited.
        let bin = env!("CARGO_BIN_EXE_omp-panel");
        let pane = target.to_string();
        let status = f.root().join("jump.status");
        let stderr = f.root().join("jump.stderr");
        let script = format!(
            "'{bin}' jump beta {pane} 2>'{}'; echo $? >'{}'",
            stderr.display(),
            status.display()
        );
        let out = f.zellij(&[
            "-s", "alpha", "action", "new-pane", "--", "sh", "-c", &script,
        ]);
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );

        let expected = format!("terminal_{target}");
        let replaced = || !f.terminal_panes("beta").contains(&target);
        // Short enough that three tries fit in nextest's timeout.
        let deadline = std::time::Instant::now() + Duration::from_secs(15);
        let mut on_beta = f.client_panes("beta");
        while on_beta != [expected.as_str()] && !replaced() {
            if std::time::Instant::now() > deadline {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
            on_beta = f.client_panes("beta");
        }
        if on_beta == [expected.as_str()] {
            assert!(
                wait_for(|| f.client_panes("alpha").is_empty()),
                "the client left alpha"
            );
            return;
        }
        let exited = std::fs::read_to_string(&status).ok();
        let said = std::fs::read_to_string(&stderr).unwrap_or_default();
        // `jump` ran and zellij took the switch, or never started the pane: the
        // client went nowhere through no fault of the panel.
        if replaced() || exited.as_deref().is_none_or(|s| s.trim() == "0") {
            continue;
        }
        panic!(
            "jump exited {exited:?}: {said}; the client is on {on_beta:?} of beta and {:?} of alpha",
            f.client_panes("alpha")
        );
    }
    panic!("zellij replaced `beta` or lost the switch on every try");
}
