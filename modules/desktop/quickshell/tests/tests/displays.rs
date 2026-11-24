//! Saved display setups: `niri-displays` against niri's headless outputs.

use quickshell_tests::Session;
use serde_json::{json, Value};

/// Two outputs, the first pinned at the origin: one niri places itself moves
/// out of the way of the other, which would make the layouts below its choice.
fn session() -> Option<Session> {
    let empty = json!({ "count": 0, "stale": 0, "rows": [], "all": [] });
    let reviews = json!({
        "snapshot": "", "fetched_at": 1_700_000_000,
        "requested": empty, "reviewed": empty, "mine": empty,
    });
    let s = Session::start_with_outputs(&reviews, 2)?;
    place(&s, "HEADLESS-1", 0, 0);
    Some(s)
}

fn displays(s: &Session, args: &[&str]) -> String {
    s.run("niri-displays", args)
}

fn list(s: &Session) -> Value {
    serde_json::from_str(&displays(s, &["list"])).unwrap()
}

/// The setups' names whose layout is the one on screen.
fn active(s: &Session) -> Vec<String> {
    list(s)["setups"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|s| s["active"] == true)
        .map(|s| s["name"].as_str().unwrap().to_owned())
        .collect()
}

/// Each output's logical position.
fn layout(s: &Session) -> Vec<(String, i64, i64)> {
    let outputs = s.niri(&["outputs"]);
    let mut layout: Vec<_> = outputs
        .as_object()
        .unwrap()
        .iter()
        .map(|(name, o)| {
            let l = &o["logical"];
            (
                name.clone(),
                l["x"].as_i64().unwrap(),
                l["y"].as_i64().unwrap(),
            )
        })
        .collect();
    layout.sort();
    layout
}

fn place(s: &Session, output: &str, x: i64, y: i64) {
    s.run(
        "niri",
        &[
            "msg",
            "output",
            output,
            "position",
            "set",
            "--",
            &x.to_string(),
            &y.to_string(),
        ],
    );
}

#[test]
fn saved_setups_apply_and_cycle() {
    let Some(s) = session() else { return };
    assert_eq!(list(&s)["setups"], json!([]));

    place(&s, "HEADLESS-2", 1920, 0);
    displays(&s, &["save", "side"]);
    let side = layout(&s);
    place(&s, "HEADLESS-2", -1920, 0);
    displays(&s, &["save", "left"]);
    let left = layout(&s);
    assert_eq!(active(&s), ["left"]);

    displays(&s, &["apply", "side"]);
    assert_eq!(layout(&s), side);
    assert_eq!(active(&s), ["side"]);

    // Mod+M opens the control centre on the setup after the one on screen, in
    // saved order and wrapping around; Enter applies it and closes the panel.
    s.ipc("displays", "next");
    control_centre(&s, "the next setup", |c| {
        c["open"] == true && c["cursor"] == "left"
    });
    s.ipc("displays", "next");
    control_centre(&s, "wrapping around", |c| c["cursor"] == "side");
    s.ipc("displays", "prev");
    control_centre(&s, "the setup before", |c| {
        c["cursor"] == "left" && c["focused"] == true
    });
    assert_eq!(active(&s), ["side"]);
    s.key("Return");
    control_centre(&s, "the panel to close", |c| c["open"] == false);
    s.wait_until("the setup to apply", || layout(&s) == left);

    // Saving under an existing name replaces it, in place.
    place(&s, "HEADLESS-2", 0, 1080);
    displays(&s, &["save", "side"]);
    assert_eq!(names(&s), ["side", "left"]);
    assert_eq!(active(&s), ["side"]);

    displays(&s, &["delete", "left"]);
    assert_eq!(names(&s), ["side"]);
}

fn names(s: &Session) -> Vec<String> {
    list(s)["setups"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["name"].as_str().unwrap().to_owned())
        .collect()
}

#[test]
fn setups_are_renamed_and_reordered() {
    let Some(s) = session() else { return };
    for (name, x, y) in [("a", 1920, 0), ("b", -1920, 0), ("c", 0, 1080)] {
        place(&s, "HEADLESS-2", x, y);
        displays(&s, &["save", name]);
    }

    displays(&s, &["rename", "b", "middle"]);
    assert_eq!(names(&s), ["a", "middle", "c"]);
    // A name already taken is refused, and nothing changes.
    assert!(!s.succeeds("niri-displays", &["rename", "a", "c"]));
    assert_eq!(names(&s), ["a", "middle", "c"]);

    // Setups left out of the order keep theirs, after the others.
    displays(&s, &["order", "c", "a"]);
    assert_eq!(names(&s), ["c", "a", "middle"]);
}

/// Waits for the focused output's control centre to reach a state.
fn control_centre(s: &Session, what: &str, pred: impl Fn(&Value) -> bool) {
    s.wait_until(what, || pred(&s.control_centre()));
}

/// An open panel moves to the output focus moves to, as the launcher does.
#[test]
fn panels_follow_the_focused_output() {
    let Some(s) = session() else { return };
    s.ipc("notifs", "center");
    control_centre(&s, "the panel to open", |c| c["open"] == true);

    s.run("niri", &["msg", "action", "focus-monitor-next"]);
    control_centre(&s, "the panel on the other output", |c| {
        c["open"] == true && c["focused"] == true
    });
}

/// A setup fits wherever the monitors it turns on are connected, whatever the
/// others: one saved while a monitor was connected and off fits without it,
/// and one turning a single monitor on is not on screen while another is on.
/// (niri's headless backend cannot turn an output off, so the files are written.)
#[test]
fn setups_fit_whatever_other_monitors() {
    let Some(s) = session() else { return };
    let connected = list(&s)["connected"].clone();
    let mut office = connected[0].clone();
    office["id"] = json!("Dell Inc. DELL P2423D FN44W14");
    office["on"] = json!(false);
    let dir = s.path("state/niri-displays");
    std::fs::create_dir_all(&dir).unwrap();
    let setups = json!({ "setups": [{
        "name": "laptop", "used": 0, "outputs": [connected[0], office],
    }]});
    std::fs::write(dir.join("setups.json"), setups.to_string()).unwrap();

    let laptop = &list(&s)["setups"][0];
    assert_eq!(laptop["fits"], true);
    assert_eq!(laptop["outputs"].as_array().unwrap().len(), 1);
    assert_eq!(active(&s), Vec::<String>::new());
}

/// A setup saved for other monitors neither fits nor applies.
#[test]
fn setups_for_other_monitors_do_not_apply() {
    let Some(s) = session() else { return };
    let dir = s.path("state/niri-displays");
    std::fs::create_dir_all(&dir).unwrap();
    let other = json!({ "setups": [{
        "name": "office", "used": 0,
        "outputs": [{ "id": "Dell Inc. DELL P2423D FN44W14", "label": "P2423D", "on": true,
            "mode": { "width": 2560, "height": 1440, "refresh_rate": 75000 },
            "scale": 1.0, "transform": "Normal", "x": 0, "y": 0, "w": 2560, "h": 1440 }],
    }]});
    std::fs::write(dir.join("setups.json"), other.to_string()).unwrap();
    let before = layout(&s);

    assert_eq!(list(&s)["setups"][0]["fits"], false);
    assert!(!s.succeeds("niri-displays", &["apply", "office"]));
    assert_eq!(layout(&s), before);
}

/// The watcher applies the last used setup of the connected monitors when it
/// first sees them, as at login or once a monitor is plugged in. At login, it
/// focuses the top-left output, which takes the cursor along.
#[test]
fn watcher_applies_the_last_used_setup() {
    let Some(mut s) = session() else { return };
    place(&s, "HEADLESS-2", 0, 1080);
    displays(&s, &["save", "stacked"]);
    let stacked = layout(&s);
    place(&s, "HEADLESS-2", 1920, 0);
    displays(&s, &["save", "side"]);
    displays(&s, &["apply", "stacked"]);
    place(&s, "HEADLESS-2", -1920, 0);
    s.run("niri", &["msg", "action", "focus-monitor", "HEADLESS-2"]);
    assert_eq!(s.niri(&["focused-output"])["name"], "headless-2");

    s.spawn("niri-displays", &["watch"]);
    s.wait_until("the watcher to apply the setup", || layout(&s) == stacked);
    assert_eq!(s.niri(&["focused-output"])["name"], "headless-1");

    // Once applied, a layout changed by hand is left alone.
    place(&s, "HEADLESS-2", 1920, 0);
    std::thread::sleep(std::time::Duration::from_secs(1));
    assert_eq!(active(&s), ["side"]);
}
