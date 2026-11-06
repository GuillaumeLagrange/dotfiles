//! sway-like numbered workspaces: `niri-workspaces` and the bar's cells. niri
//! starts with one unnamed workspace; numbers exist only once gone to, or once
//! the watcher names what an output shows.

use quickshell_tests::Session;
use serde_json::{json, Value};

/// One PR to review, so the reviews pill the session waits for shows.
fn reviews() -> Value {
    let pr = json!({
        "kind": "pr", "place": "alone", "number": 1, "title": "t", "repo": "app",
        "url": "https://github.com/acme/app/pull/1", "branch": "b",
        "state": "Open", "draft": false, "updated_at": 1_700_000_000, "listed": true,
        "additions": 1, "deletions": 1, "author": "alice", "avatar": null,
        "decision": null, "checks": "Success"
    });
    let empty = json!({ "count": 0, "stale": 0, "rows": [], "all": [] });
    json!({
        "snapshot": "",
        "fetched_at": 1_700_000_000,
        "requested": { "count": 1, "stale": 0, "rows": [pr], "all": [pr] },
        "reviewed": empty,
        "mine": empty,
    })
}

fn workspaces(s: &Session) -> Vec<Value> {
    let mut ws: Vec<Value> = s.niri(&["workspaces"]).as_array().unwrap().clone();
    ws.sort_by_key(|w| w["idx"].as_u64());
    ws
}

/// The named workspaces in niri's order.
fn numbers(s: &Session) -> Vec<String> {
    workspaces(s)
        .iter()
        .filter_map(|w| w["name"].as_str().map(str::to_owned))
        .collect()
}

fn focused(s: &Session) -> Option<String> {
    let ws = workspaces(s);
    let focused = ws.iter().find(|w| w["is_focused"] == true)?;
    focused["name"].as_str().map(str::to_owned)
}

fn cell_names(s: &Session) -> Vec<String> {
    s.workspace_cells()
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["name"].as_str().unwrap().to_owned())
        .collect()
}

/// The cells once the Row has placed them: new cells first report the Row's
/// origin, and a click there lands on the wrong one.
fn placed_cells(s: &Session) -> Value {
    let mut cells = Value::Null;
    s.wait_until("the cells to be laid out", || {
        cells = s.workspace_cells();
        let xs: Vec<f64> = cells
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c["x"].as_f64().unwrap())
            .collect();
        xs.windows(2).all(|w| w[0] < w[1])
    });
    cells
}

fn click_cell(s: &Session, name: &str) {
    let cells = placed_cells(s);
    let cell = cells
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["name"] == name)
        .unwrap_or_else(|| panic!("no cell {name} in {cells}"));
    let f = |k: &str| cell[k].as_f64().unwrap();
    s.point_at(f("x") + f("w") / 2.0, f("y") + f("h") / 2.0);
    s.click();
}

/// Goes to `n`, as Mod+n does, and opens a window there.
fn fill(s: &mut Session, n: &str) {
    s.run("niri-workspaces", &["focus", n]);
    s.open_window();
}

#[test]
fn going_to_a_number_creates_it() {
    let Some(s) = Session::start(&reviews()) else {
        return;
    };
    assert_eq!(numbers(&s), Vec::<String>::new());

    s.run("niri-workspaces", &["focus", "5"]);
    assert_eq!(numbers(&s), ["5"]);
    assert_eq!(focused(&s).as_deref(), Some("5"));
    s.wait_until("the bar to show it", || cell_names(&s) == ["5"]);
}

#[test]
fn a_number_left_empty_goes_away() {
    let Some(mut s) = Session::start(&reviews()) else {
        return;
    };
    s.run("niri-workspaces", &["focus", "5"]);
    fill(&mut s, "2");
    assert_eq!(numbers(&s), ["2"], "5 was left empty");

    s.run("niri-workspaces", &["focus", "7"]);
    s.run("niri-workspaces", &["focus", "2"]);
    assert_eq!(numbers(&s), ["2"], "7 was left empty, 2 has a window");
    // Only 2 and the empty workspace niri keeps at the end remain.
    assert_eq!(workspaces(&s).len(), 2);
}

#[test]
fn numbers_are_kept_in_order() {
    let Some(mut s) = Session::start(&reviews()) else {
        return;
    };
    fill(&mut s, "5");
    fill(&mut s, "12");
    fill(&mut s, "2");
    assert_eq!(numbers(&s), ["2", "5", "12"]);
    s.wait_until("the bar to follow", || cell_names(&s) == ["2", "5", "12"]);
}

#[test]
fn moving_a_column_creates_the_number_without_following_it() {
    let Some(mut s) = Session::start(&reviews()) else {
        return;
    };
    s.spawn("niri-workspaces", &["watch"]);
    s.open_window();
    s.wait_until("the watcher to number the window's workspace", || {
        numbers(&s) == ["1"]
    });

    s.run("niri-workspaces", &["move", "3"]);
    assert_eq!(numbers(&s), ["1", "3"]);
    assert_eq!(focused(&s).as_deref(), Some("1"), "focus stays");

    s.run("niri-workspaces", &["focus", "3"]);
    assert_eq!(numbers(&s), ["3"], "1 was left empty");
}

#[test]
fn the_watcher_drops_an_empty_number_left_by_other_means() {
    let Some(mut s) = Session::start(&reviews()) else {
        return;
    };
    s.spawn("niri-workspaces", &["watch"]);
    fill(&mut s, "1");
    s.run("niri-workspaces", &["focus", "4"]);
    // Mod+K: niri's own action, which knows nothing of numbers.
    s.run("niri", &["msg", "action", "focus-workspace-up"]);
    s.wait_until("the watcher to drop 4", || numbers(&s) == ["1"]);
}

#[test]
fn the_watcher_numbers_what_each_output_shows() {
    let Some(mut s) = Session::start_with_outputs(&reviews(), 2) else {
        return;
    };
    s.spawn("niri-workspaces", &["watch"]);
    s.wait_until("both outputs to show a number", || {
        let mut names = numbers(&s);
        names.sort();
        names == ["1", "2"]
    });

    // The output left with nothing gets the lowest free number.
    fill(&mut s, "1");
    s.run("niri", &["msg", "action", "move-workspace-to-monitor-next"]);
    s.wait_until("each output to show a number again", || {
        let ws = workspaces(&s);
        let mut names = numbers(&s);
        names.sort();
        names == ["1", "2"]
            && ws
                .iter()
                .filter(|w| w["is_active"] == true)
                .all(|w| w["name"].is_string())
    });
}

#[test]
fn an_empty_number_shown_on_another_output_stays() {
    let Some(mut s) = Session::start_with_outputs(&reviews(), 2) else {
        return;
    };
    s.run("niri", &["msg", "action", "focus-monitor-next"]);
    fill(&mut s, "2");
    s.run("niri-workspaces", &["focus", "6"]);
    s.run("niri", &["msg", "action", "focus-monitor-next"]);
    s.run("niri-workspaces", &["focus", "3"]);

    // 2 replaces 6 on its output, while 3 stays on screen on the other one.
    s.run("niri-workspaces", &["focus", "2"]);
    let mut names = numbers(&s);
    names.sort();
    assert_eq!(names, ["2", "3"], "6 was left empty, 3 is still shown");
    let three = workspaces(&s)
        .into_iter()
        .find(|w| w["name"] == "3")
        .unwrap();
    assert_eq!(three["is_active"], true);
}

#[test]
fn the_watcher_sends_assigned_apps_to_their_number() {
    let Some(mut s) = Session::start(&reviews()) else {
        return;
    };
    s.spawn(
        "niri-workspaces",
        &["watch", r"--assign=^org\.quickshell$=5"],
    );
    // Windows open before the watcher started are not new to it.
    s.wait_until("the watcher to start", || {
        std::fs::read_to_string(s.path("niri-workspaces.log")).is_ok_and(|l| l.contains("watching"))
    });

    s.open_window();
    s.wait_until("the window to land on 5", || {
        let ws = workspaces(&s);
        let window = &s.niri(&["windows"])[0];
        ws.iter()
            .any(|w| w["id"] == window["workspace_id"] && w["name"] == "5")
    });
    // The watcher named the workspace shown at its start 1, where the window
    // opened before it moved it.
    s.wait_until("only 1 and 5 to be left", || numbers(&s) == ["1", "5"]);
    assert_eq!(focused(&s).as_deref(), Some("1"), "focus stays on 1");
}

#[test]
fn clicking_a_cell_goes_to_that_number() {
    let Some(mut s) = Session::start(&reviews()) else {
        return;
    };
    fill(&mut s, "5");
    fill(&mut s, "3");
    s.wait_until("the bar's cells", || cell_names(&s) == ["3", "5"]);

    click_cell(&s, "5");
    s.wait_until("5 to take focus", || focused(&s).as_deref() == Some("5"));
    click_cell(&s, "3");
    s.wait_until("3 to take focus", || focused(&s).as_deref() == Some("3"));
}
