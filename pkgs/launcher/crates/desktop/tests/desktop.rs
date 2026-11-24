//! Each test runs in its own process (nextest), so setting the environment is safe.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use launcher_core::testing::Handles;
use launcher_core::{Config, Ctx, Icon, Mode, Outcome, Source};

const WAIT: Duration = Duration::from_secs(5);

fn write(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

/// A `niri` on PATH answering `msg --json windows|workspaces` from `root`'s fixtures and
/// recording every action's argv, one argument per line, to `root/niri.log`.
fn stub_niri(root: &Path) -> PathBuf {
    let bin = root.join("bin");
    let log = root.join("niri.log");
    let script = format!(
        "#!/bin/sh\nshift\nif [ \"$1\" = --json ]; then cat '{root}/'\"$2\".json; exit; fi\nprintf '%s\\n' \"$@\" > '{log}'\n",
        root = root.display(),
        log = log.display()
    );
    write(&bin.join("niri"), &script);
    std::fs::set_permissions(bin.join("niri"), std::fs::Permissions::from_mode(0o755)).unwrap();
    let path = std::env::var("PATH").unwrap_or_default();
    std::env::set_var("PATH", format!("{}:{path}", bin.display()));
    log
}

/// The recorded argv, with a spawned program the daemon resolved on PATH named as it was asked.
fn logged(log: &Path) -> Vec<String> {
    let mut args: Vec<String> = std::fs::read_to_string(log)
        .unwrap()
        .lines()
        .map(str::to_owned)
        .collect();
    if args.len() > 3 && args[..3] == ["action", "spawn", "--"] {
        args[3] = unresolve(&args[3]);
    }
    args
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

fn source(ctx: &Ctx, mode: Mode) -> Box<dyn Source> {
    launcher_desktop::sources(ctx)
        .unwrap()
        .into_iter()
        .find(|s| s.mode() == mode)
        .unwrap()
}

fn setup_apps(root: &Path) -> (Ctx, Handles, Box<dyn Source>, PathBuf) {
    let home = root.join("home");
    let sys = root.join("sys");
    let sys2 = root.join("sys2");
    std::env::set_var("XDG_DATA_HOME", &home);
    std::env::set_var(
        "XDG_DATA_DIRS",
        format!("{}:{}", sys.display(), sys2.display()),
    );
    std::env::set_var("XDG_CURRENT_DESKTOP", "niri:GNOME");
    let apps = |d: &Path, rel: &str, text: &str| write(&d.join("applications").join(rel), text);
    apps(
        &home,
        "editor.desktop",
        "[Desktop Entry]\nType=Application\nName=Editor\nGenericName=Text Editor\nComment=Edit\nIcon=/icons/editor.png\n\
         Keywords=write;code;\nCategories=Utility;\nExec=/usr/bin/edit --title \"My\\\\$ \\\\\"doc\\\\\"\" %F\n\
         Actions=new-window;broken;\n\n[Desktop Action new-window]\nName=New Window\nExec=edit --new %U\n\
         \n[Desktop Action broken]\nName=Has no Exec\n",
    );
    apps(
        &sys,
        "editor.desktop",
        "[Desktop Entry]\nType=Application\nName=Shadowed\nExec=old\n",
    );
    apps(
        &sys,
        "kde/konsole.desktop",
        "[Desktop Entry]\nType=Application\nName=Konsole\nIcon=konsole\nExec=konsole %i\n",
    );
    apps(&sys, "top.desktop", "[Desktop Entry]\nType=Application\nName=top\nComment=Processes\nTerminal=true\nPath=/tmp/work dir\nExec=top -d 1\n");
    apps(
        &sys,
        "hidden.desktop",
        "[Desktop Entry]\nType=Application\nName=Hidden\nHidden=true\nExec=x\n",
    );
    apps(
        &sys2,
        "hidden.desktop",
        "[Desktop Entry]\nType=Application\nName=Not Hidden\nExec=x\n",
    );
    apps(
        &sys,
        "nodisplay.desktop",
        "[Desktop Entry]\nType=Application\nName=NoDisp\nNoDisplay=true\nExec=x\n",
    );
    apps(
        &sys,
        "kdeonly.desktop",
        "[Desktop Entry]\nType=Application\nName=KDE only\nOnlyShowIn=KDE;\nExec=x\n",
    );
    apps(
        &sys,
        "gnomeonly.desktop",
        "[Desktop Entry]\nType=Application\nName=Gnome App\nOnlyShowIn=GNOME;\nExec=gapp\n",
    );
    apps(
        &sys,
        "notniri.desktop",
        "[Desktop Entry]\nType=Application\nName=Not niri\nNotShowIn=niri;\nExec=x\n",
    );
    apps(
        &sys,
        "link.desktop",
        "[Desktop Entry]\nType=Link\nName=Link\nURL=https://x\n",
    );
    let log = stub_niri(root);
    let mut config = Config::with_modes(&[Mode::Apps]);
    config.terminal = vec!["kitty".into(), "-e".into()];
    let (ctx, handles) = Ctx::testing(&root.join("ctx"), config);
    let apps = source(&ctx, Mode::Apps);
    assert!(handles.wait_updated(Mode::Apps, WAIT));
    (ctx, handles, apps, log)
}

#[test]
fn apps_lists_visible_entries_alphabetically() {
    let dir = tempfile::tempdir().unwrap();
    let (_ctx, _h, apps, _log) = setup_apps(dir.path());
    let entries = apps.entries();
    let rows: Vec<(&str, &str)> = entries
        .iter()
        .map(|e| (e.id.as_str(), e.title.as_str()))
        .collect();
    assert_eq!(
        rows,
        [
            ("editor.desktop", "Editor"),
            ("gnomeonly.desktop", "Gnome App"),
            ("kde-konsole.desktop", "Konsole"),
            ("top.desktop", "top"),
        ]
    );
    let editor = &entries[0];
    assert_eq!(editor.subtitle, "Text Editor");
    assert_eq!(editor.keywords, "write code Utility edit");
    assert_eq!(editor.icon, Icon::Path("/icons/editor.png".into()));
    let labels: Vec<_> = editor
        .actions
        .iter()
        .map(|a| (a.id.as_str(), a.label.as_str(), a.key.as_deref()))
        .collect();
    assert_eq!(
        labels,
        [
            ("open", "Open", Some("Return")),
            ("action:new-window", "New Window", None)
        ]
    );
    assert_eq!(entries[2].icon, Icon::Name("konsole".into()));
    assert_eq!(entries[3].subtitle, "Processes");
    assert!(apps.frecency());
}

#[test]
fn apps_launch_argv() {
    let dir = tempfile::tempdir().unwrap();
    let (ctx, _h, mut apps, log) = setup_apps(dir.path());
    let spawned = |apps: &mut Box<dyn Source>, id: &str, action: &str| {
        assert_eq!(apps.activate(id, action, &ctx), Outcome::Close);
        logged(&log)
    };
    assert_eq!(
        spawned(&mut apps, "editor.desktop", "open"),
        [
            "action",
            "spawn",
            "--",
            "/usr/bin/edit",
            "--title",
            "My$ \"doc\""
        ]
    );
    assert_eq!(
        spawned(&mut apps, "editor.desktop", "action:new-window"),
        ["action", "spawn", "--", "edit", "--new"]
    );
    assert_eq!(
        spawned(&mut apps, "kde-konsole.desktop", "open"),
        ["action", "spawn", "--", "konsole", "--icon", "konsole"]
    );
    assert_eq!(
        spawned(&mut apps, "top.desktop", "open"),
        [
            "action",
            "spawn",
            "--",
            "env",
            "-C",
            "/tmp/work dir",
            "kitty",
            "-e",
            "top",
            "-d",
            "1"
        ]
    );
}

#[test]
fn apps_rescan_on_open() {
    let dir = tempfile::tempdir().unwrap();
    let (ctx, handles, mut apps, _log) = setup_apps(dir.path());
    apps.open(&ctx);
    assert!(
        !handles.wait_updated(Mode::Apps, Duration::from_millis(300)),
        "unchanged: no update"
    );
    write(
        &dir.path().join("home/applications/new.desktop"),
        "[Desktop Entry]\nType=Application\nName=Aaa New\nExec=new\n",
    );
    apps.open(&ctx);
    assert!(handles.wait_updated(Mode::Apps, WAIT));
    assert_eq!(apps.entries()[0].id, "new.desktop");
}

fn setup_windows(root: &Path) -> (Ctx, Handles, Box<dyn Source>, PathBuf) {
    let data = root.join("data");
    std::env::set_var("XDG_DATA_HOME", &data);
    std::env::set_var("XDG_DATA_DIRS", root.join("none"));
    write(
        &data.join("applications/org.mozilla.Firefox.desktop"),
        "[Desktop Entry]\nType=Application\nName=Firefox\nIcon=firefox\nExec=firefox\n",
    );
    write(
        &data.join("applications/term.desktop"),
        "[Desktop Entry]\nType=Application\nName=Terminal\nIcon=term-icon\nStartupWMClass=Kitty\nNoDisplay=true\nExec=kitty\n",
    );
    let ts = |s: u64| format!("{{\"secs\":{s},\"nanos\":0}}");
    write(
        &root.join("windows.json"),
        &format!(
            r#"[
            {{"id":1,"title":"Mail","app_id":"org.mozilla.firefox","pid":10,"workspace_id":1,"is_focused":false,"is_floating":false,"focus_timestamp":{}}},
            {{"id":2,"title":"Shell","app_id":"kitty","pid":11,"workspace_id":2,"is_focused":true,"is_floating":false,"focus_timestamp":{}}},
            {{"id":3,"title":"Other","app_id":"unknown.app","pid":12,"workspace_id":2,"is_focused":false,"is_floating":true,"focus_timestamp":{}}},
            {{"id":4,"title":"Never","app_id":null,"pid":13,"workspace_id":1,"is_focused":false,"is_floating":false,"focus_timestamp":null}}
            ]"#,
            ts(100),
            ts(300),
            ts(200)
        ),
    );
    write(
        &root.join("workspaces.json"),
        r#"[{"id":1,"idx":1,"name":"web","output":"DP-1","is_focused":false},
            {"id":2,"idx":2,"name":null,"output":"eDP-1","is_focused":true}]"#,
    );
    let log = stub_niri(root);
    let (ctx, handles) = Ctx::testing(&root.join("ctx"), Config::with_modes(&[Mode::Windows]));
    let mut windows = source(&ctx, Mode::Windows);
    windows.open(&ctx);
    assert!(handles.wait_updated(Mode::Windows, WAIT));
    (ctx, handles, windows, log)
}

#[test]
fn windows_most_recent_first_focused_last() {
    let dir = tempfile::tempdir().unwrap();
    let (_ctx, _h, windows, _log) = setup_windows(dir.path());
    assert_eq!(windows.status(), None);
    let entries = windows.entries();
    let rows: Vec<_> = entries
        .iter()
        .map(|e| {
            (
                e.id.as_str(),
                e.title.as_str(),
                e.subtitle.as_str(),
                e.accessory.as_str(),
                e.icon.clone(),
            )
        })
        .collect();
    assert_eq!(
        rows,
        [
            ("3", "Other", "unknown.app", "2 · eDP-1", Icon::None),
            (
                "1",
                "Mail",
                "Firefox",
                "web · DP-1",
                Icon::Name("firefox".into())
            ),
            ("4", "Never", "", "web · DP-1", Icon::None),
            (
                "2",
                "Shell",
                "Terminal",
                "2 · eDP-1",
                Icon::Name("term-icon".into())
            ),
        ]
    );
    assert_eq!(entries[0].actions[0].id, "focus");
    assert_eq!(entries[0].actions[1].key.as_deref(), Some("Shift+Delete"));
}

#[test]
fn windows_focus_and_close() {
    let dir = tempfile::tempdir().unwrap();
    let (ctx, handles, mut windows, log) = setup_windows(dir.path());
    assert_eq!(windows.activate("1", "focus", &ctx), Outcome::Close);
    assert_eq!(logged(&log), ["action", "focus-window", "--id", "1"]);
    assert_eq!(windows.activate("3", "close", &ctx), Outcome::Stay);
    assert_eq!(logged(&log), ["action", "close-window", "--id", "3"]);
    assert!(windows.entries().iter().all(|e| e.id != "3"));
    assert!(
        handles.wait_updated(Mode::Windows, WAIT),
        "re-listed after closing"
    );
}

#[test]
fn windows_report_niri_failure() {
    let dir = tempfile::tempdir().unwrap();
    std::env::set_var("PATH", dir.path().join("empty"));
    let (ctx, handles) = Ctx::testing(dir.path(), Config::with_modes(&[Mode::Windows]));
    let mut windows = source(&ctx, Mode::Windows);
    windows.open(&ctx);
    assert!(handles.wait_updated(Mode::Windows, WAIT));
    assert!(windows.status().is_some_and(|s| s.text.contains("niri")));
}

const EMOJI_TEST: &str = "\
# group: Smileys & Emotion

# subgroup: face-smiling
1F600                                                  ; fully-qualified     # 😀 E1.0 grinning face
263A FE0F                                              ; fully-qualified     # ☺️ E0.6 smiling face
263A                                                   ; unqualified         # ☺ E0.6 smiling face

# group: People & Body

# subgroup: hand-fingers-open
1F44B                                                  ; fully-qualified     # 👋 E0.6 waving hand
1F44B 1F3FB                                            ; fully-qualified     # 👋🏻 E1.0 waving hand: light skin tone

# group: Component

# subgroup: skin-tone
1F3FB                                                  ; component           # 🏻 E1.0 light skin tone
";

const ANNOTATIONS: &str = r#"<ldml>
	<annotations>
		<annotation cp="&amp;">ampersand | and</annotation>
		<annotation cp="😀">face | grin | grinning face</annotation>
		<annotation cp="😀" type="tts">grinning face</annotation>
		<annotation cp="☺">face | outlined | relaxed | smile</annotation>
		<annotation cp="☺" type="tts">smiling face &amp; co</annotation>
	</annotations>
</ldml>"#;

const DERIVED: &str = r#"<ldml><annotations>
		<annotation cp="👋">hand | wave | hello</annotation>
		<annotation cp="👋" type="tts">waving hand</annotation>
</annotations></ldml>"#;

fn emoji_ctx(root: &Path, section: serde_json::Value) -> (Ctx, Handles, Box<dyn Source>) {
    let mut config = Config::with_modes(&[Mode::Emoji]);
    config.modes.insert(Mode::Emoji, section);
    let (ctx, handles) = Ctx::testing(&root.join("ctx"), config);
    let emoji = source(&ctx, Mode::Emoji);
    assert!(handles.wait_updated(Mode::Emoji, WAIT));
    (ctx, handles, emoji)
}

#[test]
fn emoji_named_and_keyworded() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    write(&root.join("emoji-test.txt"), EMOJI_TEST);
    write(&root.join("en.xml"), ANNOTATIONS);
    write(&root.join("derived/en.xml"), DERIVED);
    let (ctx, handles, mut emoji) = emoji_ctx(
        root,
        serde_json::json!({
            "emoji_test": root.join("emoji-test.txt"),
            "annotations": [root.join("en.xml"), root.join("derived/en.xml")],
        }),
    );
    assert_eq!(emoji.status(), None);
    let entries = emoji.entries();
    let rows: Vec<_> = entries
        .iter()
        .map(|e| {
            (
                e.id.as_str(),
                e.title.as_str(),
                e.keywords.as_str(),
                e.section.as_str(),
            )
        })
        .collect();
    assert_eq!(
        rows,
        [
            (
                "😀",
                "grinning face",
                "face grin grinning face Smileys & Emotion face-smiling",
                "Smileys & Emotion"
            ),
            (
                "☺\u{FE0F}",
                "smiling face & co",
                "face outlined relaxed smile Smileys & Emotion face-smiling",
                "Smileys & Emotion"
            ),
            (
                "👋",
                "waving hand",
                "hand wave hello People & Body hand-fingers-open",
                "People & Body"
            ),
        ]
    );
    assert_eq!(entries[0].icon, Icon::Emoji("😀".into()));
    assert!(emoji.frecency());

    assert_eq!(emoji.activate("👋", "copy", &ctx), Outcome::Close);
    assert_eq!(emoji.activate("😀", "copy-name", &ctx), Outcome::Close);
    let copies: Vec<_> = handles
        .copies()
        .iter()
        .map(|c| c.text().unwrap().to_owned())
        .collect();
    assert_eq!(copies, ["👋", "grinning face"]);
}

#[test]
fn emoji_falls_back_to_test_names() {
    let dir = tempfile::tempdir().unwrap();
    write(&dir.path().join("emoji-test.txt"), EMOJI_TEST);
    let (_ctx, _h, emoji) = emoji_ctx(
        dir.path(),
        serde_json::json!({"emoji_test": dir.path().join("emoji-test.txt")}),
    );
    let titles: Vec<_> = emoji.entries().iter().map(|e| e.title.clone()).collect();
    assert_eq!(titles, ["grinning face", "smiling face", "waving hand"]);
}

#[test]
fn emoji_missing_files_are_an_error_status() {
    let dir = tempfile::tempdir().unwrap();
    let (_ctx, _h, emoji) = emoji_ctx(
        dir.path(),
        serde_json::json!({"emoji_test": dir.path().join("missing.txt")}),
    );
    assert!(emoji.entries().is_empty());
    assert!(emoji
        .status()
        .is_some_and(|s| s.text.contains("missing.txt")));
    let (_ctx, _h, emoji) = emoji_ctx(&dir.path().join("2"), serde_json::Value::Null);
    assert!(emoji
        .status()
        .is_some_and(|s| s.text.contains("emoji_test")));
}

/// The power source with a `systemctl` that records its argv to `root/systemctl.log`, or fails
/// as logind does when it cannot hibernate.
fn power(root: &Path) -> (Ctx, Handles, Box<dyn Source>) {
    let systemctl = root.join("systemctl");
    write(
        &systemctl,
        &format!(
            "#!/bin/sh\nif [ \"$1\" = hibernate ]; then echo 'Not enough suitable swap space for hibernation available' >&2; exit 1; fi\necho \"$@\" > '{}'\n",
            root.join("systemctl.log").display()
        ),
    );
    std::fs::set_permissions(&systemctl, std::fs::Permissions::from_mode(0o755)).unwrap();
    let mut config = Config::with_modes(&[]);
    config
        .modes
        .insert(Mode::Power, serde_json::json!({ "systemctl": systemctl }));
    let (ctx, handles) = Ctx::testing(&root.join("ctx"), config);
    let power = source(&ctx, Mode::Power);
    (ctx, handles, power)
}

#[test]
fn power_lists_the_mildest_first_and_runs_systemctl() {
    let dir = tempfile::tempdir().unwrap();
    let (ctx, _h, mut power) = power(dir.path());
    let ids: Vec<_> = power.entries().iter().map(|e| e.id.clone()).collect();
    assert_eq!(ids, ["suspend", "hibernate", "reboot", "poweroff"]);

    let Outcome::Wait { status, work } = power.activate("suspend", "run", &ctx) else {
        panic!("suspend is waited for");
    };
    assert_eq!(status, "Going to sleep…");
    assert_eq!(work.run(), Ok(()));
    let log = std::fs::read_to_string(dir.path().join("systemctl.log")).unwrap();
    assert_eq!(log.trim(), "suspend");
}

#[test]
fn power_shows_why_systemctl_refused() {
    let dir = tempfile::tempdir().unwrap();
    let (ctx, _h, mut power) = power(dir.path());
    let Outcome::Wait { work, .. } = power.activate("hibernate", "", &ctx) else {
        panic!("hibernate is waited for");
    };
    assert_eq!(
        work.run(),
        Err("Not enough suitable swap space for hibernation available".into())
    );
}
