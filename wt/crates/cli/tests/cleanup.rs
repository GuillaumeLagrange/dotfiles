//! Teardown, which is the half of wt that must not lose work.

mod common;

use common::Fixture;

#[test]
fn rm_refuses_while_a_member_still_holds_work() {
    let f = Fixture::new();
    f.wt(&["new", "proj-1", "--repo", "app"]).ok();
    let s = f.session("proj-1");
    f.write("sessions/proj-1/app/README.md", "edited\n");

    f.wt(&["rm", "proj-1"]).failed_with("still holds work");
    assert!(s.is_dir(), "the session was removed anyway");

    f.wt(&["rm", "proj-1", "--force"]).ok().says("removed proj-1");
    assert!(!s.exists());
}

#[test]
fn rm_reports_every_reason_it_refused() {
    let f = Fixture::new();
    f.wt(&["new", "proj-1", "--repo", "app"]).ok();
    let s = f.session("proj-1");

    f.git_in(&s.join("app"), &["switch", "-qc", "work"]);
    f.write("sessions/proj-1/app/README.md", "committed\n");
    f.git_in(&s.join("app"), &["commit", "-aqm", "work"]);
    f.write("sessions/proj-1/app/untracked.txt", "loose\n");

    let out = f.wt(&["rm", "proj-1"]).failed_with("still holds work");
    for reason in ["uncommitted changes", "no remote has"] {
        assert!(out.stderr.contains(reason), "expected `{reason}` in {out}");
    }
}

#[test]
fn rm_never_follows_a_mirror_symlink() {
    let f = Fixture::new();
    f.wt(&["new", "proj-1", "--repo", "app"]).ok();
    f.wt(&["rm", "proj-1", "--force"]).ok();

    // The link pointed at the main checkout: unlinking it must not have reached
    // through to what it pointed at.
    assert!(f.path("docs/README.md").is_file(), "the main checkout lost files");
    assert!(f.path("app/README.md").is_file());
    assert_eq!(f.git("app", &["branch", "--list", "proj-*"]), "");
}

#[test]
fn a_session_deleted_by_hand_leaves_no_phantom_worktrees() {
    let f = Fixture::new();
    f.wt(&["new", "proj-1", "--repo", "app"]).ok();
    std::fs::remove_dir_all(f.session("proj-1")).unwrap();

    // The registry entry goes on the next read, but git still records a worktree,
    // which keeps any branch it held claimed.
    let out = f.wt(&["sync", "--all"]).ok();
    assert!(out.stdout.contains("worktree record"), "{out}");

    f.wt(&["sync", "--all", "--fix"]).ok().says("pruned");
    assert_eq!(
        f.git("app", &["worktree", "list", "--porcelain"])
            .matches("worktree ")
            .count(),
        1,
        "a worktree record survived the prune"
    );
}

#[test]
fn the_registry_forgets_a_session_whose_directory_is_gone() {
    let f = Fixture::new();
    f.wt(&["new", "proj-1", "--empty"]).ok();
    std::fs::remove_dir_all(f.session("proj-1")).unwrap();

    f.wt(&["ls"]).ok().silent_about("proj-1");
    f.wt(&["path", "proj-1"]).failed_with("no session");
}
