//! The pull requests awaiting my review, with the rest of their GitHub stacks,
//! from one GraphQL search through `gh`, and their authors' avatars, both
//! cached on disk so the picker opens on the last answer while a fresh one is
//! fetched.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};

const QUERY: &str = r#"
fragment Fields on PullRequest {
  number title url body state isDraft updatedAt headRefName additions deletions changedFiles reviewDecision
  repository { name nameWithOwner }
  author { login avatarUrl(size: 64) }
  commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
}
query {
  search(query: "is:pr is:open archived:false review-requested:@me sort:updated-desc", type: ISSUE, first: 100) {
    nodes {
      ... on PullRequest {
        ...Fields
        stackEntry { position }
        stack { number size baseRefName entries(first: 50) { nodes { position pullRequest { ...Fields } } } }
      }
    }
  }
}"#;

/// An avatar older than this is fetched again, after showing the cached one.
const AVATAR_TTL: Duration = Duration::from_secs(7 * 24 * 3600);
/// A list older than this is not shown while the fresh one loads: it only
/// bridges successive opens.
const SNAPSHOT_TTL: Duration = Duration::from_secs(5 * 60);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Checks {
    Pending,
    Success,
    Failure,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Decision {
    Approved,
    ChangesRequested,
    ReviewRequired,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum State {
    Open,
    Merged,
    Closed,
}

/// A pull request's place in a GitHub stack.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Stack {
    /// Unique within the repository.
    pub number: u64,
    pub size: u64,
    /// The branch the whole stack targets.
    pub base: String,
    /// 1 is closest to `base`.
    pub position: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Pr {
    pub number: u64,
    pub title: String,
    pub url: String,
    pub body: String,
    pub state: State,
    pub draft: bool,
    /// Seconds since the epoch.
    pub updated_at: u64,
    pub branch: String,
    /// Asked of me; otherwise only listed as part of a stack.
    pub requested: bool,
    pub stack: Option<Stack>,
    pub additions: u64,
    pub deletions: u64,
    pub files: u64,
    /// The repo's name without its owner: the directory it is checked out in.
    pub repo: String,
    pub repo_full: String,
    pub author: String,
    pub avatar_url: Option<String>,
    pub decision: Option<Decision>,
    pub checks: Option<Checks>,
}

#[derive(Serialize, Deserialize)]
pub struct Snapshot {
    /// Seconds since the epoch.
    pub fetched_at: u64,
    pub prs: Vec<Pr>,
}

#[derive(Deserialize)]
struct Response {
    data: Option<Data>,
    #[serde(default)]
    errors: Vec<GqlError>,
}

#[derive(Deserialize)]
struct GqlError {
    message: String,
}

#[derive(Deserialize)]
struct Data {
    search: Search,
}

#[derive(Deserialize)]
struct Search {
    nodes: Vec<Node>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Node {
    number: u64,
    title: String,
    url: String,
    body: String,
    state: String,
    is_draft: bool,
    updated_at: String,
    head_ref_name: String,
    additions: u64,
    deletions: u64,
    changed_files: u64,
    review_decision: Option<String>,
    repository: Repository,
    /// Null for a deleted account.
    author: Option<Author>,
    commits: Commits,
    /// Only asked for the search results, not for their stacks' entries.
    #[serde(default)]
    stack_entry: Option<StackEntry>,
    #[serde(default)]
    stack: Option<StackNode>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Repository {
    name: String,
    name_with_owner: String,
}

#[derive(Deserialize)]
struct StackEntry {
    position: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StackNode {
    number: u64,
    size: u64,
    base_ref_name: String,
    entries: Entries,
}

#[derive(Deserialize)]
struct Entries {
    nodes: Vec<Entry>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Entry {
    position: u64,
    /// Null when not visible to me.
    pull_request: Option<Node>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Author {
    login: String,
    avatar_url: String,
}

#[derive(Deserialize)]
struct Commits {
    nodes: Vec<CommitNode>,
}

#[derive(Deserialize)]
struct CommitNode {
    commit: Commit,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Commit {
    status_check_rollup: Option<Rollup>,
}

#[derive(Deserialize)]
struct Rollup {
    state: String,
}

impl StackNode {
    fn at(&self, position: u64) -> Stack {
        Stack {
            number: self.number,
            size: self.size,
            base: self.base_ref_name.clone(),
            position,
        }
    }
}

impl Node {
    fn into_pr(self, requested: bool, stack: Option<Stack>) -> Pr {
        let n = self;
        let checks = n
            .commits
            .nodes
            .last()
            .and_then(|c| c.commit.status_check_rollup.as_ref())
            .map(|r| match r.state.as_str() {
                "SUCCESS" => Checks::Success,
                "FAILURE" | "ERROR" => Checks::Failure,
                _ => Checks::Pending,
            });
        let decision = n.review_decision.as_deref().and_then(|d| match d {
            "APPROVED" => Some(Decision::Approved),
            "CHANGES_REQUESTED" => Some(Decision::ChangesRequested),
            "REVIEW_REQUIRED" => Some(Decision::ReviewRequired),
            _ => None,
        });
        let (author, avatar_url) = match n.author {
            Some(a) => (a.login, Some(a.avatar_url)),
            None => ("ghost".to_owned(), None),
        };
        Pr {
            number: n.number,
            title: n.title,
            url: n.url,
            body: n.body,
            draft: n.is_draft,
            state: match n.state.as_str() {
                "MERGED" => State::Merged,
                "CLOSED" => State::Closed,
                _ => State::Open,
            },
            updated_at: parse_timestamp(&n.updated_at).unwrap_or(0),
            branch: n.head_ref_name,
            requested,
            stack,
            additions: n.additions,
            deletions: n.deletions,
            files: n.changed_files,
            repo: n.repository.name,
            repo_full: n.repository.name_with_owner,
            author,
            avatar_url,
            decision,
            checks,
        }
    }
}

pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Seconds since the epoch of a UTC `YYYY-MM-DDTHH:MM:SSZ`, GitHub's only form.
fn parse_timestamp(s: &str) -> Option<u64> {
    let num = |range: std::ops::Range<usize>| s.get(range)?.parse::<i64>().ok();
    if s.len() != 20 || !s.ends_with('Z') {
        return None;
    }
    let (y, m, d) = (num(0..4)?, num(5..7)?, num(8..10)?);
    let (hh, mm, ss) = (num(11..13)?, num(14..16)?, num(17..19)?);
    // Days from civil, Howard Hinnant's algorithm.
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    u64::try_from(days * 86400 + hh * 3600 + mm * 60 + ss).ok()
}

pub struct Cache {
    dir: PathBuf,
}

impl Cache {
    pub fn from_env() -> Self {
        let base = std::env::var_os("XDG_CACHE_HOME")
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".cache")
            });
        Cache {
            dir: base.join("reviews"),
        }
    }

    fn snapshot_path(&self) -> PathBuf {
        self.dir.join("prs.json")
    }

    /// The cached list, unless it is too old to show.
    pub fn load(&self) -> Option<Snapshot> {
        let bytes = std::fs::read(self.snapshot_path()).ok()?;
        let snapshot: Snapshot = serde_json::from_slice(&bytes).ok()?;
        (now().saturating_sub(snapshot.fetched_at) < SNAPSHOT_TTL.as_secs()).then_some(snapshot)
    }

    pub fn store(&self, snapshot: &Snapshot) -> Result<()> {
        write_atomic(&self.snapshot_path(), &serde_json::to_vec(snapshot)?)
    }

    fn avatar_path(&self, login: &str) -> PathBuf {
        self.dir.join("avatars").join(login)
    }

    /// The cached avatar, and whether it is due for a fetch.
    pub fn avatar(&self, login: &str) -> (Option<Vec<u8>>, bool) {
        let path = self.avatar_path(login);
        let stale = std::fs::metadata(&path)
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.elapsed().ok())
            .is_none_or(|age| age > AVATAR_TTL);
        (std::fs::read(&path).ok(), stale)
    }

    pub fn fetch_avatar(&self, login: &str, url: &str) -> Result<Vec<u8>> {
        let out = Command::new("curl")
            .args([
                "--fail",
                "--silent",
                "--show-error",
                "--location",
                "--max-time",
                "10",
                url,
            ])
            .stdin(Stdio::null())
            .output()
            .context("running curl")?;
        if !out.status.success() {
            bail!(
                "curl {url}: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            );
        }
        write_atomic(&self.avatar_path(login), &out.stdout)?;
        Ok(out.stdout)
    }
}

fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    let dir = path.parent().context("cache path has no parent")?;
    std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    let tmp = path.with_extension(format!("tmp{}", std::process::id()));
    std::fs::write(&tmp, bytes).with_context(|| format!("writing {}", tmp.display()))?;
    std::fs::rename(&tmp, path).with_context(|| format!("writing {}", path.display()))
}

pub fn fetch() -> Result<Vec<Pr>> {
    let out = Command::new("gh")
        .args(["api", "graphql", "-f"])
        .arg(format!("query={QUERY}"))
        .stdin(Stdio::null())
        .output()
        .context("running gh")?;
    if !out.status.success() {
        bail!(
            "gh api graphql: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    let response: Response =
        serde_json::from_slice(&out.stdout).context("parsing gh's response")?;
    if let Some(err) = response.errors.first() {
        bail!("GitHub: {}", err.message);
    }
    let data = response.data.context("GitHub answered without data")?;
    let mut prs: Vec<Pr> = Vec::new();
    let mut entries = Vec::new();
    for mut node in data.search.nodes {
        let stack = node.stack.take();
        let position = node.stack_entry.take().map(|e| e.position);
        let place = stack.as_ref().zip(position).map(|(s, p)| s.at(p));
        prs.push(node.into_pr(true, place));
        if let Some(mut stack) = stack {
            for entry in std::mem::take(&mut stack.entries.nodes) {
                if let Some(pr) = entry.pull_request {
                    entries.push((pr, stack.at(entry.position)));
                }
            }
        }
    }
    // The rest of each stack, after every requested one is in.
    for (node, place) in entries {
        if !prs.iter().any(|pr| pr.url == node.url) {
            prs.push(node.into_pr(false, Some(place)));
        }
    }
    Ok(prs)
}

#[cfg(test)]
mod tests {
    use super::parse_timestamp;

    #[test]
    fn timestamps() {
        assert_eq!(parse_timestamp("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_timestamp("2000-03-01T00:00:00Z"), Some(951868800));
        assert_eq!(parse_timestamp("2026-10-06T10:27:58Z"), Some(1791282478));
        assert_eq!(parse_timestamp("2026-10-06T10:27:58+02:00"), None);
    }
}
