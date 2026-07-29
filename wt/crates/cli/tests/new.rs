//! Creating a session: the mirror, the environment it carries, and what the members
//! are checked out at.

mod common;

use common::{have, Fixture};

#[test]
fn the_mirror_reproduces_the_whole_workspace() {
    let f = Fixture::new();
    f.wt(&["new", "proj-1", "--repo", "app", "--repo", "lib"]).ok();
    let s = f.session("proj-1");

    assert!(s.join("app/.git").exists(), "app is not a worktree");
    assert!(s.join("lib/.git").exists(), "lib is not a worktree");
    for linked in ["docs", "other", "flake"] {
        assert!(
            s.join(linked).symlink_metadata().unwrap().is_symlink(),
            "{linked} should be a symlink to the main checkout"
        );
    }
    let envrc = s.join(".envrc");
    assert!(
        envrc.is_file() && !envrc.symlink_metadata().unwrap().is_symlink(),
        ".envrc must be a real file, not a link to the workspace's"
    );
    assert!(
        !s.join("sessions").exists(),
        "the sessions root must not be mirrored into itself"
    );
}

#[test]
fn the_session_defers_to_the_workspace_and_says_nothing_about_the_root() {
    let f = Fixture::new();
    f.wt(&["new", "proj-1", "--repo", "app"]).ok();
    let s = f.session("proj-1");

    let envrc = f.read(&s.join(".envrc"));
    assert!(
        envrc.contains(&format!("source_env '{}/.envrc'", f.workspace.display())),
        "the session .envrc does not defer to the workspace's: {envrc}"
    );
    // The root is the multiplexer's to hand down: a directory-scoped variable is
    // unset again the moment a shell leaves the directory.
    assert!(
        !envrc.contains("WORKSPACE_ROOT"),
        "the session root must not come from direnv: {envrc}"
    );

    let marker = f.read(&s.join(".wt/session.json"));
    assert!(marker.contains("\"id\": \"proj-1\""), "{marker}");
    assert!(
        marker.contains(&format!("\"workspace\": \"{}\"", f.workspace.display())),
        "{marker}"
    );
}

#[test]
fn a_members_envrc_is_copied_as_it_stands() {
    let f = Fixture::new();
    f.wt(&["new", "proj-1", "--repo", "app", "--repo", "lib"]).ok();
    let s = f.session("proj-1");

    assert_eq!(
        f.read(&s.join("app/.envrc")),
        f.read(&f.path("app/.envrc")),
        "app's .envrc was rewritten"
    );
    assert_eq!(
        f.read(&s.join("lib/.envrc")),
        f.read(&f.path("lib/.envrc")),
        "lib's .envrc was rewritten"
    );
}

#[test]
fn hydration_carries_what_the_config_asks_for_and_nothing_else() {
    let f = Fixture::new();
    f.configure(&["app", "lib"], Some(&[".envrc", ".env*", "local.mk"]));
    f.wt(&["new", "proj-1", "--repo", "app"]).ok();
    let s = f.session("proj-1");

    for wanted in [".envrc", ".env", "local.mk"] {
        assert!(s.join("app").join(wanted).is_file(), "{wanted} was not carried");
    }
    assert!(
        !s.join("app/Session.vim").exists(),
        "Session.vim was copied; no pattern asks for it"
    );
    assert!(
        !s.join("app/node_modules").exists(),
        "node_modules was copied; that is a post-checkout hook's job"
    );
}

#[test]
fn members_are_detached_at_their_own_main_branch() {
    let f = Fixture::new();
    f.wt(&["new", "proj-1", "--repo", "app", "--repo", "lib"]).ok();
    let s = f.session("proj-1");

    assert_eq!(
        f.git_in(&s.join("app"), &["rev-parse", "--abbrev-ref", "HEAD"]),
        "HEAD",
        "app should be detached"
    );
    assert_eq!(
        f.git_in(&s.join("app"), &["rev-parse", "HEAD"]),
        f.git("app", &["rev-parse", "staging"]),
        "app did not fork from its own main branch"
    );
    // origin wins over the local branch, so a worktree never starts behind.
    assert_eq!(
        f.git_in(&s.join("lib"), &["rev-parse", "HEAD"]),
        f.git("lib", &["rev-parse", "origin/main"]),
        "lib did not fork from origin/main"
    );
    assert_eq!(
        f.git("app", &["branch", "--list", "proj-*"]),
        "",
        "a branch was invented for the session"
    );
}

#[test]
fn sibling_paths_resolve_as_they_do_in_the_workspace() {
    let f = Fixture::new();
    f.wt(&["new", "proj-1", "--repo", "app"]).ok();
    let s = f.session("proj-1");

    // What the mirror exists for: `../docs` from a member is a repo, not a hole.
    let toplevel = f.git_in(&s.join("app/../docs"), &["rev-parse", "--show-toplevel"]);
    assert_eq!(toplevel, f.path("docs").display().to_string());
}

#[test]
fn direnv_still_loads_the_workspace_environment() {
    if !have("direnv") {
        return;
    }
    let f = Fixture::new();
    f.wt(&["new", "proj-1", "--repo", "app"]).ok();
    let s = f.session("proj-1");

    for dir in [s.clone(), s.join("app")] {
        let out = std::process::Command::new("direnv")
            .args(["exec", &dir.display().to_string(), "sh", "-c", "echo $FROM_WORKSPACE"])
            .env("HOME", f.env_var("HOME"))
            .env("XDG_DATA_HOME", f.env_var("XDG_DATA_HOME"))
            .env("XDG_CONFIG_HOME", f.env_var("XDG_CONFIG_HOME"))
            .env("PATH", std::env::var("PATH").unwrap_or_default())
            .output()
            .expect("direnv should run");
        assert_eq!(
            String::from_utf8_lossy(&out.stdout).trim(),
            "1",
            "the workspace environment did not reach {}: {}",
            dir.display(),
            String::from_utf8_lossy(&out.stderr)
        );
    }
}

#[test]
fn an_unknown_config_key_is_an_error_rather_than_a_shrug() {
    let f = Fixture::new();
    f.write_config(&format!(
        "workspace = \"{}\"\nrepo = [\"app\"]\n",
        f.workspace.display()
    ));
    f.wt(&["ls"]).failed_with("unknown field `repo`");
}

#[test]
fn the_workspace_can_come_from_the_environment_instead() {
    let f = Fixture::new();
    f.write_config("");
    f.wt(&["ls"]).failed_with("no workspace to mirror");
    f.wt_with(&["ls"], &[("WT_WORKSPACE", &f.workspace.display().to_string())])
        .ok();
}

#[test]
fn a_name_that_is_not_a_directory_name_is_made_into_one() {
    let f = Fixture::new();
    f.wt(&["new", "COD-2931/nested name", "--empty"])
        .ok()
        .says("cod-2931-nested-name");
    assert!(f.session("cod-2931-nested-name").is_dir());
}

#[test]
fn a_session_is_never_created_twice() {
    let f = Fixture::new();
    f.wt(&["new", "proj-1", "--empty"]).ok();
    f.wt(&["new", "proj-1", "--empty"])
        .failed_with("already exists");
}
