#![allow(dead_code)] // each test binary uses a different part of this

//! A throwaway machine for one test: its own workspace of git repos, its own XDG
//! directories, its own registry. Nothing here reads or writes anything belonging to
//! the user running the tests, so the tests are safe to run in parallel and safe to
//! run on a machine with real sessions.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;

pub struct Fixture {
    /// Kept alive for the fixture's lifetime: dropping it removes everything.
    _dir: tempfile::TempDir,
    pub root: PathBuf,
    pub workspace: PathBuf,
    env: HashMap<String, String>,
}

/// The result of running `wt`, with enough context to make a failure readable.
pub struct Run {
    pub args: Vec<String>,
    pub status: i32,
    pub stdout: String,
    pub stderr: String,
}

impl Run {
    /// Assert it succeeded, and return it for further assertions.
    pub fn ok(self) -> Self {
        assert_eq!(self.status, 0, "expected success from {self}");
        self
    }

    /// Assert it failed, saying what it should have complained about.
    pub fn failed_with(self, needle: &str) -> Self {
        assert_ne!(self.status, 0, "expected a failure from {self}");
        assert!(
            self.stderr.contains(needle) || self.stdout.contains(needle),
            "expected `{needle}` from {self}"
        );
        self
    }

    pub fn says(self, needle: &str) -> Self {
        assert!(
            self.stdout.contains(needle),
            "expected `{needle}` from {self}"
        );
        self
    }

    pub fn silent_about(self, needle: &str) -> Self {
        assert!(
            !self.stdout.contains(needle),
            "did not expect `{needle}` from {self}"
        );
        self
    }

    pub fn line(&self) -> &str {
        self.stdout.trim()
    }
}

impl std::fmt::Display for Run {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "`wt {}` (exit {})\n--- stdout ---\n{}--- stderr ---\n{}",
            self.args.join(" "),
            self.status,
            self.stdout,
            self.stderr
        )
    }
}

impl Fixture {
    /// A workspace of three repos, each with a different main branch, plus the
    /// non-repo entries a mirror has to reproduce.
    ///
    /// `lib` has a remote whose tip its local branch lacks, so where a worktree
    /// forks from is observable.
    pub fn new() -> Self {
        let dir = tempfile::Builder::new()
            .prefix("wt-test")
            .tempdir()
            .expect("temp dir");
        let root = dir.path().to_path_buf();
        let workspace = root.join("ws");

        let mut env = HashMap::new();
        for (var, rel) in [
            ("HOME", "home"),
            ("XDG_STATE_HOME", "state"),
            ("XDG_CONFIG_HOME", "config"),
            ("XDG_CACHE_HOME", "cache"),
            ("XDG_DATA_HOME", "data"),
            // zellij's sockets live here, and its session metadata in the cache:
            // redirecting both is what keeps a test's sessions out of the way of the
            // machine's own.
            ("XDG_RUNTIME_DIR", "run"),
        ] {
            let path = root.join(rel);
            std::fs::create_dir_all(&path).expect("xdg dir");
            env.insert(var.to_string(), path.display().to_string());
        }

        let mut fixture = Self {
            _dir: dir,
            root,
            workspace,
            env,
        };
        // wt runs a repo's post-checkout hook through `$SHELL -i`, so that the hook
        // sees the toolchain a shell's per-directory hooks install. A test must not
        // reach for a real interactive shell for that: it would load the rc file of
        // whoever is running the tests, and take the terminal with it — an
        // interactive shell claims the tty, which suspends the run.
        let shell = fixture.stub_shell("shell", "");
        fixture.env.insert("SHELL".into(), shell);
        fixture.build_workspace();
        fixture
    }

    /// A stand-in for `$SHELL -i`: it drops the `-i` and runs the rest
    /// non-interactively, exporting whatever an rc file is meant to have exported.
    pub fn stub_shell(&self, name: &str, exports: &str) -> String {
        let path = self.root.join(name);
        std::fs::write(&path, format!("#!/bin/sh\n{exports}shift   # -i\nexec sh \"$@\"\n")).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path.display().to_string()
    }

    fn build_workspace(&self) {
        std::fs::create_dir_all(self.workspace.join("other")).unwrap();
        std::fs::create_dir_all(self.workspace.join("flake")).unwrap();
        // Stands in for `use flake ./flake`: something direnv can actually load, so
        // the session's own .envrc can be checked end to end.
        self.write(".envrc", "export FROM_WORKSPACE=1\n");
        self.write(".gitignore", "ignored-by-name\n");

        for repo in ["app", "docs", "lib"] {
            let path = self.workspace.join(repo);
            std::fs::create_dir_all(&path).unwrap();
            self.git(repo, &["init", "-q", "-b", "main"]);
            self.write(
                &format!("{repo}/.gitignore"),
                "node_modules/\n.envrc\n.env\ntarget/\nlocal.mk\nSession.vim\n",
            );
            self.write(&format!("{repo}/README.md"), &format!("# {repo}\n"));
            self.git(repo, &["add", "-A"]);
            self.git(repo, &["commit", "-qm", "init"]);

            // Git-ignored, so `git worktree add` brings none of it.
            self.write(&format!("{repo}/.env"), "SECRET=1\n");
            self.write(&format!("{repo}/local.mk"), "PREFIX=/usr/local\n");
            // State that names the checkout it was written in: hydration must not
            // carry it, whatever the pattern list says about its neighbours.
            self.write(
                &format!("{repo}/Session.vim"),
                &format!("cd {}/{repo}\n", self.workspace.display()),
            );
            std::fs::create_dir_all(path.join("node_modules/pkg")).unwrap();
            self.write(&format!("{repo}/node_modules/pkg/index.js"), "x\n");
            // `app` reaches its parent, the others do not: hydration copies both as
            // they stand, so a member behaves as it does in the main checkout.
            let envrc = if repo == "app" {
                "source_env ../.envrc\nexport FROM_MAIN=1\n"
            } else {
                "export FROM_MAIN=1\n"
            };
            self.write(&format!("{repo}/.envrc"), envrc);
        }

        self.git("app", &["branch", "-qm", "staging"]);
        self.git("docs", &["branch", "-qm", "master"]);

        let remote = self.root.join("remote-lib");
        std::fs::create_dir_all(&remote).unwrap();
        self.run_git(&remote, &["init", "-q", "--bare", "-b", "main"]);
        let remote = remote.display().to_string();
        self.git("lib", &["remote", "add", "origin", &remote]);
        self.git("lib", &["push", "-q", "origin", "main"]);
        self.git("lib", &["fetch", "-q", "origin"]);
        self.git("lib", &["remote", "set-head", "origin", "main"]);
        // A commit only the remote has.
        self.git("lib", &["switch", "-q", "--detach", "origin/main"]);
        self.write("lib/REMOTE.md", "remote-only\n");
        self.git("lib", &["add", "REMOTE.md"]);
        self.git("lib", &["commit", "-qm", "remote-only"]);
        self.git("lib", &["push", "-q", "origin", "HEAD:main"]);
        self.git("lib", &["switch", "-q", "main"]);
        self.git("lib", &["fetch", "-q", "origin"]);

        self.configure(&["app", "lib"], None);
    }

    /// Write `~/.config/wt/config.toml`, which is the only way wt learns anything
    /// about a workspace.
    pub fn configure(&self, repos: &[&str], hydrate: Option<&[&str]>) {
        let dir = PathBuf::from(&self.env["XDG_CONFIG_HOME"]).join("wt");
        std::fs::create_dir_all(&dir).unwrap();
        let list = |items: &[&str]| {
            items
                .iter()
                .map(|r| format!("\"{r}\""))
                .collect::<Vec<_>>()
                .join(", ")
        };
        let mut out = format!(
            "workspace = \"{}\"\nrepos = [{}]\n",
            self.workspace.display(),
            list(repos)
        );
        if let Some(hydrate) = hydrate {
            out.push_str(&format!("hydrate = [{}]\n", list(hydrate)));
        }
        std::fs::write(dir.join("config.toml"), out).unwrap();
    }

    /// Replace the config wholesale, for the cases that are about the file itself.
    pub fn write_config(&self, contents: &str) {
        let dir = PathBuf::from(&self.env["XDG_CONFIG_HOME"]).join("wt");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("config.toml"), contents).unwrap();
    }

    pub fn wt(&self, args: &[&str]) -> Run {
        self.wt_with(args, &[])
    }

    /// `wt` with extra environment, for the few behaviours that depend on it.
    pub fn wt_with(&self, args: &[&str], extra: &[(&str, &str)]) -> Run {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_wt"));
        cmd.args(args)
            .current_dir(&self.workspace)
            .env_clear()
            .stdin(std::process::Stdio::null());
        // PATH decides which git, direnv and zellij are found: the test's own.
        cmd.env("PATH", std::env::var("PATH").unwrap_or_default());
        for (var, value) in &self.env {
            cmd.env(var, value);
        }
        for (var, value) in extra {
            cmd.env(var, value);
        }
        let out = cmd.output().expect("wt should run");
        Run {
            args: args.iter().map(|a| a.to_string()).collect(),
            status: out.status.code().unwrap_or(-1),
            stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        }
    }

    pub fn session(&self, id: &str) -> PathBuf {
        self.workspace.join("sessions").join(id)
    }

    pub fn path(&self, rel: &str) -> PathBuf {
        self.workspace.join(rel)
    }

    pub fn write(&self, rel: &str, contents: &str) {
        let path = self.workspace.join(rel);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, contents).unwrap();
    }

    pub fn read(&self, path: &Path) -> String {
        std::fs::read_to_string(path)
            .unwrap_or_else(|e| panic!("could not read {}: {e}", path.display()))
    }

    /// A repo in the workspace, as a clone would be: used to check that nothing in a
    /// session ever reached the main checkout.
    pub fn git(&self, repo: &str, args: &[&str]) -> String {
        let dir = self.workspace.join(repo);
        self.run_git(&dir, args)
    }

    pub fn git_in(&self, dir: &Path, args: &[&str]) -> String {
        self.run_git(dir, args)
    }

    fn run_git(&self, dir: &Path, args: &[&str]) -> String {
        let out = Command::new("git")
            .args(args)
            .current_dir(dir)
            .env("HOME", &self.env["HOME"])
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_SYSTEM", "/dev/null")
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@t.t")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@t.t")
            .env("PATH", std::env::var("PATH").unwrap_or_default())
            .output()
            .expect("git should run");
        assert!(
            out.status.success(),
            "`git {}` in {} failed: {}",
            args.join(" "),
            dir.display(),
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    }

    pub fn env_var(&self, name: &str) -> &str {
        &self.env[name]
    }
}

/// Skip a test that needs a tool the machine may not have, saying so rather than
/// passing quietly.
pub fn have(tool: &str) -> bool {
    let found = Command::new("sh")
        .args(["-c", &format!("command -v {tool}")])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);
    if !found {
        eprintln!("skipped: `{tool}` is not on PATH");
    }
    found
}
