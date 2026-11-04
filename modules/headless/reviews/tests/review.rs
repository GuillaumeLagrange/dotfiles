//! `review.sh` end to end, headless: real git repos, a real wt registry and real
//! zellij sessions, in a throwaway machine of their own. The fixture's
//! `XDG_RUNTIME_DIR` gives zellij its own socket directory, so the tests' sessions
//! never meet the user's. What would reach the desktop is stubbed and recorded:
//! `zellij-attach` (focusing or opening a window), `notify-send`, and `gh`, whose
//! `pr checkout` switches to the branch the fixture registered for that PR.
//!
//! Skipped when zellij, wt, jq or script are missing, as in the nix build.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};

const URL: &str = "https://github.com/acme/app/pull/7";

struct Fixture {
    root: PathBuf,
    env: Vec<(String, String)>,
}

struct Run {
    status: i32,
    stderr: String,
    /// Its notifications so far: run without a terminal, failures land there.
    notified: String,
    /// The end of the shell trace.
    trace: String,
}

#[derive(Debug, Clone)]
struct Tab {
    name: String,
    id: u64,
    active: bool,
}

impl Tab {
    /// As wt matches a tab: the last word of its name, after mux-name's icon.
    fn is_for(&self, repo: &str) -> bool {
        self.name.split_whitespace().last() == Some(repo)
    }
}

fn have(tool: &str) -> bool {
    let found = Command::new("sh")
        .args(["-c", &format!("command -v {tool}")])
        .output()
        .is_ok_and(|o| o.status.success());
    if !found {
        eprintln!("skipped: `{tool}` is not on PATH");
    }
    found
}

fn tools() -> bool {
    ["zellij", "jq", "script", "git", "cargo"]
        .iter()
        .all(|t| have(t))
}

/// The dotfiles' own wt, built once per run: review relies on commands the
/// installed one may predate. Into a target dir of its own, since wt's suite runs
/// its binary from wt's while this one may be building.
static WT: std::sync::LazyLock<PathBuf> = std::sync::LazyLock::new(|| {
    let manifest = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../wt/Cargo.toml");
    let target = Path::new(env!("CARGO_MANIFEST_DIR")).join("target/wt");
    let out = Command::new("cargo")
        .args(["build", "--quiet", "--bin", "wt", "--manifest-path"])
        .arg(&manifest)
        .arg("--target-dir")
        .arg(&target)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "building wt: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    target.join("debug/wt")
});

fn write_exe(path: &Path, body: &str) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::write(path, format!("#!/bin/sh\n{body}")).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

impl Fixture {
    /// A workspace holding `app` and `lib`, each pushed to a bare `origin`; `app`
    /// also has `feature` there, the branch of PR 7.
    fn new() -> Self {
        static N: AtomicUsize = AtomicUsize::new(0);
        // Short: zellij's socket path has to fit in a sockaddr_un.
        let root = std::env::temp_dir().join(format!(
            "rv{}-{}",
            std::process::id(),
            N.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&root);
        let mut env = Vec::new();
        for (var, rel) in [
            ("HOME", "home"),
            ("XDG_CONFIG_HOME", "config"),
            ("XDG_STATE_HOME", "state"),
            ("XDG_CACHE_HOME", "cache"),
            ("XDG_DATA_HOME", "data"),
            ("XDG_RUNTIME_DIR", "run"),
            // zellij's log, which the machine's own sessions write to as well.
            ("TMPDIR", "tmp"),
        ] {
            let path = root.join(rel);
            std::fs::create_dir_all(&path).unwrap();
            env.push((var.to_owned(), path.display().to_string()));
        }

        let bin = root.join("bin");
        let log = root.join("log");
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::create_dir_all(&log).unwrap();
        let log_s = log.display();
        write_exe(
            &bin.join("zellij-attach"),
            &format!("echo \"$*\" >> {log_s}/attach\n"),
        );
        write_exe(
            &bin.join("notify-send"),
            &format!("echo \"$*\" >> {log_s}/notify\n"),
        );
        write_exe(
            &bin.join("gh"),
            &format!(
                "echo \"$*\" >> {log_s}/gh\n\
                 [ \"$1 $2\" = \"pr checkout\" ] || exit 1\n\
                 for a; do url=$a; done\n\
                 exec git switch -q \"$(cat {}/prs/${{url##*/}})\"\n",
                root.display()
            ),
        );
        let mux_name = Path::new(env!("CARGO_MANIFEST_DIR")).join("../mux-name.sh");
        write_exe(
            &bin.join("mux-name"),
            &format!("exec bash {} \"$@\"\n", mux_name.display()),
        );
        std::os::unix::fs::symlink(&*WT, bin.join("wt")).unwrap();

        // wt runs a repo's hooks through `$SHELL -i`. A real interactive shell
        // claims the terminal the tests run in, and is stopped for it (SIGTTOU)
        // since nextest puts each test in a process group of its own: the test
        // hangs. So `-i` is dropped and the rest runs non-interactively. `script`
        // runs its command through `$SHELL -c` as well.
        write_exe(
            &bin.join("shell"),
            "[ \"$1\" = -i ] && shift\nexec sh \"$@\"\n",
        );
        env.push(("SHELL".into(), bin.join("shell").display().to_string()));
        env.push((
            "PATH".into(),
            format!(
                "{}:{}",
                bin.display(),
                std::env::var("PATH").unwrap_or_default()
            ),
        ));
        for (var, value) in [
            ("GIT_CONFIG_GLOBAL", "/dev/null"),
            ("GIT_CONFIG_SYSTEM", "/dev/null"),
            ("GIT_AUTHOR_NAME", "t"),
            ("GIT_AUTHOR_EMAIL", "t@t.t"),
            ("GIT_COMMITTER_NAME", "t"),
            ("GIT_COMMITTER_EMAIL", "t@t.t"),
            // Submodules cloned from local paths, which git refuses by default.
            ("GIT_CONFIG_COUNT", "1"),
            ("GIT_CONFIG_KEY_0", "protocol.file.allow"),
            ("GIT_CONFIG_VALUE_0", "always"),
        ] {
            env.push((var.into(), value.into()));
        }

        let f = Fixture { root, env };
        // The real config and layout: what review drives in production.
        let dotfiles = Path::new(env!("CARGO_MANIFEST_DIR")).join("..");
        let zellij = f.root.join("config/zellij");
        std::fs::create_dir_all(zellij.join("layouts")).unwrap();
        std::fs::copy(dotfiles.join("zellij.kdl"), zellij.join("config.kdl")).unwrap();
        std::fs::copy(
            dotfiles.join("zellij-layout-guiom.kdl"),
            zellij.join("layouts/guiom.kdl"),
        )
        .unwrap();
        let ws = f.ws();
        f.write(
            "config/wt/config.toml",
            &format!(
                "workspace = \"{}\"\nmain_session = \"main\"\nrepos = [\"app\", \"lib\"]\n",
                ws.display()
            ),
        );
        f.write("prs/7", "feature");
        f.write("prs/8", "fix");

        for (repo, branch) in [("app", "feature"), ("lib", "fix")] {
            let dir = ws.join(repo);
            let remote = f.root.join(format!("remote-{repo}"));
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::create_dir_all(&remote).unwrap();
            f.git(&remote, &["init", "-q", "--bare", "-b", "main"]);
            f.git(&dir, &["init", "-q", "-b", "main"]);
            f.write(&format!("ws/{repo}/README.md"), "# readme\n");
            f.git(&dir, &["add", "-A"]);
            f.git(&dir, &["commit", "-qm", "init"]);
            f.git(
                &dir,
                &["remote", "add", "origin", &remote.display().to_string()],
            );
            f.git(&dir, &["push", "-q", "origin", "main"]);
            // Only on the remote, as a PR's branch is before its first checkout.
            f.git(&dir, &["switch", "-qc", branch]);
            f.git(&dir, &["commit", "-q", "--allow-empty", "-m", branch]);
            f.git(&dir, &["push", "-q", "origin", branch]);
            f.git(&dir, &["switch", "-q", "main"]);
            f.git(&dir, &["branch", "-qD", branch]);
            f.git(&dir, &["fetch", "-q", "origin"]);
        }
        f
    }

    /// Give `app` a submodule `sub` at its second commit, on `main` and
    /// `feature` alike; returns the submodule's two commits.
    fn add_submodule(&self) -> [String; 2] {
        let remote = self.root.join("remote-sub");
        let src = self.root.join("sub-src");
        std::fs::create_dir_all(&remote).unwrap();
        std::fs::create_dir_all(&src).unwrap();
        self.git(&remote, &["init", "-q", "--bare", "-b", "main"]);
        self.git(&src, &["init", "-q", "-b", "main"]);
        let mut commits = Vec::new();
        for n in ["one", "two"] {
            self.write(&format!("sub-src/{n}"), n);
            self.git(&src, &["add", "-A"]);
            self.git(&src, &["commit", "-qm", n]);
            commits.push(self.git(&src, &["rev-parse", "HEAD"]));
        }
        self.git(&src, &["push", "-q", &remote.display().to_string(), "main"]);

        let app = self.ws().join("app");
        self.git(
            &app,
            &[
                "submodule",
                "add",
                "-q",
                &remote.display().to_string(),
                "sub",
            ],
        );
        self.git(&app, &["commit", "-qm", "sub"]);
        self.git(&app, &["push", "-q", "origin", "main"]);
        self.git(&app, &["switch", "-qc", "feature", "origin/feature"]);
        self.git(&app, &["merge", "-q", "--no-edit", "main"]);
        self.git(&app, &["push", "-q", "origin", "feature"]);
        self.git(&app, &["switch", "-q", "main"]);
        self.git(&app, &["branch", "-qD", "feature"]);
        self.git(&app, &["fetch", "-q", "origin"]);
        commits.try_into().unwrap()
    }

    fn ws(&self) -> PathBuf {
        self.root.join("ws")
    }

    fn write(&self, rel: &str, contents: &str) {
        let path = self.root.join(rel);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, contents).unwrap();
    }

    fn command(&self, program: &str) -> Command {
        let mut cmd = Command::new(program);
        cmd.env_clear()
            .envs(self.env.iter().map(|(k, v)| (k, v)))
            .current_dir(&self.root)
            .stdin(Stdio::null());
        cmd
    }

    fn git(&self, dir: &Path, args: &[&str]) -> String {
        let out = self
            .command("git")
            .current_dir(dir)
            .args(args)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "git {args:?} in {}: {}",
            dir.display(),
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8_lossy(&out.stdout).trim().to_owned()
    }

    fn wt(&self, args: &[&str]) {
        let out = self
            .command("wt")
            .current_dir(self.ws())
            .args(args)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "wt {args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    /// `review` with its stderr not a terminal, as when run from the bar. Traced
    /// into `log/trace`, which a failure prints the end of.
    fn review(&self, args: &[&str]) -> Run {
        let script = Path::new(env!("CARGO_MANIFEST_DIR")).join("review.sh");
        let trace = self.root.join("log/trace");
        let out = self
            .command("bash")
            .arg("-c")
            .arg("exec 9>>\"$0\"; BASH_XTRACEFD=9 exec bash -xeuo pipefail \"$@\"")
            .arg(&trace)
            .arg(script)
            .args(args)
            .output()
            .unwrap();
        let trace = self.log("trace");
        let tail: Vec<&str> = trace.lines().rev().take(25).collect();
        Run {
            status: out.status.code().unwrap_or(-1),
            stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
            notified: self.log("notify"),
            trace: tail.into_iter().rev().collect::<Vec<_>>().join("\n"),
        }
    }

    fn zellij(&self, session: &str, args: &[&str]) -> String {
        let out = self
            .command("zellij")
            .args(["-s", session, "action"])
            .args(args)
            .output()
            .unwrap();
        String::from_utf8_lossy(&out.stdout).into_owned()
    }

    fn tabs(&self, session: &str) -> Vec<Tab> {
        // zellij answers with nothing until a just-attached client's screen is up.
        let mut out = String::new();
        for _ in 0..40 {
            out = self.zellij(session, &["list-tabs", "--json"]);
            if !out.trim().is_empty() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        let json: serde_json::Value = serde_json::from_str(&out)
            .unwrap_or_else(|e| panic!("tabs of {session}: {e}: {out:?}"));
        json.as_array()
            .unwrap()
            .iter()
            .map(|t| Tab {
                name: t["name"].as_str().unwrap().to_owned(),
                id: t["tab_id"].as_u64().unwrap(),
                active: t["active"].as_bool().unwrap(),
            })
            .collect()
    }

    /// `body` run while a client is attached, as a user's window would be;
    /// with the tabs as that client sees them once one is active for it.
    fn attached<T>(&self, session: &str, body: impl FnOnce(&[Tab]) -> T) -> T {
        let spawn = || {
            self.command("script")
                .args([
                    "-q",
                    "-c",
                    &format!("stty rows 50 cols 160; exec zellij attach {session}"),
                    "/dev/null",
                ])
                .env("TERM", "xterm-256color")
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap()
        };
        let mut client = spawn();
        let mut tabs = Vec::new();
        for _ in 0..50 {
            std::thread::sleep(std::time::Duration::from_millis(100));
            // A server still loading its plugins can drop a client the moment it
            // arrives ("lost connection"), and a user would attach again.
            if matches!(client.try_wait(), Ok(Some(_))) {
                client = spawn();
                continue;
            }
            tabs = self.tabs(session);
            if tabs.iter().any(|t| t.active) {
                break;
            }
        }
        let out = body(&tabs);
        let _ = client.kill();
        let _ = client.wait();
        out
    }

    /// The tabs as a client attaching now sees them, which is what the stubbed
    /// `zellij-attach` would show: a tab is only active for a client.
    fn tabs_seen(&self, session: &str) -> Vec<Tab> {
        self.attached(session, |tabs| tabs.iter().map(Tab::clone).collect())
    }

    /// Working directories of a tab's terminal panes.
    fn cwds(&self, session: &str, tab: u64) -> Vec<String> {
        let json: serde_json::Value =
            serde_json::from_str(&self.zellij(session, &["list-panes", "--json"])).unwrap();
        json.as_array()
            .unwrap()
            .iter()
            .filter(|p| p["is_plugin"] == false && p["tab_id"] == tab)
            .filter_map(|p| p["pane_cwd"].as_str().map(str::to_owned))
            .collect()
    }

    fn log(&self, name: &str) -> String {
        std::fs::read_to_string(self.root.join("log").join(name)).unwrap_or_default()
    }

    fn branch(&self, dir: &Path) -> String {
        self.git(dir, &["branch", "--show-current"])
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self
            .command("zellij")
            .args(["kill-all-sessions", "--yes"])
            .output();
        let _ = self
            .command("zellij")
            .args(["delete-all-sessions", "--yes", "--force"])
            .output();
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[track_caller]
fn assert_ok(run: &Run) {
    assert_eq!(
        run.status, 0,
        "review failed: {}{}\n--- trace ---\n{}",
        run.stderr, run.notified, run.trace
    );
}

#[test]
fn mine_goes_to_the_wt_session_holding_the_branch() {
    if !tools() {
        return;
    }
    let f = Fixture::new();
    f.wt(&["new", "feat", "--repo", "app", "--repo", "lib"]);
    let worktree = f.ws().join("sessions/feat/app");
    f.git(&worktree, &["switch", "-q", "feature"]);

    assert_ok(&f.review(&["--mine", URL, "feature"]));

    let tabs = f.tabs_seen("feat");
    let app: Vec<_> = tabs.iter().filter(|t| t.is_for("app")).collect();
    assert_eq!(app.len(), 1, "one app tab, laid out by wt: {tabs:?}");
    assert!(app[0].active, "the app tab is selected: {tabs:?}");
    assert_eq!(f.log("attach"), "--focus feat\n");
    assert_eq!(f.log("gh"), "", "nothing is checked out");
    assert_eq!(
        f.branch(&f.ws().join("app")),
        "main",
        "the main checkout is untouched"
    );
}

#[test]
fn mine_opens_the_repo_tab_a_wt_session_lacks() {
    if !tools() {
        return;
    }
    let f = Fixture::new();
    f.wt(&["new", "feat", "--repo", "app", "--repo", "lib"]);
    let worktree = f.ws().join("sessions/feat/app");
    f.git(&worktree, &["switch", "-q", "feature"]);
    assert_ok(&f.review(&["--mine", URL, "feature"]));
    // Closed from a window, as a user would.
    f.attached("feat", |tabs| {
        let app = tabs.iter().find(|t| t.is_for("app")).unwrap();
        f.zellij("feat", &["close-tab-by-id", &app.id.to_string()]);
    });

    assert_ok(&f.review(&["--mine", URL, "feature"]));

    let tabs = f.tabs_seen("feat");
    let app = tabs
        .iter()
        .find(|t| t.is_for("app"))
        .unwrap_or_else(|| panic!("{tabs:?}"));
    assert!(app.active, "{tabs:?}");
    assert!(
        tabs.iter().any(|t| t.is_for("lib")),
        "the other member's tab stays: {tabs:?}"
    );
    assert_eq!(f.cwds("feat", app.id), [worktree.display().to_string()]);
}

#[test]
fn mine_checks_the_branch_out_in_the_main_session() {
    if !tools() {
        return;
    }
    let f = Fixture::new();

    assert_ok(&f.review(&["--mine", URL, "feature"]));

    let app = f.ws().join("app");
    assert_eq!(f.branch(&app), "feature");
    let tabs = f.tabs_seen("main");
    assert_eq!(
        tabs.len(),
        1,
        "the fresh session's startup tab is replaced: {tabs:?}"
    );
    assert!(tabs[0].is_for("app") && tabs[0].active, "{tabs:?}");
    assert_eq!(f.cwds("main", tabs[0].id), [app.display().to_string()]);
    assert_eq!(f.log("attach"), "--focus main\n");
    assert_eq!(f.log("notify"), "");
}

#[test]
fn mine_reuses_the_main_session_tab() {
    if !tools() {
        return;
    }
    let f = Fixture::new();
    assert_ok(&f.review(&["--mine", URL, "feature"]));
    assert_ok(&f.review(&["--mine", "https://github.com/acme/lib/pull/8", "fix"]));
    assert!(f
        .tabs_seen("main")
        .iter()
        .any(|t| t.is_for("lib") && t.active));

    assert_ok(&f.review(&["--mine", URL, "feature"]));

    let tabs = f.tabs_seen("main");
    assert_eq!(tabs.len(), 2, "{tabs:?}");
    assert!(tabs.iter().any(|t| t.is_for("app") && t.active), "{tabs:?}");
    assert_eq!(f.branch(&f.ws().join("lib")), "fix");
}

#[test]
fn mine_leaves_a_dirty_checkout_alone() {
    if !tools() {
        return;
    }
    let f = Fixture::new();
    f.write("ws/app/README.md", "# edited\n");

    assert_ok(&f.review(&["--mine", URL, "feature"]));

    assert_eq!(f.branch(&f.ws().join("app")), "main");
    assert_eq!(f.log("gh"), "");
    assert!(
        f.log("notify").contains("uncommitted changes"),
        "{}",
        f.log("notify")
    );
    assert_eq!(
        std::fs::read_to_string(f.ws().join("app/README.md")).unwrap(),
        "# edited\n"
    );
    let tabs = f.tabs_seen("main");
    assert!(
        tabs.iter().any(|t| t.is_for("app") && t.active),
        "the tab still opens: {tabs:?}"
    );
}

#[test]
fn pr_opens_its_tab_in_the_reviews_session() {
    if !tools() {
        return;
    }
    let f = Fixture::new();
    f.wt(&["new", "reviews", "--repo", "app"]);

    assert_ok(&f.review(&["--pr", URL]));

    let tabs = f.tabs("reviews");
    assert_eq!(
        tabs.len(),
        1,
        "the fresh session's startup tab is the PR's: {tabs:?}"
    );
    assert_eq!(tabs[0].name, "app#7");
    assert_eq!(f.log("attach"), "--focus reviews\n");
}

#[test]
fn mine_fails_when_zellij_cannot_start_the_session() {
    if !tools() {
        return;
    }
    let f = Fixture::new();
    // A name zellij refuses to start a session under.
    let ws = f.ws().display().to_string();
    f.write(
        "config/wt/config.toml",
        &format!("workspace = \"{ws}\"\nmain_session = \"no/such\"\n"),
    );

    let run = f.review(&["--mine", URL, "feature"]);

    assert_ne!(run.status, 0);
    assert!(
        f.log("notify").contains("could not start"),
        "{}",
        f.log("notify")
    );
    assert_eq!(
        f.log("attach"),
        "",
        "no window on a session review could not lay out"
    );
}

#[test]
fn mine_checks_out_over_a_submodule_at_another_commit() {
    if !tools() {
        return;
    }
    let f = Fixture::new();
    let [one, two] = f.add_submodule();
    let sub = f.ws().join("app/sub");
    // What `git submodule update` fixes: the submodule moved, nothing edited.
    f.git(&sub, &["checkout", "-q", &one]);

    assert_ok(&f.review(&["--mine", URL, "feature"]));

    assert_eq!(f.log("notify"), "");
    assert_eq!(f.branch(&f.ws().join("app")), "feature");
    assert_eq!(
        f.git(&sub, &["rev-parse", "HEAD"]),
        two,
        "the submodule is updated"
    );
}

#[test]
fn mine_leaves_edits_inside_a_submodule_alone() {
    if !tools() {
        return;
    }
    let f = Fixture::new();
    f.add_submodule();
    f.write("ws/app/sub/one", "edited");

    assert_ok(&f.review(&["--mine", URL, "feature"]));

    assert_eq!(f.branch(&f.ws().join("app")), "main");
    assert!(
        f.log("notify").contains("uncommitted changes"),
        "{}",
        f.log("notify")
    );
    assert_eq!(
        std::fs::read_to_string(f.ws().join("app/sub/one")).unwrap(),
        "edited"
    );
}
