//! The bar, run headless: niri on its headless backend (patched in by
//! `niri-headless.patch`), a private D-Bus session and runtime directory, and
//! `qs` on a copy of the shell built by the home-manager module. Nothing
//! reaches the desktop it runs on: input goes in through niri's virtual
//! keyboard and pointer (`wtype`, `wlrctl`), and the bar's commands that would
//! leave the fixture are stubs that record their arguments.
//!
//! The tests read the bar through `TestProbe.qml`, an `IpcHandler` the copy
//! gains, so assertions are on the panel's state rather than on pixels.

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::LazyLock;
use std::time::{Duration, Instant};

use serde_json::Value;

/// The module's `quickshellTestEnv`: `bin/` holds niri, qs, wtype, wlrctl and
/// dbus-daemon, `shell/` the built shell with its generated Config.qml. Built
/// once per run from this checkout for the current host, or taken from
/// `QUICKSHELL_TEST_ENV`. None on a host without the bar (gullywash).
static TEST_ENV: LazyLock<Option<PathBuf>> = LazyLock::new(|| {
    if let Some(dir) = std::env::var_os("QUICKSHELL_TEST_ENV") {
        return Some(PathBuf::from(dir));
    }
    let home = PathBuf::from(std::env::var_os("HOME").unwrap());
    if !home.join(".config/quickshell/bar").exists() {
        eprintln!("skipped: this host runs no quickshell bar");
        return None;
    }
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../..");
    let host = std::fs::read_to_string("/etc/hostname").unwrap();
    let user = std::env::var("USER").unwrap();
    let attr = format!(
        ".#nixosConfigurations.{}.config.home-manager.users.{user}.quickshellTestEnv",
        host.trim()
    );
    let out = Command::new("nix")
        .args(["build", "--no-link", "--print-out-paths", &attr])
        .current_dir(&repo)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "building {attr}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    Some(PathBuf::from(String::from_utf8(out.stdout).unwrap().trim()))
});

fn test_env() -> &'static Path {
    TEST_ENV.as_deref().unwrap()
}

const TIMEOUT: Duration = Duration::from_secs(10);

pub struct Session {
    root: PathBuf,
    env: Vec<(String, String)>,
    children: Vec<Child>,
}

fn write_exe(path: &Path, body: &str) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::write(path, format!("#!/bin/sh\n{body}")).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

/// Replaces `from` once in `path`, failing loudly when the source moved on.
fn splice(path: &Path, from: &str, to: &str) {
    let text = std::fs::read_to_string(path).unwrap();
    assert!(
        text.contains(from),
        "{} no longer contains {from:?}",
        path.display()
    );
    std::fs::write(path, text.replacen(from, to, 1)).unwrap();
}

fn wait_until(what: &str, mut ready: impl FnMut() -> bool) {
    let start = Instant::now();
    while !ready() {
        assert!(start.elapsed() < TIMEOUT, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

impl Session {
    /// The bar on one 1920x1080 output, `reviews --json` printing `reviews`;
    /// None where it is skipped.
    pub fn start(reviews: &Value) -> Option<Self> {
        Self::start_with_outputs(reviews, 1)
    }

    /// As `start`, with `outputs` 1920x1080 outputs.
    pub fn start_with_outputs(reviews: &Value, outputs: u8) -> Option<Self> {
        Self::boot(reviews, outputs, &[])
    }

    /// As `start`, with these desktop entries installed, by id and contents.
    /// Their `Exec` can run `app`, a stub that records its arguments in `app.log`.
    pub fn start_with_apps(reviews: &Value, apps: &[(&str, &str)]) -> Option<Self> {
        Self::boot(reviews, 1, apps)
    }

    fn boot(reviews: &Value, outputs: u8, apps: &[(&str, &str)]) -> Option<Self> {
        let env_dir = TEST_ENV.as_deref()?;
        static N: AtomicUsize = AtomicUsize::new(0);
        // Short: the wayland socket path has to fit in a sockaddr_un.
        let root = std::env::temp_dir().join(format!(
            "qst-{}-{}",
            std::process::id(),
            N.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&root);
        for dir in ["run", "home", "bin", "share", "config", "cache", "state"] {
            std::fs::create_dir_all(root.join(dir)).unwrap();
        }
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(root.join("run"), std::fs::Permissions::from_mode(0o700))
                .unwrap();
        }

        let p = |rel: &str| root.join(rel).to_str().unwrap().to_owned();

        std::fs::write(root.join("reviews.json"), reviews.to_string()).unwrap();
        write_exe(
            &root.join("bin/reviews"),
            &format!(
                "case \"$1\" in\n--json) cat {json} ;;\n--refresh) echo refresh >> {log} ;;\nesac\n",
                json = p("reviews.json"),
                log = p("refresh.log")
            ),
        );
        // What Config.reviewPr / reviewMine spawn through niri.
        write_exe(
            &root.join("bin/review"),
            &format!("printf '%s\\n' \"$*\" >> {}\n", p("review.log")),
        );
        write_exe(
            &root.join("bin/app"),
            &format!("printf '%s\\n' \"$*\" >> {}\n", p("app.log")),
        );
        std::fs::create_dir_all(root.join("share/applications")).unwrap();
        for (id, contents) in apps {
            std::fs::write(
                root.join(format!("share/applications/{id}.desktop")),
                contents,
            )
            .unwrap();
        }
        // The zellij tab name a test puts in `tab`, as Config.reviewTab prints it.
        write_exe(
            &root.join("bin/review-tab"),
            &format!("cat {} 2>/dev/null\n", p("tab")),
        );
        // What Config.openUrl runs.
        write_exe(
            &root.join("bin/open-url"),
            &format!("printf '%s\\n' \"$*\" >> {}\n", p("open-url.log")),
        );

        // The layout is pinned: niri would take the host's from localed.
        std::fs::write(
            root.join("niri.kdl"),
            "input {\n    keyboard {\n        xkb {\n            layout \"us\"\n        }\n    }\n}\nhotkey-overlay {\n    skip-at-startup\n}\nanimations {\n    off\n}\n",
        )
        .unwrap();

        let shell = root.join("shell");
        let status = Command::new("cp")
            .arg("-rL")
            .arg(env_dir.join("shell"))
            .arg(&shell)
            .status()
            .unwrap();
        assert!(status.success());
        Command::new("chmod")
            .arg("-R")
            .arg("u+w")
            .arg(&shell)
            .status()
            .unwrap();
        Self::instrument(&shell, &root.join("bin"));

        let env = vec![
            ("HOME".into(), p("home")),
            ("XDG_RUNTIME_DIR".into(), p("run")),
            ("XDG_CONFIG_HOME".into(), p("config")),
            ("XDG_CACHE_HOME".into(), p("cache")),
            ("XDG_STATE_HOME".into(), p("state")),
            ("XDG_DATA_DIRS".into(), p("share")),
            (
                "PATH".into(),
                format!(
                    "{}:{}:/run/current-system/sw/bin",
                    p("bin"),
                    env_dir.join("bin").display()
                ),
            ),
            (
                "DBUS_SESSION_BUS_ADDRESS".into(),
                format!("unix:path={}", p("run/bus")),
            ),
            ("LANG".into(), "C.UTF-8".into()),
            ("TZ".into(), "UTC".into()),
        ];
        let mut session = Session {
            root,
            env,
            children: Vec::new(),
        };

        let dbus = session
            .command("dbus-daemon")
            .args(["--session", "--nofork", "--nopidfile"])
            .arg(format!(
                "--address=unix:path={}",
                session.path("run/bus").display()
            ))
            .spawn()
            .unwrap();
        session.children.push(dbus);
        wait_until("the D-Bus session", || session.path("run/bus").exists());

        let niri = session
            .command("niri")
            .env("NIRI_HEADLESS", outputs.to_string())
            .env("NIRI_CONFIG", session.path("niri.kdl"))
            .env("NIRI_DISABLE_SYSTEM_MANAGER_NOTIFY", "1")
            .stderr(std::fs::File::create(session.path("niri.log")).unwrap())
            .spawn()
            .unwrap();
        session.children.push(niri);
        let mut socket = None;
        wait_until("niri's sockets", || {
            socket = std::fs::read_dir(session.path("run"))
                .unwrap()
                .flatten()
                .map(|e| e.path())
                .find(|p| p.extension().is_some_and(|e| e == "sock"));
            socket.is_some() && session.path("run/wayland-1").exists()
        });
        session.env.push((
            "NIRI_SOCKET".into(),
            socket.unwrap().to_str().unwrap().into(),
        ));
        session
            .env
            .push(("WAYLAND_DISPLAY".into(), "wayland-1".into()));

        let qs = session
            .command("qs")
            .arg("-p")
            .arg(&shell)
            .env("QT_QPA_PLATFORM", "wayland")
            // niri's headless backend has no renderer, so no dmabuf: shm buffers.
            .env("QT_QUICK_BACKEND", "software")
            .stdout(std::fs::File::create(session.path("qs.log")).unwrap())
            .stderr(std::fs::File::create(session.path("qs.err")).unwrap())
            .spawn()
            .unwrap();
        session.children.push(qs);
        wait_until("the bar's probe", || {
            session
                .try_state()
                .is_some_and(|s| s["pill"]["w"].as_f64() > Some(0.0))
        });
        Some(session)
    }

    /// Points the copy's `reviews`, `reviewTab` and `openUrl` at the stubs in `bin`,
    /// loads the reviews pill even on a host without work tooling, and gives it the probe.
    fn instrument(shell: &Path, bin: &Path) {
        let config = shell.join("Config.qml");
        let text = std::fs::read_to_string(&config).unwrap();
        let set = |decl: &str, value: String| {
            let line = text
                .lines()
                .find(|l| {
                    l.trim_start()
                        .starts_with(&format!("readonly property {decl}:"))
                })
                .unwrap_or_else(|| panic!("Config.qml has no `{decl}`"));
            splice(
                &config,
                line,
                &format!("    readonly property {decl}: {value}"),
            );
        };
        let stub = |name: &str| format!("\"{}\"", bin.join(name).display());
        set("string reviews", stub("reviews"));
        set("string reviewTab", stub("review-tab"));
        set("var openUrl", format!("[{}]", stub("open-url")));
        set("bool reviewsEnabled", "true".into());
        splice(
            &shell.join("popups/ReviewRequests.qml"),
            "    property string cursor: \"\"\n",
            "    property string cursor: \"\"\n    property alias probeQuery: find.query\n",
        );
        splice(
            &shell.join("bar/ReviewsPill.qml"),
            "    ReviewRequests {\n        id: panel\n",
            "    TestProbe {\n        pill: root\n        panel: panel\n    }\n\n    ReviewRequests {\n        id: panel\n",
        );
        std::fs::copy(
            Path::new(env!("CARGO_MANIFEST_DIR")).join("TestProbe.qml"),
            shell.join("bar/TestProbe.qml"),
        )
        .unwrap();
        splice(
            &shell.join("bar/Workspaces.qml"),
            "    spacing: 2\n",
            "    spacing: 2\n\n    WorkspacesProbe {\n        row: root\n    }\n",
        );
        std::fs::copy(
            Path::new(env!("CARGO_MANIFEST_DIR")).join("WorkspacesProbe.qml"),
            shell.join("bar/WorkspacesProbe.qml"),
        )
        .unwrap();
        splice(
            &shell.join("popups/StartMenu.qml"),
            "    property int cursor: -1\n",
            "    property int cursor: -1\n    property alias probeQuery: find.query\n    property alias probeList: list\n    property alias probeGrid: grid\n",
        );
        splice(
            &shell.join("bar/StartCorner.qml"),
            "    StartMenu {\n        id: menu\n",
            "    StartProbe {\n        menu: menu\n    }\n\n    StartMenu {\n        id: menu\n",
        );
        std::fs::copy(
            Path::new(env!("CARGO_MANIFEST_DIR")).join("StartProbe.qml"),
            shell.join("bar/StartProbe.qml"),
        )
        .unwrap();
    }

    pub fn path(&self, rel: &str) -> PathBuf {
        self.root.join(rel)
    }

    fn command(&self, bin: &str) -> Command {
        let mut cmd = Command::new(test_env().join("bin").join(bin));
        cmd.env_clear()
            .envs(self.env.iter().map(|(k, v)| (k, v)))
            .current_dir(&self.root);
        cmd.stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        cmd
    }

    fn try_state(&self) -> Option<Value> {
        let out = self
            .command("qs")
            .arg("-p")
            .arg(self.path("shell"))
            .args(["ipc", "call", "test", "state"])
            .stdout(Stdio::piped())
            .output()
            .ok()?;
        if !out.status.success() {
            return None;
        }
        serde_json::from_slice(&out.stdout).ok()
    }

    /// The probe's view of the bar: see TestProbe.qml.
    pub fn state(&self) -> Value {
        self.try_state()
            .unwrap_or_else(|| panic!("the probe did not answer\n{}", self.logs()))
    }

    /// The start menu's state: see StartProbe.qml.
    pub fn start_menu(&self) -> Value {
        let out = self
            .command("qs")
            .arg("-p")
            .arg(self.path("shell"))
            .args(["ipc", "call", "start", "state"])
            .stdout(Stdio::piped())
            .output()
            .unwrap();
        serde_json::from_slice(&out.stdout)
            .unwrap_or_else(|_| panic!("the start probe did not answer\n{}", self.logs()))
    }

    /// Waits for the start menu to reach a state, and returns it.
    pub fn wait_for_start(&self, what: &str, pred: impl Fn(&Value) -> bool) -> Value {
        let start = Instant::now();
        loop {
            let s = self.start_menu();
            if pred(&s) {
                return s;
            }
            assert!(
                start.elapsed() < TIMEOUT,
                "timed out waiting for {what}; last state {s}\n{}",
                self.logs()
            );
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    /// The workspace cells of the bar: see WorkspacesProbe.qml.
    pub fn workspace_cells(&self) -> Value {
        let out = self
            .command("qs")
            .arg("-p")
            .arg(self.path("shell"))
            .args(["ipc", "call", "workspaces", "cells"])
            .stdout(Stdio::piped())
            .output()
            .unwrap();
        serde_json::from_slice(&out.stdout)
            .unwrap_or_else(|_| panic!("the workspaces probe did not answer\n{}", self.logs()))
    }

    /// `niri msg --json` with these arguments, parsed.
    pub fn niri(&self, args: &[&str]) -> Value {
        let out = self
            .command("niri")
            .args(["msg", "--json"])
            .args(args)
            .stdout(Stdio::piped())
            .output()
            .unwrap();
        assert!(out.status.success(), "niri msg {args:?}\n{}", self.logs());
        serde_json::from_slice(&out.stdout).unwrap()
    }

    /// Runs a binary of the test env in the session, and returns its stdout.
    pub fn run(&self, bin: &str, args: &[&str]) -> String {
        let out = self
            .command(bin)
            .args(args)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{bin} {args:?}: {}\n{}",
            String::from_utf8_lossy(&out.stderr),
            self.logs()
        );
        String::from_utf8(out.stdout).unwrap()
    }

    /// Runs a binary of the test env in the session, and says whether it succeeded.
    pub fn succeeds(&self, bin: &str, args: &[&str]) -> bool {
        self.command(bin).args(args).status().unwrap().success()
    }

    /// Starts a binary of the test env for the rest of the session; its output
    /// goes to `<bin>.log`.
    pub fn spawn(&mut self, bin: &str, args: &[&str]) {
        let log = std::fs::File::create(self.path(&format!("{bin}.log"))).unwrap();
        let child = self
            .command(bin)
            .args(args)
            .env("PYTHONUNBUFFERED", "1")
            .stdout(log.try_clone().unwrap())
            .stderr(log)
            .spawn()
            .unwrap();
        self.children.push(child);
    }

    /// Opens a tiled window (app id `org.quickshell`) where niri puts new ones,
    /// and waits for niri to have it.
    pub fn open_window(&mut self) {
        let before = self.niri(&["windows"]).as_array().unwrap().len();
        let dir = self.path("window");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("shell.qml"),
            "import Quickshell\nFloatingWindow {\n    implicitWidth: 200\n    implicitHeight: 100\n}\n",
        )
        .unwrap();
        let child = self
            .command("qs")
            .arg("-p")
            .arg(&dir)
            .env("QT_QPA_PLATFORM", "wayland")
            .env("QT_QUICK_BACKEND", "software")
            .spawn()
            .unwrap();
        self.children.push(child);
        wait_until("the window to open", || {
            self.niri(&["windows"]).as_array().unwrap().len() > before
        });
    }

    /// Waits for the bar to reach a state, and returns it.
    pub fn wait_for(&self, what: &str, pred: impl Fn(&Value) -> bool) -> Value {
        let start = Instant::now();
        loop {
            let s = self.state();
            if pred(&s) {
                return s;
            }
            assert!(
                start.elapsed() < TIMEOUT,
                "timed out waiting for {what}; last state {s}\n{}",
                self.logs()
            );
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    /// Runs `wtype` with these arguments: a string to type, `-k KEY`, `-M MOD`...
    pub fn wtype(&self, args: &[&str]) {
        // A new virtual keyboard's keymap reaches the client with its first
        // key, which the client then drops: a release of nothing goes first.
        let status = self
            .command("wtype")
            .args(["-p", "Shift_L"])
            .args(args)
            .status()
            .unwrap();
        assert!(status.success(), "wtype {args:?}");
    }

    pub fn key(&self, key: &str) {
        self.wtype(&["-k", key]);
    }

    fn wlrctl(&self, args: &[&str]) {
        let status = self
            .command("wlrctl")
            .arg("pointer")
            .args(args)
            .status()
            .unwrap();
        assert!(status.success(), "wlrctl pointer {args:?}");
    }

    /// Puts the pointer at output coordinates: into the top-left corner,
    /// where niri clamps it, then the rest of the way.
    pub fn point_at(&self, x: f64, y: f64) {
        self.wlrctl(&["move", "-5000", "-5000"]);
        self.wlrctl(&[
            "move",
            &(x.round() as i64).to_string(),
            &(y.round() as i64).to_string(),
        ]);
    }

    pub fn click(&self) {
        self.wlrctl(&["click", "left"]);
    }

    pub fn right_click(&self) {
        self.wlrctl(&["click", "right"]);
    }

    /// Waits for a condition the caller checks itself.
    pub fn wait_until(&self, what: &str, ready: impl FnMut() -> bool) {
        wait_until(what, ready);
    }

    /// Puts the pointer on the reviews pill. The bar lays out again as late
    /// pills appear, so it aims until the pill reports the pointer.
    pub fn point_at_pill(&self) {
        let start = Instant::now();
        loop {
            let pill = &self.state()["pill"];
            let f = |k: &str| pill[k].as_f64().unwrap();
            self.point_at(f("x") + f("w") / 2.0, f("y") + f("h") / 2.0);
            let aimed = Instant::now();
            while aimed.elapsed() < Duration::from_millis(500) {
                if self.state()["hovered"] == true {
                    return;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            assert!(
                start.elapsed() < TIMEOUT,
                "the pointer never reached the pill\n{}",
                self.logs()
            );
        }
    }

    /// The lines a stub recorded, one per call.
    pub fn recorded(&self, log: &str) -> Vec<String> {
        std::fs::read_to_string(self.path(log))
            .map(|t| t.lines().map(str::to_owned).collect())
            .unwrap_or_default()
    }

    /// Waits for a stub to record exactly this one call.
    pub fn wait_for_record(&self, log: &str, line: &str) {
        wait_until(&format!("{log} to record {line:?}"), || {
            !self.recorded(log).is_empty()
        });
        assert_eq!(self.recorded(log), [line], "{}", self.logs());
    }

    pub fn logs(&self) -> String {
        let read = |f: &str| std::fs::read_to_string(self.path(f)).unwrap_or_default();
        let niri = read("niri.log");
        let lines: Vec<_> = niri.lines().collect();
        format!(
            "--- qs.log\n{}--- niri-workspaces.log\n{}--- niri.log (tail)\n{}",
            read("qs.log"),
            read("niri-workspaces.log"),
            lines[lines.len().saturating_sub(20)..].join("\n")
        )
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        for child in self.children.iter_mut().rev() {
            let _ = child.kill();
            let _ = child.wait();
        }
        if !std::thread::panicking() {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }
}
