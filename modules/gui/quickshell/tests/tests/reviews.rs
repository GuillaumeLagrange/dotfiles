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

/// Two PRs to review, the first linked to two Linear issues, a stack and a lone
/// PR reviewed, two of mine.
fn reviews() -> Value {
    let mut linked = pr(101, "app", "Speed up the parser", "alice", "alone", "fast");
    linked["linear"] = json!([
        {
            "identifier": "ENG-42", "title": "Parsing is slow", "state": "In Progress",
            "kind": "started", "url": "https://linear.app/acme/issue/ENG-42"
        },
        {
            "identifier": "ENG-43", "title": "Lexer allocates", "state": "Todo",
            "kind": "unstarted", "url": "https://linear.app/acme/issue/ENG-43"
        }
    ]);
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

fn ctrl(s: &Session, key: &str) {
    s.wtype(&["-M", "ctrl", "-k", key, "-m", "ctrl"]);
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
fn the_ipc_call_of_mod_quote_toggles_the_panel() {
    let Some(s) = Session::start(&reviews()) else {
        return;
    };
    let shell = s.path("shell");
    let call = [
        "-p",
        shell.to_str().unwrap(),
        "ipc",
        "call",
        "reviews",
        "panel",
    ];
    s.run("qs", &call);
    s.wait_for("the panel to open", |st| st["open"] == true);
    // Focused as it maps, so the keys work without a click.
    s.key("Down");
    s.wait_for("the first PR", |st| st["cursor"] == url("app", 101));

    s.run("qs", &call);
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
    // No cursor until an arrow or a query puts one.
    assert_eq!(st["cursor"], "");

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
    s.key("Down");
    s.wait_for("the first PR", |st| st["cursor"] == url("app", 101));

    s.key("Tab");
    let st = s.wait_for("the reviewed tab", |st| st["tab"] == "reviewed");
    assert_eq!(st["matching"], json!(["stack", 201, 202, 203]));
    // A new tab starts without a cursor; Down skips the stack's heading.
    s.wait_for("no cursor", |st| st["cursor"] == "");
    s.key("Down");
    s.wait_for("the tab's first PR", |st| st["cursor"] == url("app", 201));

    s.key("Tab");
    s.wait_for("the mine tab", |st| st["tab"] == "mine");
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
    s.wait_for("the first PR", |st| st["cursor"] == url("app", 101));
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
fn ctrl_n_and_ctrl_p_move_the_cursor() {
    let Some(s) = Session::start(&reviews()) else {
        return;
    };
    open(&s);

    ctrl(&s, "n");
    s.wait_for("the first PR", |st| st["cursor"] == url("app", 101));
    ctrl(&s, "n");
    s.wait_for("the second PR", |st| st["cursor"] == url("web", 102));
    ctrl(&s, "p");
    let st = s.wait_for("back on the first", |st| st["cursor"] == url("app", 101));
    assert_eq!(st["query"], "");
}

#[test]
fn left_and_right_reach_the_linear_issues_and_enter_opens_one() {
    let Some(s) = Session::start(&reviews()) else {
        return;
    };
    open(&s);
    s.key("Down");
    s.wait_for("the first PR", |st| st["cursor"] == url("app", 101));

    s.key("Right");
    s.wait_for("the first issue", |st| st["issueCursor"] == 0);
    s.key("Right");
    s.wait_for("the second issue", |st| st["issueCursor"] == 1);
    s.key("Right");
    // Stays on the last.
    std::thread::sleep(std::time::Duration::from_millis(200));
    assert_eq!(s.state()["issueCursor"], 1);
    s.key("Left");
    s.key("Left");
    s.wait_for("back on the PR", |st| st["issueCursor"] == -1);

    // Moving to another PR leaves the issues.
    s.key("Right");
    s.wait_for("the first issue", |st| st["issueCursor"] == 0);
    s.key("Down");
    s.wait_for("the second PR", |st| {
        st["cursor"] == url("web", 102) && st["issueCursor"] == -1
    });
    s.key("Up");
    s.key("Right");
    s.key("Right");
    s.wait_for("the second issue", |st| {
        st["cursor"] == url("app", 101) && st["issueCursor"] == 1
    });

    s.key("Return");
    s.wait_for("the panel to close", |st| st["open"] == false);
    s.wait_for_record("open-url.log", "https://linear.app/acme/issue/ENG-43");
    assert!(s.recorded("review.log").is_empty());
}

#[test]
fn clicking_a_linear_issue_opens_it_not_the_pr() {
    let Some(s) = Session::start(&reviews()) else {
        return;
    };
    open(&s);
    let st = s.state();
    let chip = &st["chips"]["ENG-42"];
    let f = |k: &str| chip[k].as_f64().unwrap();
    s.point_at(f("x") + f("w") / 2.0, f("y") + f("h") / 2.0);
    s.click();

    s.wait_for("the panel to close", |st| st["open"] == false);
    s.wait_for_record("open-url.log", "https://linear.app/acme/issue/ENG-42");
    // The card's own tap would have spawned it by now.
    std::thread::sleep(std::time::Duration::from_millis(300));
    assert!(s.recorded("review.log").is_empty());
}

#[test]
fn it_opens_on_the_pr_of_the_focused_review_tab() {
    let Some(s) = Session::start(&reviews()) else {
        return;
    };
    std::fs::write(s.path("tab"), "app#202\n").unwrap();
    open(&s);
    // Found in another tab than the last picked one, which it switches to.
    s.wait_for("the reviewed tab on its PR", |st| {
        st["tab"] == "reviewed" && st["cursor"] == url("app", 202)
    });

    s.key("Return");
    s.wait_for_record("review.log", &format!("--pr {}", url("app", 202)));
}

#[test]
fn a_tab_that_is_no_review_leaves_no_cursor() {
    let Some(s) = Session::start(&reviews()) else {
        return;
    };
    std::fs::write(s.path("tab"), "app\n").unwrap();
    open(&s);
    std::thread::sleep(std::time::Duration::from_millis(300));
    let st = s.state();
    assert_eq!(st["tab"], "requested");
    assert_eq!(st["cursor"], "");
}

#[test]
fn enter_on_my_pr_opens_its_branch() {
    let Some(s) = Session::start(&reviews()) else {
        return;
    };
    open(&s);
    shift_tab(&s);
    s.wait_for("the mine tab", |st| st["tab"] == "mine");
    s.key("Down");
    s.wait_for("my first PR", |st| st["cursor"] == url("app", 301));

    s.key("Return");
    s.wait_for_record(
        "review.log",
        &format!("--mine {} dark-mode", url("app", 301)),
    );
}
