use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use crate::registry::Registry;
use crate::{git, util};

/// What makes a session directory self-describing, so that an ancestor walk
/// answers "which session is this?" with no registry lookup and no environment.
pub const MARKER: &str = ".zwt/session.json";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Marker {
    pub id: String,
    /// The checkout this session mirrors.
    pub workspace: PathBuf,
}

pub fn write_marker(path: &Path, id: &str, workspace: &Path) -> Result<()> {
    let file = path.join(MARKER);
    let dir = file.parent().expect("marker path has a parent");
    std::fs::create_dir_all(dir).with_context(|| format!("failed to create {}", dir.display()))?;
    let marker = Marker {
        id: id.to_string(),
        workspace: workspace.to_path_buf(),
    };
    std::fs::write(
        &file,
        format!("{}\n", serde_json::to_string_pretty(&marker)?),
    )
    .with_context(|| format!("failed to write {}", file.display()))
}

pub fn read_marker(path: &Path) -> Option<Marker> {
    let raw = std::fs::read_to_string(path.join(MARKER)).ok()?;
    serde_json::from_str(&raw).ok()
}

/// The session root at or above `dir`, found by its marker.
pub fn root_from(dir: &Path) -> Option<PathBuf> {
    dir.ancestors()
        .find(|candidate| candidate.join(MARKER).is_file())
        .map(Path::to_path_buf)
}

#[derive(Debug, Clone)]
pub struct Member {
    pub repo: String,
    pub path: PathBuf,
    pub branch: Option<String>,
}

/// How a repo is currently reproduced in a session directory.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RepoState {
    /// A real worktree: the repo is a member of the session.
    Worktree,
    /// A symlink to the main checkout: present but not a member.
    Linked,
    /// Neither — the mirror predates this repo, or someone deleted it.
    Absent,
}

#[derive(Debug, Clone)]
pub struct Session {
    pub id: String,
    pub path: PathBuf,
    pub title: Option<String>,
}

impl Session {
    pub fn from_registry(reg: &Registry, id: &str) -> Result<Self> {
        let entry = reg
            .get(id)
            .with_context(|| format!("unknown session `{id}` (see `zwt ls`)"))?;
        Ok(Self {
            id: id.to_string(),
            path: entry.resolved_path(),
            title: entry.title.clone(),
        })
    }

    pub fn repo_state(&self, repo: &str) -> RepoState {
        let path = self.path.join(repo);
        if !util::exists(&path) {
            RepoState::Absent
        } else if util::is_symlink(&path) {
            RepoState::Linked
        } else if git::is_repo(&path) {
            RepoState::Worktree
        } else {
            RepoState::Absent
        }
    }

    /// Members read straight off the filesystem: a real (non-symlinked) repo
    /// directory inside the session is a worktree, and therefore a member.
    pub fn members(&self) -> Result<Vec<Member>> {
        let mut members = Vec::new();
        let dir = match std::fs::read_dir(&self.path) {
            Ok(dir) => dir,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(members),
            Err(e) => return Err(e).context(format!("failed to read {}", self.path.display())),
        };
        for entry in dir {
            let entry = entry?;
            let path = entry.path();
            if util::is_symlink(&path) || !path.is_dir() || !git::is_repo(&path) {
                continue;
            }
            let repo = entry.file_name().to_string_lossy().into_owned();
            members.push(Member {
                branch: git::current_branch(&path),
                repo,
                path,
            });
        }
        members.sort_by(|a, b| a.repo.cmp(&b.repo));
        Ok(members)
    }

    pub fn member_names(&self) -> Result<Vec<String>> {
        Ok(self.members()?.into_iter().map(|m| m.repo).collect())
    }
}

/// The session the caller is in: the marked root above the path they walked in
/// through, else whichever session directory contains the resolved cwd.
pub fn current(reg: &Registry) -> Result<Option<Session>> {
    if let Some(marker) = logical_cwd()
        .as_deref()
        .and_then(root_from)
        .and_then(|root| read_marker(&root))
    {
        if reg.get(&marker.id).is_some() {
            return Session::from_registry(reg, &marker.id).map(Some);
        }
    }
    let cwd = std::env::current_dir()?;
    Ok(from_path(reg, &cwd))
}

/// `$PWD` while it still describes the current directory: it keeps the path a
/// shell walked in through, which the resolved cwd has lost. The difference is a
/// session's symlinked repos, whose real path lies outside the session.
fn logical_cwd() -> Option<PathBuf> {
    let pwd = PathBuf::from(std::env::var_os("PWD")?);
    if !pwd.is_absolute() {
        return None;
    }
    let real = std::env::current_dir().ok()?;
    (pwd.canonicalize().ok()? == real).then_some(pwd)
}

pub fn from_path(reg: &Registry, path: &Path) -> Option<Session> {
    let (id, _) = reg.containing(path)?;
    Session::from_registry(reg, id).ok()
}
