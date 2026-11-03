//! `wt main`: the main checkout's session and root, for other tools to open
//! things there.

mod common;

use common::Fixture;

#[test]
fn main_session_is_named_after_the_workspace_by_default() {
    let f = Fixture::new();
    assert_eq!(f.wt(&["main"]).ok().line(), "ws-main");
    assert_eq!(
        f.wt(&["main", "--path"]).ok().line(),
        f.workspace.display().to_string()
    );
}

#[test]
fn main_session_comes_from_the_config() {
    let f = Fixture::new();
    f.write_config(&format!(
        "workspace = \"{}\"\nmain_session = \"home\"\n",
        f.workspace.display()
    ));
    assert_eq!(f.wt(&["main"]).ok().line(), "home");
}
