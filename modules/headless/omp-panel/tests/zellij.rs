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

fn have(bin: &str) -> bool {
    Command::new("sh")
        .args(["-c", &format!("command -v {bin}")])
        .stdout(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

fn wait_for(mut cond: impl FnMut() -> bool) -> bool {
    for _ in 0..200 {
        if cond() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    false
}

impl Fixture {
    fn new() -> Option<Self> {
        if !have("zellij") || !have("script") {
            return None;
        }
        let dir = tempfile::Builder::new()
            .prefix("omp-panel")
            .tempdir()
            .unwrap();
        let root = dir.path();
        let mut env = HashMap::new();
        for (var, rel) in [
            ("HOME", "home"),
            ("XDG_RUNTIME_DIR", "run"),
            ("XDG_CACHE_HOME", "cache"),
            ("XDG_DATA_HOME", "data"),
            ("XDG_CONFIG_HOME", "config"),
            ("ZELLIJ_CONFIG_DIR", "config/zellij"),
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
        write_script(&attach, "exec zellij attach \"$1\"\n");
        env.insert("OMP_PANEL_ATTACH", attach.display().to_string());

        Some(Self {
            dir,
            env,
            clients: Vec::new(),
        })
    }

    fn root(&self) -> &Path {
        self.dir.path()
    }

    fn command(&self, program: impl AsRef<std::ffi::OsStr>) -> Command {
        let mut cmd = Command::new(program);
        cmd.env_clear().envs(&self.env);
        cmd
    }

    fn zellij(&self, args: &[&str]) -> Output {
        self.command("zellij").args(args).output().unwrap()
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
        assert!(wait_for(|| {
            let out = self.zellij(&["-s", session, "action", "list-panes", "--json"]);
            serde_json::from_slice::<serde_json::Value>(&out.stdout).is_ok_and(|v| {
                v.as_array()
                    .is_some_and(|a| a.iter().any(|p| p["is_plugin"] == false))
            })
        }));
    }

    /// A real client on a session, the way a user's terminal is one.
    ///
    /// Its input is /dev/null, not a pipe held open: a client behind a silent pipe
    /// does not follow `focus-pane-id` to another tab.
    fn attach(&mut self, session: &str) {
        let child = self
            .command("script")
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
            .unwrap();
        self.clients.push(child);
        assert!(
            wait_for(|| !self.client_panes(session).is_empty()),
            "no client reached `{session}`"
        );
    }

    fn new_pane(&self, session: &str) -> u32 {
        let out = self.zellij(&["-s", session, "action", "new-pane"]);
        let id = String::from_utf8_lossy(&out.stdout);
        id.trim()
            .strip_prefix("terminal_")
            .unwrap()
            .parse()
            .unwrap()
    }

    fn client_panes(&self, session: &str) -> Vec<String> {
        let out = self.zellij(&["-s", session, "action", "list-clients"]);
        String::from_utf8_lossy(&out.stdout)
            .lines()
            .skip(1)
            .filter_map(|l| l.split_whitespace().nth(1).map(str::to_owned))
            .collect()
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
    let Some(f) = Fixture::new() else { return };
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
fn jump_focuses_the_window_showing_the_session_then_the_pane() {
    let Some(mut f) = Fixture::new() else { return };
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
    let Some(mut f) = Fixture::new() else { return };
    f.start("beta");
    let other = f.new_pane("beta");
    let log = f.fake_niri(r#"[{"id":3,"title":"alpha | x"}]"#);
    // Whichever pane the new client lands on, jump to the other one.
    let listed = json(&f.zellij(&["-s", "beta", "action", "list-panes", "--json", "--state"]));
    let focused = listed
        .as_array()
        .unwrap()
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
    let Some(mut f) = Fixture::new() else { return };
    f.start("alpha");
    f.start("beta");
    let target = f.new_pane("beta");
    f.zellij(&["-s", "beta", "action", "focus-pane-id", "terminal_0"]);
    f.attach("alpha");
    assert!(f.client_panes("beta").is_empty());

    // From a pane of alpha, the way the floating picker runs.
    let bin = env!("CARGO_BIN_EXE_omp-panel");
    let pane = target.to_string();
    let out = f.zellij(&[
        "-s", "alpha", "action", "new-pane", "--", bin, "jump", "beta", &pane,
    ]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );

    let expected = format!("terminal_{target}");
    assert!(
        wait_for(|| f.client_panes("beta") == [expected.as_str()]),
        "{:?}",
        f.client_panes("beta")
    );
    assert!(f.client_panes("alpha").is_empty(), "the client left alpha");
}
