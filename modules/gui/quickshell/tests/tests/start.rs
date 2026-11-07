//! The start menu, driven the way a user does: the pointer resting in the
//! bar's bottom-left corner, clicks and keys in the menu.

use std::time::Duration;

use quickshell_tests::Session;
use serde_json::{json, Value};

fn app(name: &str) -> String {
    format!(
        "[Desktop Entry]\nType=Application\nName={name}\nExec=app {}\n",
        name.to_lowercase()
    )
}

/// One review asked of me: the harness waits for the reviews pill to show.
fn reviews() -> Value {
    let pr = json!({
        "kind": "pr", "place": "alone", "number": 1, "title": "t", "repo": "app",
        "url": "https://github.com/acme/app/pull/1", "branch": "b", "state": "Open",
        "draft": false, "updated_at": 1_700_000_000, "listed": true, "additions": 1,
        "deletions": 1, "author": "a", "avatar": null, "decision": null, "checks": "Success"
    });
    let tab =
        |rows: Vec<Value>| json!({ "count": rows.len(), "stale": 0, "rows": rows, "all": rows });
    json!({
        "snapshot": "", "fetched_at": 1_700_000_000,
        "requested": tab(vec![pr]), "reviewed": tab(vec![]), "mine": tab(vec![]),
    })
}

fn start() -> Option<Session> {
    let (alpha, beta, gamma) = (app("Alpha"), app("Beta"), app("Gamma"));
    Session::start_with_apps(
        &reviews(),
        &[("alpha", &alpha), ("beta", &beta), ("gamma", &gamma)],
    )
}

fn names(list: &Value) -> Vec<&str> {
    list.as_array()
        .unwrap()
        .iter()
        .map(|i| i["name"].as_str().unwrap())
        .collect()
}

fn point_at_corner(s: &Session) {
    // Clamped to the output's bottom-left pixel.
    s.point_at(0.0, 5000.0);
}

fn open(s: &Session) -> Value {
    point_at_corner(s);
    s.wait_for_start("the menu to open", |st| st["open"] == true)
}

fn point_at_named(s: &Session, list: &str, name: &str) {
    let st = s.start_menu();
    let item = st[list]
        .as_array()
        .unwrap()
        .iter()
        .find(|i| i["name"] == name)
        .unwrap_or_else(|| panic!("no {name} in {list}: {st}"));
    s.point_at(item["x"].as_f64().unwrap(), item["y"].as_f64().unwrap());
}

#[test]
fn resting_in_the_corner_opens_the_menu_and_closing_it_there_does_not_reopen_it() {
    let Some(s) = start() else {
        return;
    };
    let st = open(&s);
    assert_eq!(names(&st["rows"]), ["Alpha", "Beta", "Gamma"]);

    s.key("Escape");
    s.wait_for_start("the menu to close", |st| st["open"] == false);
    // The pointer is still in the corner, well past the dwell.
    std::thread::sleep(Duration::from_millis(600));
    assert_eq!(s.start_menu()["open"], false);

    s.point_at(500.0, 500.0);
    open(&s);
}

#[test]
fn right_clicking_an_app_pins_it_and_right_clicking_its_tile_unpins_it() {
    let Some(s) = start() else {
        return;
    };
    open(&s);

    point_at_named(&s, "rows", "Beta");
    s.right_click();
    let st = s.wait_for_start("Beta to be pinned", |st| st["pins"] == json!(["beta"]));
    assert_eq!(names(&st["tiles"]), ["Beta"]);
    let saved = std::fs::read_to_string(s.path("state/quickshell/start-pins.json")).unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&saved).unwrap(),
        json!(["beta"])
    );

    point_at_named(&s, "rows", "Alpha");
    s.right_click();
    let st = s.wait_for_start("Alpha to be pinned after Beta", |st| {
        st["pins"] == json!(["beta", "alpha"])
    });
    assert_eq!(names(&st["tiles"]), ["Beta", "Alpha"]);

    point_at_named(&s, "tiles", "Beta");
    s.right_click();
    let st = s.wait_for_start("Beta to be unpinned", |st| st["pins"] == json!(["alpha"]));
    assert_eq!(names(&st["tiles"]), ["Alpha"]);
}

#[test]
fn typing_filters_the_apps_and_enter_launches_the_best_match_through_niri() {
    let Some(s) = start() else {
        return;
    };
    open(&s);

    s.wtype(&["gam"]);
    let st = s.wait_for_start("the query", |st| st["query"] == "gam");
    assert_eq!(names(&st["rows"]), ["Gamma"]);
    assert_eq!(st["cursor"], 0);

    s.key("Return");
    s.wait_for_record("app.log", "gamma");
    assert_eq!(s.start_menu()["open"], false);
}

#[test]
fn clicking_a_pinned_tile_launches_it_and_the_corner_opens_the_menu_again_at_once() {
    let Some(s) = start() else {
        return;
    };
    open(&s);
    point_at_named(&s, "rows", "Alpha");
    s.right_click();
    s.wait_for_start("Alpha to be pinned", |st| {
        st["tiles"].as_array().unwrap().len() == 1
    });

    point_at_named(&s, "tiles", "Alpha");
    s.click();
    s.wait_for_record("app.log", "alpha");
    // The menu closed away from the corner, so going there opens it.
    open(&s);
}
