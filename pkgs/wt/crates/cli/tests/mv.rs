//! Renaming, which moves worktrees git has to be told about.

mod common;

use common::Fixture;

#[test]
fn mv_moves_the_directory_and_keeps_the_worktrees_working() {
    let f = Fixture::new();
    f.wt(&["new", "proj-1", "--repo", "app", "--title", "Proj"])
        .ok();
    let old = f.session("proj-1");
    f.git_in(&old.join("app"), &["switch", "-qc", "work"]);
    f.write("sessions/proj-1/app/README.md", "edited\n");
    // A repo created in the session, with no main checkout in the workspace.
    std::fs::create_dir(old.join("scratch")).unwrap();
    f.git_in(&old.join("scratch"), &["init", "-q"]);

    f.wt(&["mv", "proj-1", "Proj 2"])
        .ok()
        .says("proj-1 -> proj-2");
    let new = f.session("proj-2");
    assert!(!old.exists(), "the old directory is still there");

    assert_eq!(
        f.wt(&["path", "--exact", "proj-2"]).ok().line(),
        new.display().to_string()
    );
    f.wt(&["path", "--exact", "proj-1"])
        .failed_with("no session");
    assert!(f
        .read(&new.join(".wt/session.json"))
        .contains("\"id\": \"proj-2\""));
    f.wt(&["ls"]).ok().says("Proj");

    // git follows the move: the record points at the new path, the branch is still
    // held by it, and the uncommitted change came along.
    let list = f.git("app", &["worktree", "list", "--porcelain"]);
    assert!(
        list.contains(&format!("worktree {}", new.join("app").display())),
        "{list}"
    );
    assert!(!list.contains("prunable"), "{list}");
    assert_eq!(
        f.git_in(&new.join("app"), &["status", "--porcelain"]),
        "M README.md"
    );

    // And it is still the guarded session it was.
    f.wt(&["rm", "proj-2"]).failed_with("still holds work");
}

#[test]
fn mv_keeps_a_directory_placed_with_at() {
    let f = Fixture::new();
    let at = f.root.join("elsewhere");
    f.wt(&["new", "proj-1", "--empty", "--at", at.to_str().unwrap()])
        .ok();

    f.wt(&["rename", "proj-1", "proj-2"]).ok();
    assert_eq!(
        f.wt(&["path", "--exact", "proj-2"]).ok().line(),
        at.display().to_string()
    );
    assert!(!f.session("proj-2").exists());
}

#[test]
fn mv_refuses_a_name_already_taken() {
    let f = Fixture::new();
    f.wt(&["new", "proj-1", "--empty"]).ok();
    f.wt(&["new", "proj-2", "--empty"]).ok();

    f.wt(&["mv", "proj-1", "proj-2"])
        .failed_with("already exists");
    assert!(f.session("proj-1").is_dir());
}
