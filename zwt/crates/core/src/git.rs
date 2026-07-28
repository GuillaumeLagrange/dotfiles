use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

use crate::util::{self, capture, checked};

#[derive(Debug, Clone)]
pub struct Worktree {
    pub path: PathBuf,
    pub branch: Option<String>,
    pub detached: bool,
    pub bare: bool,
}

pub fn is_repo(path: &Path) -> bool {
    path.join(".git").exists()
}

pub fn git(repo: &Path, args: &[&str]) -> Result<String> {
    checked("git", args, Some(repo))
}

pub fn git_ok(repo: &Path, args: &[&str]) -> bool {
    capture("git", args, Some(repo))
        .map(|o| o.ok())
        .unwrap_or(false)
}

pub fn worktrees(repo: &Path) -> Result<Vec<Worktree>> {
    let out = git(repo, &["worktree", "list", "--porcelain"])?;
    let mut list = Vec::new();
    let mut current: Option<Worktree> = None;
    for line in out.lines() {
        if let Some(path) = line.strip_prefix("worktree ") {
            if let Some(wt) = current.take() {
                list.push(wt);
            }
            current = Some(Worktree {
                path: PathBuf::from(path),
                branch: None,
                detached: false,
                bare: false,
            });
        } else if let Some(branch) = line.strip_prefix("branch ") {
            if let Some(wt) = current.as_mut() {
                wt.branch = Some(branch.trim_start_matches("refs/heads/").to_string());
            }
        } else if line == "detached" {
            if let Some(wt) = current.as_mut() {
                wt.detached = true;
            }
        } else if line == "bare" {
            if let Some(wt) = current.as_mut() {
                wt.bare = true;
            }
        }
    }
    if let Some(wt) = current {
        list.push(wt);
    }
    Ok(list)
}

/// The checkout git considers the main one: the first entry of `worktree list`.
pub fn main_worktree(repo: &Path) -> Result<PathBuf> {
    worktrees(repo)?
        .into_iter()
        .next()
        .map(|wt| wt.path)
        .with_context(|| format!("{} has no worktrees", repo.display()))
}

pub fn current_branch(path: &Path) -> Option<String> {
    let out = capture("git", &["branch", "--show-current"], Some(path)).ok()?;
    let name = out.stdout.trim().to_string();
    (out.ok() && !name.is_empty()).then_some(name)
}

/// Tried in order when the repo itself does not say which branch is its main one.
const USUAL_MAIN_BRANCHES: [&str; 5] = ["main", "master", "staging", "trunk", "develop"];

/// The branch new work forks from: `origin/HEAD`, then a `GIT_MAIN_BRANCH` that
/// resolves in this repo, then whichever usual name exists.
///
/// `GIT_MAIN_BRANCH` is verified rather than trusted: direnv exports it for
/// whichever repo the shell is standing in, so it can name a branch this one does
/// not have.
pub fn base_branch(repo: &Path) -> String {
    if let Ok(out) = capture(
        "git",
        &["symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
        Some(repo),
    ) {
        if out.ok() {
            if let Some(name) = out.stdout.trim().strip_prefix("origin/") {
                return name.to_string();
            }
        }
    }
    if let Ok(explicit) = std::env::var("GIT_MAIN_BRANCH") {
        if !explicit.is_empty() && branch_exists(repo, &explicit) {
            return explicit;
        }
    }
    USUAL_MAIN_BRANCHES
        .into_iter()
        .find(|name| branch_exists(repo, name))
        .unwrap_or("main")
        .to_string()
}

/// A revision `git worktree add` can actually fork from, preferring the remote
/// tip so a new worktree does not start behind the local checkout.
pub fn base_ref(repo: &Path) -> Result<String> {
    let base = base_branch(repo);
    for candidate in [format!("origin/{base}"), base.clone(), "HEAD".to_string()] {
        if git_ok(repo, &["rev-parse", "--verify", "--quiet", &candidate]) {
            return Ok(candidate);
        }
    }
    anyhow::bail!(
        "{}: nothing to branch from (no origin/{base}, no {base}, no HEAD)",
        repo.display()
    )
}

pub fn local_branch_exists(repo: &Path, branch: &str) -> bool {
    git_ok(
        repo,
        &[
            "show-ref",
            "--verify",
            "--quiet",
            &format!("refs/heads/{branch}"),
        ],
    )
}

pub fn remote_branch_exists(repo: &Path, branch: &str) -> bool {
    git_ok(
        repo,
        &[
            "show-ref",
            "--verify",
            "--quiet",
            &format!("refs/remotes/origin/{branch}"),
        ],
    )
}

pub fn branch_exists(repo: &Path, branch: &str) -> bool {
    local_branch_exists(repo, branch) || remote_branch_exists(repo, branch)
}

/// Create a detached worktree at `base`, returning the complaint of a
/// `post-checkout` hook that failed after the checkout itself succeeded.
///
/// Run from an interactive shell in the main checkout, because a repo's hooks
/// expect the toolchain that shell's per-directory hooks install: a hook that runs
/// `pnpm install` needs the node version fnm picks there, not the one zwt was
/// started with.
///
/// git reports a hook's exit status as its own, so a repo whose hook installs
/// dependencies fails the whole command over an unrelated toolchain mismatch —
/// with a complete, usable worktree already on disk.
pub fn add_worktree(repo: &Path, worktree: &Path, base: &str) -> Result<Option<String>> {
    let command = format!(
        "git worktree add --detach {} {}",
        util::shell_quote(&worktree.to_string_lossy()),
        util::shell_quote(base)
    );
    let out = util::shell_in(repo, &command)?;
    if out.ok() {
        return Ok(None);
    }
    let registered = worktrees(repo)
        .map(|list| list.iter().any(|wt| wt.path == worktree))
        .unwrap_or(false);
    anyhow::ensure!(
        registered,
        "`{command}` exited {}: {}",
        out.status,
        out.stderr.trim()
    );
    Ok(Some(out.stderr.trim().to_string()))
}

/// Whether a recorded worktree still has a checkout of its own behind it: a real
/// directory with a `.git`, rather than a path that is gone or a symlink standing
/// where the worktree used to be.
///
/// The symlink case is a mirror pointing at another checkout entirely. Following
/// it, `git worktree remove` refuses with `is not a .git file` — correctly, since
/// removing it would mean deleting that other checkout.
pub fn is_live_worktree(path: &Path) -> bool {
    !util::is_symlink(path) && path.join(".git").exists()
}

pub fn remove_worktree(repo: &Path, path: &Path, force: bool) -> Result<()> {
    let path = path.to_string_lossy().to_string();
    let mut args = vec!["worktree", "remove"];
    if force {
        args.push("--force");
    }
    args.push(&path);
    git(repo, &args)?;
    Ok(())
}

pub fn prune_worktrees(repo: &Path) -> Result<()> {
    git(repo, &["worktree", "prune"])?;
    Ok(())
}

/// Drop a record with nothing live behind it.
///
/// A symlink standing where the worktree was has to be unlinked first, because
/// `git worktree prune` keeps every record whose path still exists. Unlinking
/// never touches what the link points at.
pub fn prune_record(repo: &Path, path: &Path) -> Result<()> {
    if util::is_symlink(path) {
        std::fs::remove_file(path)
            .with_context(|| format!("failed to unlink {}", path.display()))?;
    }
    prune_worktrees(repo)
}

pub fn switch_branch(repo: &Path, branch: &str) -> Result<()> {
    git(repo, &["switch", branch])?;
    Ok(())
}

pub fn is_dirty(path: &Path) -> bool {
    capture("git", &["status", "--porcelain"], Some(path))
        .map(|o| o.ok() && !o.stdout.trim().is_empty())
        .unwrap_or(false)
}

/// Commits on HEAD that no remote ref contains, so nothing is lost by removing
/// the worktree. Works whether or not the branch has an upstream.
pub fn unpushed(path: &Path) -> usize {
    capture(
        "git",
        &["log", "--oneline", "HEAD", "--not", "--remotes"],
        Some(path),
    )
    .map(|o| if o.ok() { o.stdout.lines().count() } else { 0 })
    .unwrap_or(0)
}

/// Stash entries git recorded while on `branch`. Stashes are repo-wide, so the
/// `WIP on <branch>` subject is the only attribution available.
pub fn stashes_for_branch(repo: &Path, branch: &str) -> usize {
    let Ok(out) = capture("git", &["stash", "list", "--format=%gs"], Some(repo)) else {
        return 0;
    };
    if !out.ok() {
        return 0;
    }
    let on = format!(" on {branch}:");
    out.stdout.lines().filter(|l| l.contains(&on)).count()
}

/// Paths git ignores in `path`, relative to it. An ignored directory is one entry
/// rather than one per file inside it.
pub fn ignored_paths(path: &Path) -> Result<Vec<String>> {
    let out = git(
        path,
        &["status", "--porcelain", "--ignored=matching", "-uall"],
    )?;
    let mut paths = Vec::new();
    for line in out.lines() {
        let Some(rest) = line.strip_prefix("!! ") else {
            continue;
        };
        let rest = rest.trim();
        let rest = rest
            .strip_prefix('"')
            .and_then(|r| r.strip_suffix('"'))
            .unwrap_or(rest);
        let rest = rest.trim_end_matches('/');
        if rest.is_empty() {
            continue;
        }
        paths.push(rest.to_string());
    }
    Ok(paths)
}

pub fn fetch(repo: &Path) -> Result<()> {
    git(repo, &["fetch", "--quiet", "origin"])?;
    Ok(())
}
