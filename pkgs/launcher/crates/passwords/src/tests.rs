use std::path::{Path, PathBuf};
use std::time::Duration;

use launcher_core::config::Config as LauncherConfig;
use launcher_core::testing::Handles;
use launcher_core::{Ctx, Mode, Outcome, Preview, Source, StatusKind};
use serde_json::json;

use super::*;

const WAIT: Duration = Duration::from_secs(10);

// Fixtures follow pass-cli's `vault list` / `item list --output json` serializers
// (pass-cli/src/commands/vault/list.rs `VaultList`, item/list.rs `ItemsList<ItemSummary>`) and
// `item view --field` printing the bare value (item/view.rs); `not logged in` is main.rs's
// "This operation requires an authenticated client".
const PASS_CLI: &str = r#"#!/bin/sh
dir=$(dirname "$0")
(IFS='|'; echo "$*") >> "$dir/pass-cli.log"
while [ -e "$dir/hold" ]; do sleep 0.01; done
# clap's parsing as far as the tests go: `--name value` or `--name=value`, and a separate
# value starting with `-` is an unexpected argument (pass-cli exits 2 before doing anything).
arg() {
  local want=$1; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      "$want="*) echo "${1#*=}"; return ;;
      "$want") case "$2" in -*) return 1 ;; esac; echo "$2"; return ;;
    esac
    shift
  done
}
for name in --share-id --item-id --field; do
  if ! arg "$name" "$@" >/dev/null; then
    echo "error: unexpected argument found after '$name'" >&2; exit 2
  fi
done
if [ -e "$dir/logged-out" ]; then
  echo "Error: This operation requires an authenticated client" >&2; exit 1
fi
case "$1 $2" in
  "vault list") cat "$dir/vaults.json" ;;
  "item list") cat "$dir/items-$(arg --share-id "$@").json" ;;
  "item view")
    f="$dir/secret-$(arg --item-id "$@")-$(arg --field "$@")"
    if [ -e "$f" ]; then cat "$f"; else echo "Error: Field does not exist: $(arg --field "$@")" >&2; exit 1; fi ;;
  *) echo "unexpected: $*" >&2; exit 2 ;;
esac
"#;

// Fixture follows `op item list --format json` as documented at
// https://developer.1password.com/docs/cli/reference/management-commands/item#item-list;
// `op item get --fields label=X` prints the bare value.
const OP: &str = r#"#!/bin/sh
dir=$(dirname "$0")
(IFS='|'; echo "$*") >> "$dir/op.log"
while [ -e "$dir/hold" ]; do sleep 0.01; done
if [ -e "$dir/locked" ]; then
  printf '[ERROR] 2026/11/21 10:00:00 connecting to desktop app: the app is locked\nmore\n' >&2; exit 1
fi
case "$1 $2" in
  "item list") cat "$dir/op-items.json" ;;
  "item get")
    case "$6" in
      --otp) f="$dir/op-$3-otp" ;;
      --fields) f="$dir/op-$3-${7#label=}" ;;
    esac
    if [ -e "$f" ]; then cat "$f"; else echo "[ERROR] no such field" >&2; exit 1; fi ;;
  *) echo "unexpected: $*" >&2; exit 2 ;;
esac
"#;

const NIRI: &str = r#"#!/bin/sh
(IFS='|'; echo "$*") >> "$(dirname "$0")/niri.log"
"#;

struct Fixture {
    _tmp: tempfile::TempDir,
    bin: PathBuf,
    ctx: Ctx,
    handles: Handles,
}

fn script(path: &Path, body: &str) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::write(path, body).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

impl Fixture {
    fn new(proton: bool, onepassword: bool) -> Fixture {
        let tmp = tempfile::tempdir().unwrap();
        let bin = tmp.path().join("bin");
        std::fs::create_dir(&bin).unwrap();
        script(&bin.join("pass-cli"), PASS_CLI);
        script(&bin.join("op"), OP);
        script(&bin.join("niri"), NIRI);
        // Each test runs in its own process under nextest.
        let path = std::env::var_os("PATH").unwrap_or_default();
        let mut paths = vec![bin.clone()];
        paths.extend(std::env::split_paths(&path));
        std::env::set_var("PATH", std::env::join_paths(paths).unwrap());

        let mut section = serde_json::Map::new();
        if proton {
            section.insert("proton".into(), json!({"command": bin.join("pass-cli")}));
        }
        if onepassword {
            section.insert("onepassword".into(), json!({"command": bin.join("op")}));
        }
        let config: LauncherConfig = serde_json::from_value(json!({
            "terminal": ["launcher-test-terminal", "-e"],
            "modes": {"passwords": section},
        }))
        .unwrap();
        let (ctx, handles) = Ctx::testing(&tmp.path().join("root"), config);
        let f = Fixture {
            _tmp: tmp,
            bin,
            ctx,
            handles,
        };
        f.write(
            "vaults.json",
            &json!({"vaults": [
                {"name": "Personal", "vault_id": "v1", "share_id": "S1"},
                {"name": "Work", "vault_id": "v2", "share_id": "S2"},
            ]})
            .to_string(),
        );
        f.write(
            "items-S1.json",
            &proton_items("S1", &[("I1", "GitHub"), ("I2", "amazon")]),
        );
        f.write("items-S2.json", &proton_items("S2", &[("I3", "Codspeed")]));
        f.write(
            "op-items.json",
            &json!([
                {
                    "id": "o1", "title": "AWS", "version": 3,
                    "vault": {"id": "V9", "name": "Engineering"},
                    "category": "LOGIN",
                    "last_edited_by": "X", "created_at": "2025-01-01T00:00:00Z", "updated_at": "2025-01-01T00:00:00Z",
                    "additional_information": "guillaume@work",
                    "urls": [
                        {"label": "website", "href": "https://other.example.org/x"},
                        {"label": "website", "primary": true, "href": "https://www.console.aws.amazon.com/login"}
                    ]
                },
                {
                    "id": "o2", "title": "Wifi key", "version": 1,
                    "vault": {"id": "V9", "name": "Engineering"},
                    "category": "PASSWORD",
                    "created_at": "2025-01-01T00:00:00Z", "updated_at": "2025-01-01T00:00:00Z"
                }
            ])
            .to_string(),
        );
        f
    }

    fn write(&self, name: &str, content: &str) {
        std::fs::write(self.bin.join(name), content).unwrap();
    }

    fn log(&self, name: &str) -> Vec<String> {
        std::fs::read_to_string(self.bin.join(name))
            .map(|s| s.lines().map(str::to_owned).collect())
            .unwrap_or_default()
    }

    fn source(&self) -> Box<dyn Source> {
        let mut sources = sources(&self.ctx).unwrap();
        assert_eq!(sources.len(), 1);
        sources.pop().unwrap()
    }

    fn loaded(&self, source: &mut dyn Source) {
        source.open(&self.ctx);
        assert!(
            self.handles.wait_updated(Mode::Passwords, WAIT),
            "no update"
        );
    }
}

/// The status an `Outcome::Wait` shows, and what its work ends with.
fn wait(outcome: Outcome) -> (String, Result<(), String>) {
    match outcome {
        Outcome::Wait { status, work } => (status, work.run()),
        other => panic!("expected work to wait for, got {other:?}"),
    }
}

fn proton_items(share: &str, items: &[(&str, &str)]) -> String {
    let items: Vec<_> = items
        .iter()
        .map(|(id, title)| {
            json!({
                "id": id, "share_id": share, "vault_id": "v", "state": "Active", "flags": [],
                "create_time": "2025-01-01T00:00:00", "modify_time": "2025-01-01T00:00:00",
                "last_use_time": null, "title": title, "item_type": "login"
            })
        })
        .collect();
    json!({"items": items, "folders": []}).to_string()
}

fn ids(source: &dyn Source) -> Vec<String> {
    source.entries().iter().map(|e| e.id.clone()).collect()
}

#[test]
fn lists_both_managers_proton_first_sorted_by_title() {
    let f = Fixture::new(true, true);
    let mut s = f.source();
    assert_eq!(s.status(), None, "nothing loading before the first open");
    f.write("hold", "");
    s.open(&f.ctx);
    let status = s.status().unwrap();
    assert_eq!(
        (status.kind, status.text.as_str()),
        (StatusKind::Loading, "Loading Proton Pass and 1Password…")
    );
    assert!(s.entries().is_empty());
    std::fs::remove_file(f.bin.join("hold")).unwrap();
    assert!(f.handles.wait_updated(Mode::Passwords, WAIT));
    assert_eq!(
        ids(s.as_ref()),
        [
            "proton:S1:I2",
            "proton:S2:I3",
            "proton:S1:I1",
            "op:V9:o1",
            "op:V9:o2"
        ]
        .map(String::from)
        .to_vec(),
        "amazon, Codspeed, GitHub (case-insensitive, across vaults), then 1Password"
    );
    assert_eq!(s.status(), None);

    let entries = s.entries();
    let aws = entries.iter().find(|e| e.id == "op:V9:o1").unwrap();
    assert_eq!(aws.title, "AWS");
    assert_eq!(aws.subtitle, "guillaume@work");
    assert_eq!(aws.accessory, "1Password · Engineering");
    assert!(aws.keywords.contains("console.aws.amazon.com"));
    assert!(aws.keywords.contains("Engineering"));
    assert_eq!(aws.icon, Icon::Name("1password".into()));
    let actions: Vec<_> = aws
        .actions
        .iter()
        .map(|a| (a.id.as_str(), a.key.as_deref()))
        .collect();
    assert_eq!(
        actions,
        [
            ("password", Some("Return")),
            ("username", Some("Alt+Return")),
            ("totp", Some("Ctrl+Return")),
            ("open-url", None)
        ]
    );
    let wifi = entries.iter().find(|e| e.id == "op:V9:o2").unwrap();
    assert_eq!(
        wifi.actions
            .iter()
            .map(|a| a.id.as_str())
            .collect::<Vec<_>>(),
        ["password"]
    );

    let github = entries.iter().find(|e| e.id == "proton:S1:I1").unwrap();
    assert_eq!(github.accessory, "Proton · Personal");
    assert_eq!(github.icon, Icon::Name("proton-pass".into()));
    assert!(github.preview);

    assert_eq!(
        s.preview("op:V9:o1", &f.ctx),
        Some(Preview::Fields {
            fields: vec![
                ("Username".into(), "guillaume@work".into()),
                (
                    "URLs".into(),
                    "https://www.console.aws.amazon.com/login\nhttps://other.example.org/x".into()
                ),
                ("Vault".into(), "Engineering".into()),
                ("Manager".into(), "1Password".into()),
            ]
        })
    );
    assert_eq!(
        f.log("pass-cli.log").first().map(String::as_str),
        Some("vault|list|--output|json")
    );
    assert!(f.log("pass-cli.log").contains(
        &"item|list|--share-id=S2|--filter-type|login|--filter-state|active|--output|json"
            .to_owned()
    ));
    assert_eq!(
        f.log("op.log"),
        ["item|list|--categories|Login,Password|--format|json"]
    );
}

#[test]
fn a_later_open_shows_the_cached_list_until_the_refresh_lands() {
    let f = Fixture::new(true, false);
    let mut s = f.source();
    f.loaded(s.as_mut());
    assert_eq!(s.entries().len(), 3);

    f.write(
        "items-S2.json",
        &proton_items("S2", &[("I3", "Codspeed"), ("I4", "Zed")]),
    );
    f.write("hold", "");
    s.open(&f.ctx);
    assert_eq!(s.entries().len(), 3, "cached entries while refreshing");
    assert_eq!(s.status(), None, "no loading status over a cached list");
    std::fs::remove_file(f.bin.join("hold")).unwrap();
    assert!(f.handles.wait_updated(Mode::Passwords, WAIT));
    assert_eq!(
        ids(s.as_ref()).last().map(String::as_str),
        Some("proton:S2:I4")
    );
}

#[test]
fn not_logged_in_shows_info_and_a_login_row() {
    let f = Fixture::new(true, true);
    f.write("logged-out", "");
    let mut s = f.source();
    f.loaded(s.as_mut());
    let status = s.status().unwrap();
    assert_eq!(
        (status.kind, status.text.as_str()),
        (StatusKind::Info, "Proton Pass: not logged in")
    );
    assert_eq!(ids(s.as_ref()), ["proton:login", "op:V9:o1", "op:V9:o2"]);
    assert_eq!(s.entries()[0].title, "Log in to Proton Pass");

    assert_eq!(s.activate("proton:login", "login", &f.ctx), Outcome::Close);
    let cli = f.bin.join("pass-cli");
    assert_eq!(
        f.log("niri.log"),
        [format!(
            "msg|action|spawn|--|launcher-test-terminal|-e|{}|login",
            cli.display()
        )]
    );
}

#[test]
fn the_panel_waits_until_the_value_is_on_the_clipboard() {
    let f = Fixture::new(true, true);
    // Proton ids are base64url: some start with `-`.
    f.write(
        "items-S1.json",
        &proton_items("S1", &[("I1", "GitHub"), ("-I5", "dashed")]),
    );
    f.write("secret-I1-password", "hunter2\n");
    f.write("secret-I1-email", "me@proton.me\n");
    f.write("secret-I1-totp", "123456\n");
    f.write("secret--I5-password", "dash\n");
    f.write("op-o1-password", "awspass\n");
    f.write("op-o1-username", "guillaume\n");
    f.write("op-o1-otp", "654321\n");
    let mut s = f.source();
    f.loaded(s.as_mut());

    let steps = [
        (
            "proton:S1:I1",
            "password",
            "Copying the password…",
            "hunter2",
            true,
        ),
        (
            "proton:S1:I1",
            "username",
            "Copying the username…",
            "me@proton.me",
            false,
        ),
        (
            "proton:S1:I1",
            "totp",
            "Copying the one-time code…",
            "123456",
            true,
        ),
        (
            "proton:S1:-I5",
            "password",
            "Copying the password…",
            "dash",
            true,
        ),
        (
            "op:V9:o1",
            "password",
            "Copying the password…",
            "awspass",
            true,
        ),
        (
            "op:V9:o1",
            "username",
            "Copying the username…",
            "guillaume",
            false,
        ),
        (
            "op:V9:o1",
            "totp",
            "Copying the one-time code…",
            "654321",
            true,
        ),
    ];
    for (n, (id, action, status, text, secret)) in steps.iter().enumerate() {
        let (shown, ended) = wait(s.activate(id, action, &f.ctx));
        assert_eq!((shown.as_str(), ended), (*status, Ok(())), "{id} {action}");
        // Copied by the time the work ends, which is when the panel closes.
        let copies = f.handles.copies();
        assert_eq!(copies.len(), n + 1, "{id} {action}");
        assert_eq!(copies[n].text(), Some(*text), "{id} {action}");
        assert_eq!(copies[n].secret, *secret, "{id} {action}");
    }

    let proton: Vec<_> = f
        .log("pass-cli.log")
        .into_iter()
        .filter(|l| l.starts_with("item|view"))
        .collect();
    assert_eq!(
        proton,
        [
            "item|view|--share-id=S1|--item-id=I1|--field|password",
            "item|view|--share-id=S1|--item-id=I1|--field|username",
            "item|view|--share-id=S1|--item-id=I1|--field|email",
            "item|view|--share-id=S1|--item-id=I1|--field|totp",
            "item|view|--share-id=S1|--item-id=-I5|--field|password",
        ]
    );
    let op: Vec<_> = f
        .log("op.log")
        .into_iter()
        .filter(|l| l.starts_with("item|get"))
        .collect();
    assert_eq!(
        op,
        [
            "item|get|o1|--vault|V9|--fields|label=password|--reveal",
            "item|get|o1|--vault|V9|--fields|label=username",
            "item|get|o1|--vault|V9|--otp",
        ]
    );
}

#[test]
fn a_failed_fetch_is_the_panels_error_and_leaves_the_clipboard_alone() {
    let f = Fixture::new(true, true);
    let mut s = f.source();
    f.loaded(s.as_mut());
    let (_, ended) = wait(s.activate("op:V9:o1", "totp", &f.ctx));
    assert_eq!(
        ended,
        Err("Copying the one-time code failed: [ERROR] no such field".into())
    );
    let (_, ended) = wait(s.activate("proton:S1:I2", "password", &f.ctx));
    assert_eq!(
        ended,
        Err("Copying the password failed: Error: Field does not exist: password".into())
    );
    assert!(f.handles.copies().is_empty());
}

#[test]
fn a_locked_1password_is_an_error_status_with_the_first_line() {
    let f = Fixture::new(true, true);
    f.write("locked", "");
    let mut s = f.source();
    f.loaded(s.as_mut());
    let status = s.status().unwrap();
    assert_eq!(status.kind, StatusKind::Error);
    assert_eq!(
        status.text,
        "1Password: [ERROR] 2026/11/21 10:00:00 connecting to desktop app: the app is locked"
    );
    assert_eq!(s.entries().len(), 3, "Proton items still listed");
}

#[test]
fn a_disabled_manager_never_runs() {
    let f = Fixture::new(false, true);
    let mut s = f.source();
    f.write("hold", "");
    s.open(&f.ctx);
    assert_eq!(s.status().unwrap().text, "Loading 1Password…");
    std::fs::remove_file(f.bin.join("hold")).unwrap();
    assert!(f.handles.wait_updated(Mode::Passwords, WAIT));
    assert_eq!(ids(s.as_ref()), ["op:V9:o1", "op:V9:o2"]);
    assert!(f.log("pass-cli.log").is_empty());

    let f = Fixture::new(true, false);
    let mut s = f.source();
    f.loaded(s.as_mut());
    assert_eq!(s.entries().len(), 3);
    assert!(f.log("op.log").is_empty());
}

#[test]
fn the_mode_off_means_no_source() {
    let tmp = tempfile::tempdir().unwrap();
    let (ctx, _) = Ctx::testing(tmp.path(), LauncherConfig::with_modes(&[Mode::Apps]));
    assert!(sources(&ctx).unwrap().is_empty());
}

#[test]
fn hosts() {
    assert_eq!(host("https://www.github.com/login?x=1"), "github.com");
    assert_eq!(host("http://user@example.org:8080/"), "example.org");
    assert_eq!(host("example.net"), "example.net");
}
