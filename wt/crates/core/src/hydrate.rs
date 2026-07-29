use std::path::Path;

use anyhow::{Context, Result};

use crate::config::Config;
use crate::util::{capture, which};
use crate::{envrc, git, util};

#[derive(Debug, Default)]
pub struct Report {
    pub copied: Vec<String>,
    pub failed: Vec<(String, String)>,
    pub direnv_allowed: bool,
}

/// Whether a git-ignored path is one the config asks for.
///
/// A pattern with no `/` matches a name at any depth, one with a `/` matches the
/// path from the repo root, and `*` stands for any run of characters within a
/// single name — the reading gitignore trains you to expect.
///
/// The point of the list being narrow is that it carries *environment*, not state
/// or build output: a `Session.vim` records absolute paths and a cwd, so a copy of
/// one restores the checkout it was written in, not the worktree it landed in.
fn wanted(patterns: &[String], path: &str) -> bool {
    patterns.iter().any(|pattern| {
        if pattern.contains('/') {
            glob(pattern, path)
        } else {
            glob(pattern, path.rsplit('/').next().unwrap_or(path))
        }
    })
}

/// `*` against a single name: it never matches across a `/`.
fn glob(pattern: &str, name: &str) -> bool {
    match pattern.split_once('*') {
        None => pattern == name,
        Some((head, tail)) => {
            let Some(rest) = name.strip_prefix(head) else {
                return false;
            };
            (0..=rest.len())
                .filter(|i| rest.is_char_boundary(*i))
                .filter(|i| !rest[..*i].contains('/'))
                .any(|i| glob(tail, &rest[i..]))
        }
    }
}

/// Containers whose contents belong to other checkouts, not to this one.
fn is_excluded(path: &str) -> bool {
    path == ".git"
        || path.starts_with(".git/")
        || path == ".worktrees"
        || path.starts_with(".worktrees/")
}

/// Copy a worktree's environment from the main checkout, then let direnv run
/// there.
///
/// `git worktree add` brings no ignored file, which on a globally-gitignored
/// `.envrc` means the flake environment is silently missing.
pub fn hydrate(cfg: &Config, main: &Path, worktree: &Path) -> Result<Report> {
    let mut report = Report::default();

    let ignored = git::ignored_paths(main)
        .with_context(|| format!("failed to list ignored paths in {}", main.display()))?;

    for rel in ignored {
        if is_excluded(&rel) {
            continue;
        }
        if !wanted(&cfg.hydrate, &rel) {
            continue;
        }
        let src = main.join(&rel);
        let dst = worktree.join(&rel);
        if util::exists(&dst) || !util::exists(&src) {
            continue;
        }
        if let Some(parent) = dst.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("failed to create {}", parent.display()))?;
        }
        let out = capture(
            "cp",
            &[
                "-a".as_ref(),
                "--reflink=auto".as_ref(),
                "-T".as_ref(),
                src.as_os_str(),
                dst.as_os_str(),
            ],
            None,
        )?;
        if out.ok() {
            report.copied.push(rel);
        } else {
            report.failed.push((rel, out.stderr.trim().to_string()));
        }
    }

    match allow_direnv(worktree) {
        Ok(allowed) => report.direnv_allowed = allowed,
        Err(err) => report.failed.push((envrc::FILE.into(), err.to_string())),
    }

    Ok(report)
}

/// Let direnv load the `.envrc` at `path`. Its allow list is keyed on the path,
/// so every new directory needs this once.
pub fn allow_direnv(path: &Path) -> Result<bool> {
    if !path.join(".envrc").exists() || which("direnv").is_none() {
        return Ok(false);
    }
    let out = capture("direnv", &["allow".as_ref(), path.as_os_str()], None)?;
    if !out.ok() {
        anyhow::bail!("{}", out.stderr.trim());
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn patterns(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn the_configured_patterns_decide() {
        let p = patterns(&[
            ".envrc",
            ".env*",
            ".claude/settings.local.json",
            "config/*.local.toml",
        ]);
        // A bare name matches at any depth, a path only from the repo root.
        assert!(wanted(&p, ".envrc"));
        assert!(wanted(&p, "apps/api/.envrc"));
        assert!(wanted(&p, "apps/api/.env.local"));
        assert!(wanted(&p, ".claude/settings.local.json"));
        assert!(!wanted(&p, "apps/api/.claude/settings.local.json"));
        assert!(wanted(&p, "config/db.local.toml"));
        assert!(!wanted(&p, "config/nested/db.local.toml"));
        assert!(!wanted(&p, "node_modules"));
        // State, not environment: it pins the checkout it was written in, and no
        // default pattern asks for it.
        assert!(!wanted(&p, "Session.vim"));
        assert!(!wanted(&[], ".envrc"));
    }

    #[test]
    fn a_star_stops_at_a_slash() {
        assert!(glob(".env*", ".env.local"));
        assert!(glob("*.local.json", "settings.local.json"));
        assert!(glob("a*c", "abc"));
        assert!(glob("a*c", "ac"));
        assert!(!glob("a*c", "abd"));
        assert!(!glob("a*c", "ab/c"));
    }

    #[test]
    fn git_internals_are_excluded() {
        assert!(is_excluded(".git"));
        assert!(is_excluded(".worktrees/proj-9"));
        assert!(!is_excluded("target"));
    }
}
