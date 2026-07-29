//! A repo's own `post-checkout` hook, which is where installing dependencies
//! belongs. It needs the toolchain a shell's per-directory hooks provide, and it
//! must not be able to cost anyone a worktree.

mod common;

use common::Fixture;

fn install_hook(f: &Fixture, repo: &str, body: &str) {
    f.git(repo, &["config", "core.hooksPath", ".hooks"]);
    f.write(&format!("{repo}/.hooks/post-checkout"), body);
    let path = f.path(&format!("{repo}/.hooks/post-checkout"));
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

#[test]
fn the_hook_runs_with_an_interactive_shells_environment() {
    let f = Fixture::new();
    let seen = f.root.join("hookenv.txt");
    install_hook(
        &f,
        "lib",
        &format!(
            "#!/bin/sh\nprintf 'FROM_SHELL_RC=%s\\n' \"${{FROM_SHELL_RC:-<unset>}}\" > {}\n",
            seen.display()
        ),
    );

    let shell = f.stub_shell("rc-shell", "export FROM_SHELL_RC=1\n");
    f.wt_with(&["new", "proj-1", "--repo", "lib"], &[("SHELL", &shell)])
        .ok();

    assert_eq!(
        std::fs::read_to_string(&seen).unwrap_or_default().trim(),
        "FROM_SHELL_RC=1",
        "the hook ran outside the shell"
    );
}

#[test]
fn a_failing_hook_is_reported_but_costs_nothing() {
    let f = Fixture::new();
    // What a pnpm-install hook does when the node it wants is not on PATH. git
    // reports the hook's status as its own, so the checkout looks like a failure
    // while being perfectly complete.
    install_hook(
        &f,
        "app",
        "#!/bin/sh\necho 'pretend pnpm install failed' >&2\nexit 1\n",
    );

    let out = f
        .wt(&["new", "proj-1", "--repo", "app", "--repo", "lib"])
        .ok();
    assert!(
        out.stderr.contains("a git hook failed"),
        "the hook failure was not reported: {out}"
    );

    let s = f.session("proj-1");
    assert!(s.join("app/.git").exists(), "the worktree was discarded");
    assert!(s.join("lib/.git").exists(), "a later member was skipped");
    assert!(
        s.join("app/.envrc").is_file(),
        "hydration was skipped after the hook failed"
    );
    f.wt(&["ls"]).ok().says("proj-1");
}
