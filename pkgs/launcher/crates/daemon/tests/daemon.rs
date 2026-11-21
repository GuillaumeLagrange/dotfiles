//! The daemon binary on a private headless sway, driven through its socket by `launcher query`
//! and `launcher activate`, as the panel drives it.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::Duration;

use serde_json::Value;

const BIN: &str = env!("CARGO_BIN_EXE_launcher");

fn write(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

fn wait_for(what: &str, mut ready: impl FnMut() -> bool) {
    while !ready() {
        eprintln!("waiting for {what}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

struct Fixture {
    root: tempfile::TempDir,
    sway: Child,
    daemon: Option<Child>,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        if let Some(daemon) = &mut self.daemon {
            let _ = daemon.kill();
            let _ = daemon.wait();
        }
        let _ = self.sway.kill();
        let _ = self.sway.wait();
    }
}

impl Fixture {
    fn path(&self, rel: &str) -> PathBuf {
        self.root.path().join(rel)
    }

    fn runtime(&self) -> PathBuf {
        self.path("run")
    }

    fn socket(&self) -> PathBuf {
        self.path("launcher.sock")
    }

    /// The environment the daemon and its clients run in: nothing of the host's session.
    fn command(&self, program: &str) -> Command {
        let mut cmd = Command::new(program);
        cmd.env_clear()
            .env("HOME", self.path("home"))
            .env("XDG_RUNTIME_DIR", self.runtime())
            .env("XDG_STATE_HOME", self.path("state"))
            .env("XDG_DATA_HOME", self.path("data"))
            .env("XDG_CACHE_HOME", self.path("cache"))
            .env("XDG_CONFIG_HOME", self.path("config"))
            .env("XDG_DATA_DIRS", self.path("share"))
            .env("WAYLAND_DISPLAY", "wayland-test")
            .env(
                "PATH",
                format!(
                    "{}:{}",
                    self.path("bin").display(),
                    std::env::var("PATH").unwrap()
                ),
            );
        cmd
    }

    fn start() -> Fixture {
        let root = tempfile::tempdir().unwrap();
        let path = |rel: &str| root.path().join(rel);
        std::fs::create_dir_all(path("run")).unwrap();
        std::fs::set_permissions(path("run"), std::fs::Permissions::from_mode(0o700)).unwrap();
        write(&path("sway.conf"), "output HEADLESS-1 resolution 800x600\n");
        let sway = Command::new("sway")
            .args(["-c", path("sway.conf").to_str().unwrap()])
            .env_clear()
            .env("HOME", path("home"))
            .env("XDG_RUNTIME_DIR", path("run"))
            .env("WAYLAND_DISPLAY", "wayland-test")
            .env("WLR_BACKENDS", "headless")
            .env("WLR_RENDERER", "pixman")
            .env("WLR_LIBINPUT_NO_DEVICES", "1")
            .env("PATH", std::env::var("PATH").unwrap())
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("sway on PATH");
        let fixture = Fixture {
            root,
            sway,
            daemon: None,
        };
        // sway creates its socket under its own name; the clients use the fixed one.
        let display = fixture.runtime().join("wayland-test");
        wait_for("sway", || {
            std::fs::read_dir(fixture.runtime())
                .unwrap()
                .flatten()
                .find(|e| {
                    let name = e.file_name().to_string_lossy().into_owned();
                    name.starts_with("wayland-") && !name.ends_with(".lock")
                })
                .is_some_and(|e| {
                    if e.path() != display {
                        let _ = std::os::unix::fs::symlink(e.path(), &display);
                    }
                    std::os::unix::net::UnixStream::connect(&display).is_ok()
                })
        });
        fixture
    }

    fn fixtures(&self) {
        write(
            &self.path("share/applications/firefox.desktop"),
            "[Desktop Entry]\nType=Application\nName=Firefox\nGenericName=Web Browser\nExec=fixture-browser %u\nIcon=firefox\n",
        );
        write(
            &self.path("share/applications/files.desktop"),
            "[Desktop Entry]\nType=Application\nName=Files\nExec=nautilus\n",
        );
        write(
            &self.path("emoji/emoji-test.txt"),
            "# group: Smileys & Emotion\n# subgroup: face-smiling\n\
             1F600 ; fully-qualified # 😀 E1.0 grinning face\n\
             1F604 ; fully-qualified # 😄 E0.6 grinning face with smiling eyes\n",
        );
        write(
            &self.path("emoji/en.xml"),
            "<ldml>\n<annotations>\n\
             <annotation cp=\"😀\">face | grin | happy</annotation>\n\
             <annotation cp=\"😀\" type=\"tts\">grinning face</annotation>\n\
             </annotations>\n</ldml>\n",
        );
        let config = serde_json::json!({
            "terminal": ["launcher-test-terminal"],
            "modes": {
                "apps": null,
                "emoji": {
                    "emoji_test": self.path("emoji/emoji-test.txt"),
                    "annotations": [self.path("emoji/en.xml")],
                },
                "clipboard": {"secret_clear_seconds": 30},
            },
        });
        write(&self.path("config.json"), &config.to_string());
        // What the panel's picks hand to niri, recorded.
        let niri = self.path("bin/niri");
        write(
            &niri,
            &format!(
                "#!/bin/sh\nprintf '%s\\n' \"$*\" >> {}\n",
                self.path("niri.log").display()
            ),
        );
        std::fs::set_permissions(&niri, std::fs::Permissions::from_mode(0o755)).unwrap();
        let browser = self.path("bin/fixture-browser");
        write(&browser, "#!/bin/sh\n");
        std::fs::set_permissions(&browser, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    fn start_daemon(&mut self) {
        let daemon = self
            .command(BIN)
            .args(["daemon", "--config"])
            .arg(self.path("config.json"))
            .arg("--socket")
            .arg(self.socket())
            .stdin(Stdio::null())
            .spawn()
            .unwrap();
        self.daemon = Some(daemon);
        let socket = self.socket();
        wait_for("the daemon's socket", || {
            std::os::unix::net::UnixStream::connect(&socket).is_ok()
        });
    }

    fn client(&self, args: &[&str]) -> Value {
        let out = self
            .command(BIN)
            .args(args)
            .arg("--socket")
            .arg(self.socket())
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        serde_json::from_slice(&out.stdout).unwrap()
    }

    /// The results of `query` in `mode`, once `until` holds for them.
    fn query_until(&self, mode: &str, query: &str, until: impl Fn(&Value) -> bool) -> Value {
        loop {
            let results = self.client(&["query", mode, query]);
            if until(&results) {
                return results;
            }
            eprintln!("waiting for {mode} results to settle: {results}");
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    fn paste(&self) -> String {
        let out = self
            .command("wl-paste")
            .arg("--no-newline")
            .output()
            .unwrap();
        String::from_utf8(out.stdout).unwrap()
    }
}

fn titles(results: &Value) -> Vec<String> {
    results["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["title"].as_str().unwrap().to_owned())
        .collect()
}

#[test]
fn the_daemon_serves_its_modes_end_to_end() {
    let mut f = Fixture::start();
    f.fixtures();
    f.start_daemon();

    let apps = f.query_until("apps", "fire", |r| {
        !r["items"].as_array().unwrap().is_empty()
    });
    assert_eq!(titles(&apps), ["Firefox"]);
    assert_eq!(apps["items"][0]["hl"], serde_json::json!([[0, 4]]));

    let reply = f.client(&["activate", "apps", "firefox.desktop"]);
    assert_eq!(reply["type"], "done");
    wait_for("the launch", || f.path("niri.log").exists());
    // Resolved on the daemon's PATH, so niri's own does not matter.
    assert_eq!(
        std::fs::read_to_string(f.path("niri.log")).unwrap().trim(),
        format!(
            "msg action spawn -- {}",
            f.path("bin/fixture-browser").display()
        )
    );

    let modes = f.client(&["query", "apps", "/e"]);
    assert_eq!(titles(&modes), ["Emoji"]);

    // An emoji pick lands on the clipboard and at the top of the history.
    let emoji = f.query_until("emoji", "happy", |r| {
        r["status"].is_null() && r["total"] == 1
    });
    assert_eq!(titles(&emoji), ["grinning face"]);
    let reply = f.client(&["activate", "emoji", "😀"]);
    assert_eq!(reply, serde_json::json!({"type": "done", "close": true}));
    assert_eq!(f.paste(), "😀");
    let history = f.query_until("clipboard", "", |r| r["total"] == 1);
    assert_eq!(titles(&history), ["😀"]);

    // What another client copies is recorded too, newest first, and a pick serves it again.
    let status = f
        .command("wl-copy")
        .arg("from another app")
        .status()
        .unwrap();
    assert!(status.success());
    let history = f.query_until("clipboard", "", |r| r["total"] == 2);
    assert_eq!(titles(&history), ["from another app", "😀"]);
    let id = history["items"][1]["id"].as_str().unwrap().to_owned();
    f.client(&["activate", "clipboard", &id]);
    assert_eq!(f.paste(), "😀");
}
