//! A temp root with stub programs first on PATH, each recording its argv under `log/`.
//! Sets process-wide env vars: run under nextest, one process per test.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use launcher_core::testing::Handles;
use launcher_core::{Config, Ctx, Mode};

const NIRI: &str = r#"#!/bin/sh
# niri msg action spawn -- ARGV...
[ "$1 $2 $3 $4" = "msg action spawn --" ] || exit 1
shift 4
echo "$*" >> "$STUB_LOG/spawned"
"#;

pub struct Fixture {
    pub dir: tempfile::TempDir,
    pub ctx: Ctx,
    pub handles: Handles,
}

impl Fixture {
    pub fn new(modes: &[Mode]) -> Fixture {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        for sub in ["bin", "log", "config", "state"] {
            std::fs::create_dir_all(root.join(sub)).unwrap();
        }
        let path = format!(
            "{}:{}",
            root.join("bin").display(),
            std::env::var("PATH").unwrap_or_default()
        );
        std::env::set_var("PATH", path);
        std::env::set_var("STUB_LOG", root.join("log"));
        std::env::set_var("XDG_CONFIG_HOME", root.join("config"));
        std::env::set_var("XDG_STATE_HOME", root.join("state"));
        let (ctx, handles) = Ctx::testing(&root.join("launcher"), Config::with_modes(modes));
        let fx = Fixture { dir, ctx, handles };
        fx.stub("niri", NIRI);
        fx
    }

    pub fn root(&self) -> &Path {
        self.dir.path()
    }

    pub fn write(&self, rel: &str, text: &str) -> PathBuf {
        let path = self.root().join(rel);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, text).unwrap();
        path
    }

    pub fn stub(&self, name: &str, script: &str) {
        let path = self.write(&format!("bin/{name}"), script);
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    /// The lines a stub recorded.
    pub fn log(&self, name: &str) -> Vec<String> {
        std::fs::read_to_string(self.root().join("log").join(name))
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    /// The argv handed to `niri msg action spawn --`, joined by spaces, with the program the
    /// daemon resolved on PATH named as it was asked.
    pub fn spawned(&self) -> Vec<String> {
        self.log("spawned")
            .into_iter()
            .map(|line| match line.split_once(' ') {
                Some((program, rest)) => format!("{} {rest}", unresolve(program)),
                None => unresolve(&line),
            })
            .collect()
    }

    /// Waits for `n` spawns; a spawn that never comes is nextest's timeout.
    pub fn wait_spawned(&self, n: usize) -> Vec<String> {
        loop {
            let spawned = self.spawned();
            if spawned.len() >= n {
                return spawned;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }
}

/// `path`'s file name when that name resolves to `path` on PATH.
fn unresolve(path: &str) -> String {
    let Some(name) = Path::new(path).file_name().and_then(|n| n.to_str()) else {
        return path.to_owned();
    };
    let on_path = std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default())
        .map(|dir| dir.join(name))
        .find(|p| p.is_file());
    if on_path.is_some_and(|p| p == Path::new(path)) {
        name.to_owned()
    } else {
        path.to_owned()
    }
}
