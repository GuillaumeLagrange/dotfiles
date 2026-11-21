use std::fs;
use std::io::{BufRead, BufReader};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

use launcher_core::matcher::{rank, Prepared};
use launcher_core::testing::Handles;
use launcher_core::{Config, Ctx, Icon, Mode, Outcome, Source, StatusKind};
use rusqlite::{params, Connection};
use tempfile::TempDir;

use super::{Browser, Bus};

type Row = (i32, i32, String, String, i32, bool, bool, String);

#[allow(clippy::too_many_arguments)]
fn row(
    window: i32,
    id: i32,
    title: &str,
    url: &str,
    index: i32,
    active: bool,
    pinned: bool,
    icon: &str,
) -> Row {
    (
        window,
        id,
        title.into(),
        url.into(),
        index,
        active,
        pinned,
        icon.into(),
    )
}

/// A private bus, killed on drop.
struct DBus {
    child: Child,
    address: String,
}

impl DBus {
    fn start(dir: &Path) -> DBus {
        let config = dir.join("bus.conf");
        fs::write(
            &config,
            format!(
                r#"<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:path={}</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>"#,
                dir.join("bus.sock").display()
            ),
        )
        .unwrap();
        let mut child = Command::new("dbus-daemon")
            .arg(format!("--config-file={}", config.display()))
            .args(["--nofork", "--print-address"])
            .stdout(Stdio::piped())
            .spawn()
            .expect("dbus-daemon is needed for the TabCtl tests");
        let mut address = String::new();
        BufReader::new(child.stdout.take().unwrap())
            .read_line(&mut address)
            .unwrap();
        DBus {
            child,
            address: address.trim().to_owned(),
        }
    }

    fn bus(&self) -> Bus {
        Bus::Address(self.address.clone())
    }
}

impl Drop for DBus {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[derive(Clone, Default)]
struct Fake {
    tabs: Arc<Mutex<Vec<Row>>>,
    calls: Arc<Mutex<Vec<String>>>,
}

#[zbus::interface(name = "dev.slastra.TabCtl.Browser")]
impl Fake {
    fn list_tabs_with_icons(&self) -> Vec<Row> {
        self.tabs.lock().unwrap().clone()
    }

    fn list_tabs(&self) -> Vec<(i32, i32, String, String, i32, bool, bool)> {
        self.tabs
            .lock()
            .unwrap()
            .iter()
            .map(|t| (t.0, t.1, t.2.clone(), t.3.clone(), t.4, t.5, t.6))
            .collect()
    }

    fn activate_tab(&self, tab_id: i32, focused: bool) {
        self.calls
            .lock()
            .unwrap()
            .push(format!("ActivateTab({tab_id}, {focused})"));
    }

    fn close_tabs(&self, ids: Vec<i32>) {
        self.calls
            .lock()
            .unwrap()
            .push(format!("CloseTabs({ids:?})"));
    }
}

/// A TabCtl instance (`dev.slastra.TabCtl.<instance>`) on the private bus.
struct Service {
    fake: Fake,
    conn: zbus::blocking::Connection,
    path: String,
}

impl Service {
    fn start(bus: &DBus, instance: &str, tabs: Vec<Row>) -> Service {
        let fake = Fake::default();
        *fake.tabs.lock().unwrap() = tabs;
        let path = format!("/dev/slastra/TabCtl/Browser/{instance}");
        let conn = zbus::blocking::connection::Builder::address(bus.address.as_str())
            .unwrap()
            .name(format!("dev.slastra.TabCtl.{instance}"))
            .unwrap()
            .serve_at(path.as_str(), fake.clone())
            .unwrap()
            .build()
            .unwrap();
        Service { fake, conn, path }
    }

    fn set_tabs(&self, tabs: Vec<Row>) {
        *self.fake.tabs.lock().unwrap() = tabs;
        self.conn
            .emit_signal(
                None::<&str>,
                self.path.as_str(),
                "dev.slastra.TabCtl.Browser",
                "TabsUpdated",
                &(),
            )
            .unwrap();
    }

    fn calls(&self) -> Vec<String> {
        self.fake.calls.lock().unwrap().clone()
    }
}

/// A temp root with a stub `niri` on PATH that records its arguments and answers
/// `msg --json windows` with `windows.json`.
struct Env {
    dir: TempDir,
}

impl Env {
    fn new() -> Env {
        let dir = TempDir::new().unwrap();
        let bin = dir.path().join("bin");
        fs::create_dir(&bin).unwrap();
        let niri = bin.join("niri");
        fs::write(
            &niri,
            format!(
                "#!/bin/sh\necho \"$*\" >> '{0}/niri.log'\nif [ \"$*\" = 'msg --json windows' ]; then cat '{0}/windows.json' 2>/dev/null || echo '[]'; fi\n",
                dir.path().display()
            ),
        )
        .unwrap();
        fs::set_permissions(&niri, fs::Permissions::from_mode(0o755)).unwrap();
        // nextest runs each test in its own process.
        std::env::set_var(
            "PATH",
            format!(
                "{}:{}",
                bin.display(),
                std::env::var("PATH").unwrap_or_default()
            ),
        );
        Env { dir }
    }

    fn path(&self) -> &Path {
        self.dir.path()
    }

    fn windows(&self, json: &str) {
        fs::write(self.path().join("windows.json"), json).unwrap();
    }

    fn niri_calls(&self) -> Vec<String> {
        fs::read_to_string(self.path().join("niri.log"))
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    fn ctx(&self, inis: &[PathBuf]) -> (Ctx, Handles) {
        let mut config = Config::with_modes(&[Mode::Browser]);
        config.modes.insert(
            Mode::Browser,
            serde_json::json!({"profiles_ini": inis, "firefox": "/opt/firefox"}),
        );
        Ctx::testing(&self.path().join("root"), config)
    }
}

fn wait(handles: &Handles, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !done() {
        assert!(Instant::now() < deadline, "timed out");
        handles.wait_updated(Mode::Browser, Duration::from_millis(50));
    }
}

fn ids(source: &Browser) -> Vec<String> {
    source.entries().iter().map(|e| e.id.clone()).collect()
}

fn fixture_tabs() -> Vec<Row> {
    vec![
        row(
            1,
            12,
            "Docs",
            "https://docs.rs/zbus",
            1,
            true,
            false,
            "chrome://branding/icon.png",
        ),
        row(
            1,
            11,
            "Mail",
            "https://mail.example.org/inbox",
            0,
            false,
            true,
            "https://mail.example.org/favicon.ico",
        ),
        row(2, 30, "", "about:blank", 0, true, false, ""),
    ]
}

#[test]
fn tabs_are_listed_in_window_and_index_order() {
    let env = Env::new();
    let bus = DBus::start(env.path());
    let _service = Service::start(&bus, "Firefox", fixture_tabs());
    let (ctx, handles) = env.ctx(&[]);
    let source = Browser::new(&ctx, bus.bus()).unwrap();
    wait(&handles, || source.entries().len() == 3);

    assert_eq!(
        ids(&source),
        ["tab:Firefox:11", "tab:Firefox:12", "tab:Firefox:30"]
    );
    let entries = source.entries();
    let mail = &entries[0];
    assert_eq!(mail.title, "Mail");
    assert_eq!(mail.subtitle, "mail.example.org/inbox");
    assert_eq!(
        mail.icon,
        Icon::Url("https://mail.example.org/favicon.ico".into())
    );
    assert_eq!(mail.accessory, "pinned");
    assert_eq!(mail.section, "Open tabs");
    assert_eq!(mail.boost, 1.5);
    assert_eq!(mail.actions[0].id, "switch");
    assert_eq!(entries[1].icon, Icon::Name("firefox".into()));
    assert_eq!(entries[1].accessory, "");
    assert_eq!(entries[2].title, "about:blank");
    assert!(source.status().is_none());
}

#[test]
fn tabs_updated_refreshes_the_list() {
    let env = Env::new();
    let bus = DBus::start(env.path());
    let service = Service::start(&bus, "Firefox", fixture_tabs());
    let (ctx, handles) = env.ctx(&[]);
    let source = Browser::new(&ctx, bus.bus()).unwrap();
    wait(&handles, || source.entries().len() == 3);

    let mut tabs = fixture_tabs();
    tabs.push(row(
        2,
        31,
        "News",
        "https://news.example.org/",
        1,
        false,
        false,
        "",
    ));
    service.set_tabs(tabs);
    assert!(handles.wait_updated(Mode::Browser, Duration::from_secs(5)));
    wait(&handles, || source.entries().len() == 4);
    assert_eq!(source.entries()[3].title, "News");
}

#[test]
fn an_instance_appearing_later_is_picked_up() {
    let env = Env::new();
    let bus = DBus::start(env.path());
    let (ctx, handles) = env.ctx(&[]);
    let source = Browser::new(&ctx, bus.bus()).unwrap();
    wait(&handles, || source.status().is_some());

    let _service = Service::start(&bus, "Firefox", fixture_tabs());
    wait(&handles, || source.entries().len() == 3);
    assert!(source.status().is_none());
}

#[test]
fn the_tab_in_sight_goes_last() {
    let env = Env::new();
    env.windows(
        r#"[{"id":7,"title":"Docs — Mozilla Firefox","app_id":"firefox","is_focused":true}]"#,
    );
    let bus = DBus::start(env.path());
    let _service = Service::start(&bus, "Firefox", fixture_tabs());
    let (ctx, handles) = env.ctx(&[]);
    let source = Browser::new(&ctx, bus.bus()).unwrap();
    wait(&handles, || source.entries().len() == 3);
    assert_eq!(
        ids(&source),
        ["tab:Firefox:11", "tab:Firefox:30", "tab:Firefox:12"]
    );
}

#[test]
fn switch_activates_the_tab_and_focuses_its_window() {
    let env = Env::new();
    env.windows(
        r#"[{"id":3,"title":"Docs — notes","app_id":"kitty","is_focused":true},
            {"id":7,"title":"Docs — Mozilla Firefox","app_id":"firefox"},
            {"id":8,"title":"Mail — Mozilla Firefox","app_id":"firefox"}]"#,
    );
    let bus = DBus::start(env.path());
    let service = Service::start(&bus, "Firefox", fixture_tabs());
    let (ctx, handles) = env.ctx(&[]);
    let mut source = Browser::new(&ctx, bus.bus()).unwrap();
    wait(&handles, || source.entries().len() == 3);

    assert_eq!(
        source.activate("tab:Firefox:12", "switch", &ctx),
        Outcome::Close
    );
    wait(&handles, || {
        env.niri_calls().iter().any(|c| c.contains("focus-window"))
    });
    assert_eq!(service.calls(), ["ActivateTab(12, true)"]);
    let focus: Vec<_> = env
        .niri_calls()
        .into_iter()
        .filter(|c| c.contains("focus-window"))
        .collect();
    assert_eq!(focus, ["msg action focus-window --id 7"]);
}

#[test]
fn close_and_copy_url() {
    let env = Env::new();
    let bus = DBus::start(env.path());
    let service = Service::start(&bus, "Firefox", fixture_tabs());
    let (ctx, handles) = env.ctx(&[]);
    let mut source = Browser::new(&ctx, bus.bus()).unwrap();
    wait(&handles, || source.entries().len() == 3);

    assert_eq!(
        source.activate("tab:Firefox:11", "close", &ctx),
        Outcome::Stay
    );
    wait(&handles, || !service.calls().is_empty());
    assert_eq!(service.calls(), ["CloseTabs([11])"]);

    assert_eq!(
        source.activate("tab:Firefox:12", "copy-url", &ctx),
        Outcome::Close
    );
    assert_eq!(handles.copies()[0].text(), Some("https://docs.rs/zbus"));
}

#[test]
fn two_instances_are_merged_and_named() {
    let env = Env::new();
    let bus = DBus::start(env.path());
    let _one = Service::start(&bus, "Firefox", fixture_tabs());
    let _two = Service::start(
        &bus,
        "Firefox2",
        vec![row(
            5,
            12,
            "Work",
            "https://work.example.org/",
            0,
            true,
            true,
            "",
        )],
    );
    let (ctx, handles) = env.ctx(&[]);
    let source = Browser::new(&ctx, bus.bus()).unwrap();
    wait(&handles, || source.entries().len() == 4);

    assert_eq!(
        ids(&source),
        [
            "tab:Firefox:11",
            "tab:Firefox:12",
            "tab:Firefox:30",
            "tab:Firefox2:12"
        ]
    );
    let entries = source.entries();
    assert_eq!(entries[0].accessory, "pinned · Firefox");
    assert_eq!(entries[1].accessory, "Firefox");
    assert_eq!(entries[3].accessory, "pinned · Firefox2");
}

struct Profile {
    dir: PathBuf,
    db: Connection,
}

const PNG16: &[u8] = b"\x89PNG\r\n\x1a\nsixteen";
const PNG32: &[u8] = b"\x89PNG\r\n\x1a\nthirty-two";
const PNG128: &[u8] = b"\x89PNG\r\n\x1a\nbig";

impl Profile {
    /// `<root>/profiles.ini` naming a relative profile `abc.default` with Firefox's roots, a
    /// `Dev/Rust` folder in the toolbar and a tag.
    fn new(root: &Path) -> (PathBuf, Profile) {
        let dir = root.join("abc.default");
        fs::create_dir_all(&dir).unwrap();
        let ini = root.join("profiles.ini");
        fs::write(
            &ini,
            "[General]\nStartWithLastProfile=1\n\n[Profile0]\nName=default\nIsRelative=1\nPath=abc.default\n\n[Install4F96D1932A9F858E]\nDefault=abc.default\n",
        )
        .unwrap();
        let db = Connection::open(dir.join("places.sqlite")).unwrap();
        db.execute_batch(
            "CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, rev_host LONGVARCHAR);
             CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER DEFAULT NULL, parent INTEGER,
               position INTEGER, title LONGVARCHAR, keyword_id INTEGER, folder_type TEXT, dateAdded INTEGER,
               lastModified INTEGER, guid TEXT);
             INSERT INTO moz_bookmarks (id, type, parent, title, guid) VALUES
               (1, 2, 0, '', 'root________'), (2, 2, 1, 'menu', 'menu________'), (3, 2, 1, 'toolbar', 'toolbar_____'),
               (4, 2, 1, 'tags', 'tags________'), (5, 2, 1, 'unfiled', 'unfiled_____'), (6, 2, 1, 'mobile', 'mobile______'),
               (10, 2, 3, 'Dev', 'dev_________'), (11, 2, 10, 'Rust', 'rust________'), (12, 2, 4, 'reading', 'tagread_____');",
        )
        .unwrap();
        let profile = Profile { dir, db };
        profile.bookmark(
            20,
            11,
            "The Rust Book",
            "https://doc.rust-lang.org/book/",
            300,
        );
        profile.bookmark(21, 2, "", "https://example.org/untitled", 200);
        profile.bookmark(22, 3, "Mail", "https://mail.example.org/inbox", 100);
        profile.bookmark(23, 12, "Tagged", "https://doc.rust-lang.org/book/", 400);
        profile.bookmark(24, 2, "Recent", "place:sort=14", 500);

        let icons = Connection::open(profile.dir.join("favicons.sqlite")).unwrap();
        icons
            .execute_batch(
                "CREATE TABLE moz_icons (id INTEGER PRIMARY KEY, icon_url TEXT, fixed_icon_url_hash INTEGER, width INTEGER,
                   root INTEGER, color INTEGER, expire_ms INTEGER, flags INTEGER, data BLOB);
                 CREATE TABLE moz_pages_w_icons (id INTEGER PRIMARY KEY, page_url TEXT, page_url_hash INTEGER);
                 CREATE TABLE moz_icons_to_pages (page_id INTEGER, icon_id INTEGER, expire_ms INTEGER);
                 INSERT INTO moz_pages_w_icons VALUES (1, 'https://doc.rust-lang.org/book/', 0), (2, 'https://mail.example.org/inbox', 0);
                 INSERT INTO moz_icons_to_pages VALUES (1, 1, 0), (1, 2, 0), (1, 3, 0), (2, 4, 0);",
            )
            .unwrap();
        let mut insert = icons
            .prepare("INSERT INTO moz_icons (id, icon_url, width, data) VALUES (?1, '', ?2, ?3)")
            .unwrap();
        insert.execute(params![1, 16, PNG16]).unwrap();
        insert.execute(params![2, 32, PNG32]).unwrap();
        insert.execute(params![3, 128, PNG128]).unwrap();
        insert
            .execute(params![4, 16, b"GIF89a".as_slice()])
            .unwrap();
        (ini, profile)
    }

    fn bookmark(&self, id: i64, parent: i64, title: &str, url: &str, added: i64) {
        self.db
            .execute(
                "INSERT INTO moz_places (id, url, title) VALUES (?1, ?2, ?3)",
                params![id, url, title],
            )
            .unwrap();
        self.db
            .execute(
                "INSERT INTO moz_bookmarks (id, type, fk, parent, title, dateAdded, guid) VALUES (?1, 1, ?1, ?2, ?3, ?4, ?5)",
                params![id, parent, title, added, format!("bm{id}")],
            )
            .unwrap();
    }

    /// Moves the database's mtime on, as a write a second later would.
    fn touch(&self) {
        let file = fs::File::options()
            .write(true)
            .open(self.dir.join("places.sqlite"))
            .unwrap();
        file.set_modified(SystemTime::now() + Duration::from_secs(10))
            .unwrap();
    }
}

fn hash_of(dir: &Path) -> String {
    super::bookmarks::hash(
        fs::canonicalize(dir)
            .unwrap()
            .as_os_str()
            .as_encoded_bytes(),
    )
}

#[test]
fn bookmarks_are_listed_with_their_folders_newest_first() {
    let env = Env::new();
    let (ini, profile) = Profile::new(&env.path().join("ff"));
    let (ctx, handles) = env.ctx(&[ini, env.path().join("missing/profiles.ini")]);
    let bus = DBus::start(env.path());
    let source = Browser::new(&ctx, bus.bus()).unwrap();
    wait(&handles, || {
        source.entries().len() == 3 && source.status().is_some()
    });

    let h = hash_of(&profile.dir);
    assert_eq!(
        ids(&source),
        [
            format!("bm:{h}:20"),
            format!("bm:{h}:21"),
            format!("bm:{h}:22")
        ]
    );
    let entries = source.entries();
    let book = &entries[0];
    assert_eq!(book.title, "The Rust Book");
    assert_eq!(book.subtitle, "doc.rust-lang.org/book/ · Dev / Rust");
    assert_eq!(book.keywords, "Dev / Rust");
    assert_eq!(book.section, "Bookmarks");
    assert_eq!(book.boost, 1.0);
    let Icon::Path(icon) = &book.icon else {
        panic!("{:?}", book.icon)
    };
    assert!(icon.starts_with(ctx.dirs.cache.join("favicons")));
    assert_eq!(fs::read(icon).unwrap(), PNG32);
    assert_eq!(entries[1].title, "https://example.org/untitled");
    assert_eq!(entries[1].subtitle, "example.org/untitled");
    // A GIF favicon is not extracted.
    assert_eq!(entries[2].icon, Icon::Name("firefox".into()));

    let status = source.status().unwrap();
    assert_eq!(status.kind, StatusKind::Info);
    assert!(status.text.contains("TabCtl is not connected"));
}

#[test]
fn opening_a_bookmark_runs_firefox_and_copy_copies() {
    let env = Env::new();
    let (ini, profile) = Profile::new(&env.path().join("ff"));
    let (ctx, handles) = env.ctx(&[ini]);
    let mut source = Browser::new(&ctx, Bus::Address("unix:path=/nonexistent".into())).unwrap();
    wait(&handles, || source.entries().len() == 3);

    let id = format!("bm:{}:22", hash_of(&profile.dir));
    assert_eq!(source.activate(&id, "open", &ctx), Outcome::Close);
    assert!(env.niri_calls().contains(
        &"msg action spawn -- /opt/firefox --new-tab https://mail.example.org/inbox".to_owned()
    ));
    assert_eq!(source.activate(&id, "copy-url", &ctx), Outcome::Close);
    assert_eq!(
        handles.copies()[0].text(),
        Some("https://mail.example.org/inbox")
    );
}

#[test]
fn bookmarks_reload_on_open_when_the_database_changed() {
    let env = Env::new();
    let (ini, profile) = Profile::new(&env.path().join("ff"));
    let (ctx, handles) = env.ctx(&[ini]);
    let mut source = Browser::new(&ctx, Bus::Address("unix:path=/nonexistent".into())).unwrap();
    wait(&handles, || source.entries().len() == 3);

    // Unchanged mtimes: the copy is not reread.
    let before = fs::metadata(profile.dir.join("places.sqlite"))
        .unwrap()
        .modified()
        .unwrap();
    profile.bookmark(25, 2, "Sneaky", "https://sneaky.example.org/", 600);
    let file = fs::File::options()
        .write(true)
        .open(profile.dir.join("places.sqlite"))
        .unwrap();
    file.set_modified(before).unwrap();
    let initial = source.entries();
    source.open(&ctx);
    std::thread::sleep(Duration::from_millis(300));
    assert!(Arc::ptr_eq(&initial, &source.entries()));

    profile.touch();
    source.open(&ctx);
    wait(&handles, || source.entries().len() == 4);
    assert_eq!(source.entries()[0].title, "Sneaky");
}

#[test]
fn uncheckpointed_wal_writes_are_read() {
    let env = Env::new();
    let (ini, profile) = Profile::new(&env.path().join("ff"));
    profile
        .db
        .execute_batch("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        .unwrap();
    profile.bookmark(25, 2, "In the WAL", "https://wal.example.org/", 600);
    assert!(profile.dir.join("places.sqlite-wal").exists());
    let (ctx, handles) = env.ctx(&[ini]);
    let source = Browser::new(&ctx, Bus::Address("unix:path=/nonexistent".into())).unwrap();
    wait(&handles, || source.entries().len() == 4);
    assert_eq!(source.entries()[0].title, "In the WAL");
}

#[test]
fn profiles_are_found_once_across_ini_files() {
    let root = TempDir::new().unwrap();
    let a = root.path().join("a");
    let abs = root.path().join("elsewhere/xyz.work");
    fs::create_dir_all(a.join("abc.default")).unwrap();
    fs::create_dir_all(&abs).unwrap();
    fs::write(
        a.join("profiles.ini"),
        format!(
            "[Profile1]\nName=work\nIsRelative=0\nPath={}\n\n[Profile0]\nName=default\nIsRelative=1\nPath=abc.default\nDefault=1\n",
            abs.display()
        ),
    )
    .unwrap();
    // The same profile again, through another file and an absolute path.
    fs::write(
        root.path().join("other.ini"),
        format!(
            "[Profile0]\nIsRelative=0\nPath={}\n",
            a.join("abc.default").display()
        ),
    )
    .unwrap();
    let dirs = super::bookmarks::profile_dirs(&[
        a.join("profiles.ini"),
        root.path().join("missing.ini"),
        root.path().join("other.ini"),
    ]);
    let canon = |p: &Path| fs::canonicalize(p).unwrap();
    assert_eq!(dirs, [canon(&abs), canon(&a.join("abc.default"))]);
}

#[test]
fn an_open_tab_ranks_over_a_bookmark_of_the_same_title() {
    let env = Env::new();
    let (ini, _profile) = Profile::new(&env.path().join("ff"));
    let bus = DBus::start(env.path());
    let _service = Service::start(
        &bus,
        "Firefox",
        vec![row(
            1,
            5,
            "Mail",
            "https://mail.example.org/inbox",
            0,
            false,
            false,
            "",
        )],
    );
    let (ctx, handles) = env.ctx(&[ini]);
    let source = Browser::new(&ctx, bus.bus()).unwrap();
    wait(&handles, || source.entries().len() == 4);

    // Bookmarks come after tabs in the source's order too, so rank them first to be sure.
    let mut reversed = (*source.entries()).clone();
    reversed.reverse();
    let prepared = Prepared::new(Arc::new(reversed));
    let (ranked, _) = rank(&prepared, "mail", false, &|_| 0.0, 10);
    assert_eq!(prepared.entries[ranked[0].index].id, "tab:Firefox:5");
    assert!(ranked.len() >= 2);
}
