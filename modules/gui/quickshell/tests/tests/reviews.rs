//! The reviews pill and its panel, driven the way a user does: a click on the
//! pill, keys typed into the panel.

use quickshell_tests::Session;
use serde_json::{json, Value};

fn pr(number: u64, repo: &str, title: &str, author: &str, place: &str, branch: &str) -> Value {
    json!({
        "kind": "pr", "place": place, "number": number, "title": title, "repo": repo,
        "url": format!("https://github.com/acme/{repo}/pull/{number}"), "branch": branch,
        "state": "Open", "draft": false, "updated_at": 1_700_000_000, "listed": true,
        "additions": 1, "deletions": 1, "author": author, "avatar": null,
        "decision": null, "checks": "Success"
    })
}

fn tab(rows: Vec<Value>) -> Value {
    let count = rows.iter().filter(|r| r["kind"] == "pr").count();
    json!({ "count": count, "stale": 0, "rows": rows, "all": rows })
}

fn url(repo: &str, number: u64) -> String {
    format!("https://github.com/acme/{repo}/pull/{number}")
}

/// Two PRs to review, the first linked to a Linear issue, a stack and a lone
/// PR reviewed, two of mine.
fn reviews() -> Value {
    let mut linked = pr(101, "app", "Speed up the parser", "alice", "alone", "fast");
    linked["linear"] = json!([{
        "identifier": "ENG-42", "title": "Parsing is slow", "state": "In Progress",
        "kind": "started", "url": "https://linear.app/acme/issue/ENG-42"
    }]);
    json!({
        "snapshot": "",
        "fetched_at": 1_700_000_000,
        "requested": tab(vec![
            linked,
            pr(102, "web", "Fix flaky login test", "bob", "alone", "flaky"),
        ]),
        "reviewed": tab(vec![
            json!({ "kind": "stack", "repo": "app", "size": 2, "base": "main" }),
            pr(201, "app", "Split the tokenizer", "carol", "child", "split"),
            pr(202, "app", "Parser error recovery", "carol", "last", "recover"),
            pr(203, "app", "Bump dependencies", "dave", "alone", "bump"),
        ]),
        "mine": tab(vec![
            pr(301, "app", "Add dark mode", "me", "alone", "dark-mode"),
            pr(302, "web", "Drop legacy API", "me", "alone", "drop-legacy"),
        ]),
    })
}

fn open(s: &Session) {
    s.point_at_pill();
    s.click();
    s.wait_for("the panel to open", |st| st["open"] == true);
}

/// As a keyboard sends it: xkb's second level of Tab is ISO_Left_Tab. wtype
/// gives each keysym a one-level key, so a shifted Tab would stay Tab.
fn shift_tab(s: &Session) {
    s.wtype(&["-M", "shift", "-k", "ISO_Left_Tab", "-m", "shift"]);
}

#[test]
fn hovering_the_pill_does_not_open_the_panel_and_clicking_toggles_it() {
    let Some(s) = Session::start(&reviews()) else {
        return;
    };
    s.point_at_pill();
    // Longer than the hover panels' dwell.
    std::thread::sleep(std::time::Duration::from_millis(800));
    assert_eq!(s.state()["open"], false);

    s.click();
    s.wait_for("the panel to open", |st| st["open"] == true);
    // The pill's click used to refresh; the panel's button does now.
    assert!(s.recorded("refresh.log").is_empty());

    s.click();
    s.wait_for("the panel to close", |st| st["open"] == false);
}

#[test]
fn typing_filters_the_tab_and_escape_clears_before_closing() {
    let Some(s) = Session::start(&reviews()) else {
        return;
    };
    open(&s);
    let st = s.state();
    assert_eq!(st["matching"], json!([101, 102]));
    assert_eq!(st["cursor"], url("app", 101));

    s.wtype(&["flaky"]);
    let st = s.wait_for("the query", |st| st["query"] == "flaky");
    assert_eq!(st["matching"], json!([102]));
    // On the best match, so Enter takes it.
    assert_eq!(st["cursor"], url("web", 102));

    s.key("BackSpace");
    s.wait_for("one character less", |st| st["query"] == "flak");

    s.key("Escape");
    let st = s.wait_for("the query cleared", |st| st["query"] == "");
    assert_eq!(st["open"], true);
    assert_eq!(st["matching"], json!([101, 102]));

    s.key("Escape");
    s.wait_for("the panel to close", |st| st["open"] == false);
}

#[test]
fn typing_a_linear_issue_finds_its_pr() {
    let Some(s) = Session::start(&reviews()) else {
        return;
    };
    open(&s);
    s.wtype(&["ENG-42"]);
    let st = s.wait_for("the query", |st| st["query"] == "ENG-42");
    assert_eq!(st["matching"], json!([101]));
}

#[test]
fn tab_and_shift_tab_cycle_the_tabs() {
    let Some(s) = Session::start(&reviews()) else {
        return;
    };
    open(&s);
    assert_eq!(s.state()["tab"], "requested");

    s.key("Tab");
    let st = s.wait_for("the reviewed tab", |st| st["tab"] == "reviewed");
    // Not on the stack's heading: on its first PR.
    s.wait_for("the cursor on the tab's first PR", |st| {
        st["cursor"] == url("app", 201)
    });
    assert_eq!(st["matching"], json!(["stack", 201, 202, 203]));

    s.key("Tab");
    s.wait_for("the mine tab", |st| {
        st["tab"] == "mine" && st["cursor"] == url("app", 301)
    });
    s.key("Tab");
    s.wait_for("back to the first tab", |st| st["tab"] == "requested");

    shift_tab(&s);
    s.wait_for("the last tab", |st| st["tab"] == "mine");
}

#[test]
fn a_filter_lists_a_stacks_members_without_its_heading() {
    let Some(s) = Session::start(&reviews()) else {
        return;
    };
    open(&s);
    s.key("Tab");
    s.wait_for("the reviewed tab", |st| st["tab"] == "reviewed");

    s.wtype(&["parser"]);
    let st = s.wait_for("the query", |st| st["query"] == "parser");
    assert_eq!(st["matching"], json!([202]));
    assert_eq!(st["cursor"], url("app", 202));
}

#[test]
fn arrows_move_the_cursor_and_enter_opens_the_pr() {
    let Some(s) = Session::start(&reviews()) else {
        return;
    };
    open(&s);

    s.key("Down");
    s.wait_for("the second PR", |st| st["cursor"] == url("web", 102));
    s.key("Down");
    // Stays on the last.
    std::thread::sleep(std::time::Duration::from_millis(200));
    assert_eq!(s.state()["cursor"], url("web", 102));

    s.key("Return");
    s.wait_for("the panel to close", |st| st["open"] == false);
    s.wait_for_record("review.log", &format!("--pr {}", url("web", 102)));
}

#[test]
fn enter_on_my_pr_opens_its_branch() {
    let Some(s) = Session::start(&reviews()) else {
        return;
    };
    open(&s);
    shift_tab(&s);
    s.wait_for("the mine tab", |st| {
        st["tab"] == "mine" && st["cursor"] == url("app", 301)
    });

    s.key("Return");
    s.wait_for_record(
        "review.log",
        &format!("--mine {} dark-mode", url("app", 301)),
    );
}
