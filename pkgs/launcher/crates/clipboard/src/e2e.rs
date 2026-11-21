//! Against a private headless sway, driven with wl-copy and wl-paste.

use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};

use launcher_core::clipboard::{Offer, Sink};
use launcher_core::{Config, Ctx, Dirs, Outcome, Source};

use super::*;
use crate::store::tests::png;
use crate::wayland::PASSWORD_HINT;

struct Sway {
    child: Child,
    runtime: tempfile::TempDir,
    display: String,
}

impl Drop for Sway {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Sway {
    fn start() -> Sway {
        let runtime = tempfile::tempdir().unwrap();
        std::fs::set_permissions(runtime.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let config = runtime.path().join("sway.conf");
        std::fs::write(&config, "output * resolution 640x480\n").unwrap();
        let child = Command::new("sway")
            .arg("-c")
            .arg(&config)
            .env_clear()
            .env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .env("HOME", runtime.path())
            .env("XDG_RUNTIME_DIR", runtime.path())
            .env("WLR_BACKENDS", "headless")
            .env("WLR_RENDERER", "pixman")
            .env("WLR_LIBINPUT_NO_DEVICES", "1")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("sway must be on PATH");
        let mut sway = Sway {
            child,
            runtime,
            display: String::new(),
        };
        let dir = sway.runtime.path().to_owned();
        sway.display = wait(|| {
            std::fs::read_dir(&dir).unwrap().flatten().find_map(|e| {
                let name = e.file_name().to_string_lossy().into_owned();
                (name.starts_with("wayland-") && !name.ends_with(".lock")).then_some(name)
            })
        });
        let socket = sway.socket();
        wait(|| std::os::unix::net::UnixStream::connect(&socket).ok());
        sway
    }

    fn socket(&self) -> PathBuf {
        self.runtime.path().join(&self.display)
    }

    fn command(&self, program: &str) -> Command {
        let mut cmd = Command::new(program);
        cmd.env_clear()
            .env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .env("XDG_RUNTIME_DIR", self.runtime.path())
            .env("WAYLAND_DISPLAY", &self.display);
        cmd
    }

    fn copy(&self, args: &[&str], data: &[u8]) {
        let mut child = self
            .command("wl-copy")
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("wl-copy must be on PATH");
        child.stdin.take().unwrap().write_all(data).unwrap();
        assert!(child.wait().unwrap().success());
    }

    /// What wl-paste prints, None when it fails (nothing copied).
    fn paste(&self, args: &[&str]) -> Option<Vec<u8>> {
        let out = self
            .command("wl-paste")
            .arg("--no-newline")
            .args(args)
            .stderr(Stdio::null())
            .output()
            .expect("wl-paste must be on PATH");
        out.status.success().then_some(out.stdout)
    }

    fn paste_text(&self) -> Option<String> {
        self.paste(&[]).map(|b| String::from_utf8(b).unwrap())
    }
}

fn wait<T>(mut f: impl FnMut() -> Option<T>) -> T {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(v) = f() {
            return v;
        }
        assert!(Instant::now() < deadline, "timed out");
        std::thread::sleep(Duration::from_millis(20));
    }
}

struct Rig {
    sway: Sway,
    service: Service,
    ctx: Ctx,
    _root: tempfile::TempDir,
}

impl Rig {
    fn new(section: serde_json::Value) -> Rig {
        let sway = Sway::start();
        let root = tempfile::tempdir().unwrap();
        let config: Config =
            serde_json::from_value(serde_json::json!({ "modes": { "clipboard": section } }))
                .unwrap();
        let dirs = Dirs::under(&root.path().join("daemon")).unwrap();
        let (_tx, updater, _rx) = launcher_core::engine::channel();
        let service = start_on(Some(&sway.socket()), &config, &dirs, updater).unwrap();
        let (ctx, _) = Ctx::testing(&root.path().join("ctx"), config);
        Rig {
            sway,
            service,
            ctx,
            _root: root,
        }
    }

    fn source(&mut self) -> &mut Box<dyn Source> {
        self.service.source.as_mut().unwrap()
    }

    fn titles(&mut self) -> Vec<String> {
        self.source()
            .entries()
            .iter()
            .map(|e| e.title.clone())
            .collect()
    }

    fn wait_title(&mut self, title: &str) {
        wait(|| {
            self.titles()
                .first()
                .is_some_and(|t| t == title)
                .then_some(())
        });
    }

    fn id(&mut self, title: &str) -> String {
        let entries = self.source().entries();
        entries
            .iter()
            .find(|e| e.title == title)
            .unwrap()
            .id
            .clone()
    }

    fn pick(&mut self, title: &str) {
        let id = self.id(title);
        let ctx = self.ctx.clone();
        assert_eq!(self.source().activate(&id, "copy", &ctx), Outcome::Close);
    }
}

#[test]
fn copies_are_recorded_and_deduped_to_the_top() {
    let mut rig = Rig::new(serde_json::Value::Null);
    rig.sway.copy(&[], b"hello");
    rig.wait_title("hello");
    rig.sway.copy(&[], b"world");
    rig.wait_title("world");
    rig.sway.copy(&[], b"hello");
    rig.wait_title("hello");
    assert_eq!(rig.titles(), ["hello", "world"]);
}

#[test]
fn password_manager_copies_are_not_recorded() {
    let mut rig = Rig::new(serde_json::Value::Null);
    let limits = Limits {
        max_text_bytes: 1 << 20,
        max_image_bytes: 1 << 20,
        secret_clear: Duration::from_secs(60),
    };
    let manager = wayland::connect(&rig.sway.socket(), None, limits, false, None).unwrap();
    let offer = Offer {
        mimes: vec![
            ("text/plain".into(), Arc::from(&b"hunter2"[..])),
            (PASSWORD_HINT.into(), Arc::from(&b"secret"[..])),
        ],
    };
    WaylandSink(manager).copy(offer, false);
    assert_eq!(
        wait(|| rig.sway.paste_text().filter(|t| t == "hunter2")),
        "hunter2"
    );
    // The reader takes offers in order: once the next copy is in, the secret was seen.
    rig.sway.copy(&[], b"after");
    rig.wait_title("after");
    assert_eq!(rig.titles(), ["after"]);
}

#[test]
fn a_pick_sticks_every_time() {
    let mut rig = Rig::new(serde_json::Value::Null);
    rig.sway.copy(&[], b"first");
    rig.wait_title("first");
    rig.sway.copy(&[], b"second");
    rig.wait_title("second");
    for i in 0..20 {
        let title = if i % 2 == 0 { "first" } else { "second" };
        rig.pick(title);
        assert_eq!(rig.sway.paste_text().as_deref(), Some(title), "pick {i}");
        assert_eq!(rig.titles().len(), 2);
        assert_eq!(rig.titles()[0], title);
        std::thread::sleep(Duration::from_millis(50));
        assert_eq!(
            rig.sway.paste_text().as_deref(),
            Some(title),
            "pick {i}, later"
        );
    }
    // The panel side goes away; the daemon keeps serving.
    rig.service.source = None;
    std::thread::sleep(Duration::from_millis(100));
    assert_eq!(rig.sway.paste_text().as_deref(), Some("second"));
}

#[test]
fn an_image_round_trips() {
    let mut rig = Rig::new(serde_json::Value::Null);
    rig.sway.copy(&["--type", "image/png"], &png());
    rig.wait_title("Image 2×1 png");
    rig.sway.copy(&[], b"text");
    rig.wait_title("text");
    rig.pick("Image 2×1 png");
    let types = String::from_utf8(rig.sway.paste(&["--list-types"]).unwrap()).unwrap();
    assert!(types.lines().any(|t| t == "image/png"), "{types}");
    assert_eq!(rig.sway.paste(&["--type", "image/png"]).unwrap(), png());
    assert_eq!(rig.titles(), ["Image 2×1 png", "text"]);
}

#[test]
fn secrets_are_cleared_and_never_recorded() {
    let mut rig = Rig::new(serde_json::json!({ "secret_clear_seconds": 1 }));
    rig.service.clipboard.copy_secret("s3cret");
    assert_eq!(rig.sway.paste_text().as_deref(), Some("s3cret"));
    std::thread::sleep(Duration::from_millis(1500));
    assert_eq!(rig.sway.paste_text(), None);
    assert!(rig.titles().is_empty());

    // Unless the selection changed hands meanwhile.
    rig.service.clipboard.copy_secret("s3cret");
    rig.sway.copy(&[], b"mine");
    rig.wait_title("mine");
    std::thread::sleep(Duration::from_millis(1500));
    assert_eq!(rig.sway.paste_text().as_deref(), Some("mine"));
    assert_eq!(rig.titles(), ["mine"]);
}

#[test]
fn the_clipboard_works_without_the_history_mode() {
    let sway = Sway::start();
    let root = tempfile::tempdir().unwrap();
    let dirs = Dirs::under(root.path()).unwrap();
    let (_tx, updater, _rx) = launcher_core::engine::channel();
    let service = start_on(Some(&sway.socket()), &Config::default(), &dirs, updater).unwrap();
    assert!(service.source.is_none());
    service.clipboard.copy_text("plain");
    assert_eq!(sway.paste_text().as_deref(), Some("plain"));
}
