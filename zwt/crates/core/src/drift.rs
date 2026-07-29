//! What a session can drift into, and how to put it back. Every repair lives
//! here; no other command mutates a session to fix it.

use anyhow::Result;

use crate::config::Config;
use crate::session::{RepoState, Session};
use crate::util::capture;
use crate::workspace::{self, Reproduce};
use crate::{envrc, git, hydrate, mirror, session, util};

#[derive(Debug, Clone)]
pub enum Drift {
    /// A workspace entry the mirror predates.
    MirrorEntryMissing {
        name: String,
        how: Reproduce,
    },
    /// A symlink whose target is gone: the repo was removed from the workspace.
    MirrorLinkDangling {
        name: String,
    },
    /// The `.envrc` that carries the workspace's environment, absent or no longer
    /// what zwt generates.
    SessionEnvrcStale,
    DirenvNotAllowed,
    /// Nothing marks the directory as a session, so nothing walking up finds it.
    MarkerMissing,
    /// git still records a worktree whose directory someone deleted.
    WorktreeRecordStale {
        repo: String,
        path: String,
    },
}

impl Drift {
    pub fn describe(&self) -> String {
        match self {
            Self::MirrorEntryMissing { name, .. } => format!("mirror is missing `{name}`"),
            Self::MirrorLinkDangling { name } => {
                format!("`{name}` links to something that no longer exists")
            }
            Self::SessionEnvrcStale => {
                ".envrc is not the one zwt generates for a session".into()
            }
            Self::DirenvNotAllowed => "direnv has not been allowed here".into(),
            Self::MarkerMissing => format!("{} is missing", session::MARKER),
            Self::WorktreeRecordStale { repo, path } => {
                format!("`{repo}` still records a worktree at {path}")
            }
        }
    }
}

/// A worktree git still records with nothing live behind it: the directory is
/// gone, or a mirror symlink now stands where it was.
///
/// Deleting a session with `rm -rf` leaves one of these per member. They are
/// invisible in every listing but keep any branch they hold claimed, so checking
/// it out anywhere else fails pointing at a path that is not a worktree.
#[derive(Debug, Clone)]
pub struct Orphan {
    pub repo: String,
    pub path: std::path::PathBuf,
    pub branch: Option<String>,
    /// Whether it sits under the sessions root, and is therefore ours to prune.
    pub ours: bool,
}

pub fn orphans(cfg: &Config) -> Result<Vec<Orphan>> {
    let mut found = Vec::new();
    for repo in workspace::repo_names(cfg)? {
        for wt in git::worktrees(&cfg.workspace.join(&repo))? {
            if git::is_live_worktree(&wt.path) {
                continue;
            }
            found.push(Orphan {
                repo: repo.clone(),
                ours: wt.path.starts_with(&cfg.default_root),
                branch: wt.branch,
                path: wt.path,
            });
        }
    }
    Ok(found)
}

pub fn prune_orphan(cfg: &Config, orphan: &Orphan) -> Result<()> {
    git::prune_record(&cfg.workspace.join(&orphan.repo), &orphan.path)
}

pub fn detect(cfg: &Config, session: &Session) -> Result<Vec<Drift>> {
    let mut drift = Vec::new();
    let members = session.members()?;
    let member_names: Vec<String> = members.iter().map(|m| m.repo.clone()).collect();

    for entry in workspace::entries(cfg)? {
        if member_names.contains(&entry.name) || entry.name == envrc::FILE {
            continue;
        }
        let path = session.path.join(&entry.name);
        if !util::exists(&path) {
            drift.push(Drift::MirrorEntryMissing {
                name: entry.name,
                how: entry.how,
            });
        }
    }

    // Dangling links are found by walking the session, not the workspace: the
    // repo they pointed at is not there to be listed any more.
    if let Ok(dir) = std::fs::read_dir(&session.path) {
        for entry in dir.flatten() {
            let path = entry.path();
            if util::is_symlink(&path) && !path.exists() {
                drift.push(Drift::MirrorLinkDangling {
                    name: entry.file_name().to_string_lossy().into_owned(),
                });
            }
        }
    }

    if !envrc::session_is_current(cfg, &session.path) {
        drift.push(Drift::SessionEnvrcStale);
    } else if !direnv_allowed(&session.path) {
        drift.push(Drift::DirenvNotAllowed);
    }

    if session::read_marker(&session.path).is_none() {
        drift.push(Drift::MarkerMissing);
    }


    for repo in workspace::repo_names(cfg)? {
        let repo_path = cfg.workspace.join(&repo);
        for wt in git::worktrees(&repo_path)? {
            if !wt.path.starts_with(&session.path) {
                continue;
            }
            if !git::is_live_worktree(&wt.path) {
                drift.push(Drift::WorktreeRecordStale {
                    repo: repo.clone(),
                    path: wt.path.display().to_string(),
                });
            }
        }
    }

    Ok(drift)
}

pub fn fix(cfg: &Config, session: &Session, item: &Drift) -> Result<()> {
    match item {
        Drift::MirrorEntryMissing { name, how } => {
            let src = cfg.workspace.join(name);
            let dst = session.path.join(name);
            match how {
                Reproduce::CopiedDotfile => {
                    std::fs::copy(&src, &dst)?;
                }
                Reproduce::Repo | Reproduce::Symlink => mirror::symlink(&src, &dst)?,
            }
        }
        // Unlinks only. Following the link here would delete the main checkout.
        Drift::MirrorLinkDangling { name } => {
            std::fs::remove_file(session.path.join(name))?;
        }
        Drift::SessionEnvrcStale => {
            envrc::write_session(cfg, &session.path)?;
            hydrate::allow_direnv(&session.path)?;
        }
        Drift::DirenvNotAllowed => {
            hydrate::allow_direnv(&session.path)?;
        }
        Drift::MarkerMissing => {
            session::write_marker(&session.path, &session.id, &cfg.workspace)?;
        }
        Drift::WorktreeRecordStale { repo, path } => {
            git::prune_record(&cfg.workspace.join(repo), std::path::Path::new(path))?;
            if session.repo_state(repo) == RepoState::Absent {
                mirror::relink_repo(cfg, &session.path, repo)?;
            }
        }
    }
    Ok(())
}

fn direnv_allowed(path: &std::path::Path) -> bool {
    if util::which("direnv").is_none() {
        return true;
    }
    let Ok(out) = capture("direnv", &["status", "--json"], Some(path)) else {
        return true;
    };
    if !out.ok() {
        return true;
    }
    let Ok(value) = serde_json::from_str::<serde_json::Value>(&out.stdout) else {
        return true;
    };
    match value["state"]["foundRC"].as_object() {
        // `allowed: 0` is direnv's way of saying yes.
        Some(rc) => rc.get("allowed").and_then(|a| a.as_i64()) == Some(0),
        None => true,
    }
}
