//! Drift: what a session can become, and what `--fix` puts back.

mod common;

use common::Fixture;

#[test]
fn a_fresh_session_is_clean() {
    let f = Fixture::new();
    f.wt(&["new", "proj-1", "--repo", "app"]).ok();
    f.wt(&["sync", "proj-1"]).ok().says("clean");
}

#[test]
fn a_stripped_envrc_and_a_missing_marker_are_both_repaired() {
    let f = Fixture::new();
    f.wt(&["new", "proj-1", "--repo", "app"]).ok();
    let s = f.session("proj-1");
    std::fs::write(s.join(".envrc"), "export TAMPERED=1\n").unwrap();
    std::fs::remove_dir_all(s.join(".wt")).unwrap();

    let out = f.wt(&["sync", "proj-1"]).ok();
    assert!(out.stdout.contains(".envrc"), "{out}");
    assert!(out.stdout.contains("session.json"), "{out}");

    f.wt(&["sync", "proj-1", "--fix"]).ok();
    assert!(f
        .read(&s.join(".envrc"))
        .contains(&format!("source_env '{}/.envrc'", f.workspace.display())));
    assert!(s.join(".wt/session.json").is_file());
    f.wt(&["sync", "proj-1"]).ok().says("clean");
}

#[test]
fn a_repo_cloned_after_the_session_joins_the_mirror() {
    let f = Fixture::new();
    f.wt(&["new", "proj-1", "--repo", "app"]).ok();

    // A repo that did not exist when the mirror was built.
    std::fs::create_dir_all(f.path("tool")).unwrap();
    f.git("tool", &["init", "-q", "-b", "main"]);

    f.wt(&["sync", "proj-1"]).ok().says("mirror is missing `tool`");
    f.wt(&["sync", "proj-1", "--fix"]).ok();
    assert!(f
        .session("proj-1")
        .join("tool")
        .symlink_metadata()
        .unwrap()
        .is_symlink());
    f.wt(&["sync", "proj-1"]).ok().says("clean");
}

#[test]
fn a_link_to_a_removed_repo_is_unlinked_not_followed() {
    let f = Fixture::new();
    f.wt(&["new", "proj-1", "--repo", "app"]).ok();
    let s = f.session("proj-1");
    // `other` is a plain directory in the workspace, mirrored as a symlink.
    std::fs::remove_dir_all(f.path("other")).unwrap();

    f.wt(&["sync", "proj-1"])
        .ok()
        .says("`other` links to something that no longer exists");
    f.wt(&["sync", "proj-1", "--fix"]).ok();
    assert!(
        !s.join("other").symlink_metadata().is_ok(),
        "the dangling link is still there"
    );
    f.wt(&["sync", "proj-1"]).ok().says("clean");
}

#[test]
fn a_worktree_deleted_by_hand_is_pruned_and_relinked() {
    let f = Fixture::new();
    f.wt(&["new", "proj-1", "--repo", "app"]).ok();
    let s = f.session("proj-1");
    std::fs::remove_dir_all(s.join("app")).unwrap();

    f.wt(&["sync", "proj-1"]).ok().says("still records a worktree");
    f.wt(&["sync", "proj-1", "--fix"]).ok();
    // The path stays valid: the member becomes a link to the main checkout again.
    assert!(s.join("app").symlink_metadata().unwrap().is_symlink());
    f.wt(&["sync", "proj-1"]).ok().says("clean");
}

#[test]
fn sync_all_covers_every_session() {
    let f = Fixture::new();
    f.wt(&["new", "proj-1", "--empty"]).ok();
    f.wt(&["new", "proj-2", "--empty"]).ok();
    f.wt(&["sync", "--all"]).ok().says("proj-1").says("proj-2");
}
