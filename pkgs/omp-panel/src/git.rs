//! The branch an omp works on, how far it is from its upstream, and whether it
//! has uncommitted changes.

use std::collections::HashMap;
use std::process::Command;
use std::time::{Duration, Instant};

use serde::Serialize;

use crate::state::Group;

#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
pub struct Git {
    /// None when detached.
    pub branch: Option<String>,
    pub ahead: u32,
    pub behind: u32,
    /// Tracked files only: listing untracked ones walks the whole worktree.
    pub dirty: bool,
}

fn parse(porcelain: &str) -> Git {
    let mut git = Git {
        branch: None,
        ahead: 0,
        behind: 0,
        dirty: false,
    };
    for line in porcelain.lines() {
        if let Some(head) = line.strip_prefix("# branch.head ") {
            git.branch = (head != "(detached)").then(|| head.to_owned());
        } else if let Some(ab) = line.strip_prefix("# branch.ab ") {
            let mut counts = ab.split(' ');
            let mut count = |sign: char| {
                counts
                    .next()
                    .and_then(|c| c.strip_prefix(sign))
                    .and_then(|c| c.parse().ok())
                    .unwrap_or(0)
            };
            git.ahead = count('+');
            git.behind = count('-');
        } else if !line.starts_with('#') && !line.is_empty() {
            git.dirty = true;
        }
    }
    git
}

pub fn status(cwd: &str) -> Option<Git> {
    let out = Command::new("git")
        .args([
            "-C",
            cwd,
            "status",
            "--porcelain=v2",
            "--branch",
            "--untracked-files=no",
        ])
        // The omp in that worktree may be running git itself: no index lock from here.
        .env("GIT_OPTIONAL_LOCKS", "0")
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| parse(&String::from_utf8_lossy(&out.stdout)))
}

/// Statuses by directory, each kept for `ttl` so a refresh every second does
/// not run git status that often in every worktree.
pub struct Cache {
    ttl: Duration,
    entries: HashMap<String, (Instant, Option<Git>)>,
}

impl Cache {
    pub fn new(ttl: Duration) -> Self {
        Self {
            ttl,
            entries: HashMap::new(),
        }
    }

    pub fn annotate(&mut self, groups: &mut [Group]) {
        let now = Instant::now();
        self.entries
            .retain(|_, (checked, _)| now.duration_since(*checked) < self.ttl);
        let mut missing: Vec<&str> = groups
            .iter()
            .flat_map(|g| &g.panes)
            .map(|row| row.cwd.as_str())
            .filter(|cwd| !self.entries.contains_key(*cwd))
            .collect();
        missing.sort_unstable();
        missing.dedup();
        std::thread::scope(|scope| {
            let handles: Vec<_> = missing
                .into_iter()
                .map(|cwd| (cwd, scope.spawn(move || status(cwd))))
                .collect();
            for (cwd, handle) in handles {
                let git = handle.join().ok().flatten();
                self.entries.insert(cwd.to_owned(), (now, git));
            }
        });
        for row in groups.iter_mut().flat_map(|g| g.panes.iter_mut()) {
            row.git = self.entries.get(&row.cwd).and_then(|(_, git)| git.clone());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_branch_distance_and_changes() {
        let git = parse(
            "# branch.oid abc\n# branch.head feat\n# branch.upstream origin/feat\n# branch.ab +2 -1\n\
             1 .M N... 100644 100644 100644 a b src/main.rs\n",
        );
        assert_eq!(
            git,
            Git {
                branch: Some("feat".into()),
                ahead: 2,
                behind: 1,
                dirty: true
            }
        );
        let detached = parse("# branch.oid abc\n# branch.head (detached)\n");
        assert_eq!(detached.branch, None);
        assert!(!detached.dirty, "no upstream, no changes");
    }
}
