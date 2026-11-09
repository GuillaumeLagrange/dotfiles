//! Swapping a repo between a mirror symlink and a worktree, in both directions.

mod common;

use common::Fixture;

#[test]
fn add_swaps_a_symlink_for_a_worktree_in_place() {
    let f = Fixture::new();
    f.configure(&["app", "docs", "lib"], None);
    f.wt(&["new", "proj-1", "--repo", "app"]).ok();
    let s = f.session("proj-1");
    assert!(s.join("docs").symlink_metadata().unwrap().is_symlink());

    f.wt(&["add", "docs", "--session", "proj-1"])
        .ok()
        .says("docs joined proj-1");

    // The path is what shells, editors and Claude project dirs remember, so it is
    // the one thing that must not change.
    assert!(!s.join("docs").symlink_metadata().unwrap().is_symlink());
    assert!(s.join("docs/.git").exists());
    assert_eq!(
        f.git_in(&s.join("docs"), &["rev-parse", "HEAD"]),
        f.git("docs", &["rev-parse", "master"]),
        "docs did not fork from its own main branch"
    );
}

#[test]
fn add_refuses_what_it_cannot_do() {
    let f = Fixture::new();
    f.wt(&["new", "proj-1", "--repo", "app"]).ok();

    f.wt(&["add", "nonesuch", "--session", "proj-1"])
        .failed_with("not a git repo");
    assert!(
        !f.session("proj-1").join("nonesuch").exists(),
        "a hole was left in the mirror for a repo that does not exist"
    );

    f.wt(&["add", "app", "--session", "proj-1"])
        .failed_with("already a member");
}

#[test]
fn promote_hands_the_branch_to_the_main_checkout() {
    let f = Fixture::new();
    f.wt(&["new", "proj-1", "--repo", "app"]).ok();
    let s = f.session("proj-1");

    // Detached is the normal state, and there is nothing to hand over from it.
    f.wt(&["promote", "app", "--session", "proj-1"])
        .failed_with("detached HEAD");

    f.git_in(&s.join("app"), &["switch", "-qc", "proj-1-app"]);
    f.wt(&["promote", "app", "--session", "proj-1"]).ok();

    assert_eq!(
        f.git("app", &["branch", "--show-current"]),
        "proj-1-app",
        "the main checkout did not move onto the branch"
    );
    assert!(
        s.join("app").symlink_metadata().unwrap().is_symlink(),
        "the worktree was not swapped back for a symlink"
    );
    // Still reachable under the same path, now through the main checkout.
    assert!(s.join("app/README.md").exists());
}
