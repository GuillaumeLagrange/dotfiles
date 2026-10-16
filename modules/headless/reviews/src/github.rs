//! The pull requests awaiting my review and those I reviewed lately, with the
//! rest of their GitHub stacks, from one GraphQL query through `gh`; their
//! authors' avatars and their descriptions' images. The list and the pictures
//! are cached on disk so the picker opens on the last answer while a fresh one
//! is fetched.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};

const QUERY: &str = r#"
fragment Fields on PullRequest {
  number title url body state isDraft updatedAt headRefName additions deletions changedFiles
  viewerLatestReview { state }
  repository { name nameWithOwner }
  author { login avatarUrl(size: 64) }
  commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
}
fragment Found on PullRequest {
  ...Fields
  stackEntry { position }
  stack { number size baseRefName entries(first: 50) { nodes { position pullRequest { ...Fields } } } }
}
query($q: String!) {
  search(query: $q, type: ISSUE, first: 100) { nodes { ...Found } }
}"#;

/// How far back the reviewed list goes, by last update.
pub const REVIEWED_DAYS: u64 = 14;

/// An avatar older than this is fetched again, after showing the cached one.
const AVATAR_TTL: Duration = Duration::from_secs(7 * 24 * 3600);
/// A list older than this is not shown while the fresh one loads: it only
/// bridges successive opens.
const SNAPSHOT_TTL: Duration = Duration::from_secs(5 * 60);
/// Images are fetched again after this, to keep the cache from growing.
const IMAGE_TTL: Duration = Duration::from_secs(30 * 24 * 3600);

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
    /// Found by its list's search; otherwise only listed as part of a stack.
    pub listed: bool,
    pub stack: Option<Stack>,
    pub additions: u64,
    pub deletions: u64,
    pub files: u64,
    /// The repo's name without its owner: the directory it is checked out in.
    pub repo: String,
    pub repo_full: String,
    pub author: String,
    pub avatar_url: Option<String>,
    /// My latest review's verdict, not the pull request's review decision.
    pub decision: Option<Decision>,
    pub checks: Option<Checks>,
}

/// The searches, each a tab of the picker. Two requests, not one query: the
/// reviewed search alone takes GitHub up to 9s of its 10.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Query {
    Requested,
    Reviewed,
}

impl Query {
    fn search(self) -> String {
        match self {
            Query::Requested => {
                "is:pr is:open archived:false review-requested:@me sort:updated-desc".to_owned()
            }
            Query::Reviewed => {
                let since = date(now().saturating_sub(REVIEWED_DAYS * 86400));
                format!("is:pr archived:false reviewed-by:@me -author:@me updated:>={since} sort:updated-desc")
            }
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Lists {
    /// Open, my review requested.
    pub requested: Vec<Pr>,
    /// Reviewed by me, updated within `REVIEWED_DAYS`, and not in `requested`.
    pub reviewed: Vec<Pr>,
}

impl Lists {
    pub fn get(&self, query: Query) -> &[Pr] {
        match query {
            Query::Requested => &self.requested,
            Query::Reviewed => &self.reviewed,
        }
    }

    /// Replace a list, keeping a pull request asked of me again out of the
    /// reviewed one.
    pub fn set(&mut self, query: Query, prs: Vec<Pr>) {
        match query {
            Query::Requested => self.requested = prs,
            Query::Reviewed => self.reviewed = prs,
        }
        let requested = &self.requested;
        self.reviewed
            .retain(|pr| !pr.listed || !requested.iter().any(|r| r.listed && r.url == pr.url));
    }
}

#[derive(Serialize, Deserialize)]
pub struct Snapshot {
    /// Seconds since the epoch.
    pub fetched_at: u64,
    pub lists: Lists,
}

#[derive(Deserialize)]
struct Response<T> {
    data: Option<T>,
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
    viewer_latest_review: Option<Review>,
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
struct Review {
    state: String,
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
    fn into_pr(self, listed: bool, stack: Option<Stack>) -> Pr {
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
        let decision = n.viewer_latest_review.and_then(|r| match r.state.as_str() {
            "APPROVED" => Some(Decision::Approved),
            "CHANGES_REQUESTED" => Some(Decision::ChangesRequested),
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
            listed,
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

/// `YYYY-MM-DD` of a time in seconds since the epoch, UTC.
fn date(secs: u64) -> String {
    // Civil from days, Howard Hinnant's algorithm.
    let z = (secs / 86400) as i64 + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}")
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
        let bytes = curl(url)?;
        write_atomic(&self.avatar_path(login), &bytes)?;
        Ok(bytes)
    }

    fn images_dir(&self) -> PathBuf {
        self.dir.join("images")
    }

    /// Keyed by the source in the markdown: signed URLs change on every fetch.
    fn image_path(&self, src: &str) -> PathBuf {
        // FNV-1a: stable across builds, unlike std's hasher.
        let hash = src.bytes().fold(0xcbf29ce484222325u64, |h, b| {
            (h ^ u64::from(b)).wrapping_mul(0x100000001b3)
        });
        self.images_dir().join(format!("{hash:016x}"))
    }

    pub fn image(&self, src: &str) -> Option<Vec<u8>> {
        std::fs::read(self.image_path(src)).ok()
    }

    pub fn store_image(&self, src: &str, bytes: &[u8]) -> Result<()> {
        write_atomic(&self.image_path(src), bytes)
    }

    pub fn prune_images(&self) {
        let Ok(entries) = std::fs::read_dir(self.images_dir()) else {
            return;
        };
        for entry in entries.flatten() {
            let old = entry
                .metadata()
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| t.elapsed().ok())
                .is_some_and(|age| age > IMAGE_TTL);
            if old {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
}

pub fn curl(url: &str) -> Result<Vec<u8>> {
    let out = Command::new("curl")
        .args([
            "--fail",
            "--silent",
            "--show-error",
            "--location",
            "--max-time",
            "20",
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
    Ok(out.stdout)
}

fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    let dir = path.parent().context("cache path has no parent")?;
    std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    let tmp = path.with_extension(format!("tmp{}", std::process::id()));
    std::fs::write(&tmp, bytes).with_context(|| format!("writing {}", tmp.display()))?;
    std::fs::rename(&tmp, path).with_context(|| format!("writing {}", path.display()))
}

fn graphql<T: for<'de> Deserialize<'de>>(query: &str, vars: &[(&str, String)]) -> Result<T> {
    let mut cmd = Command::new("gh");
    cmd.args(["api", "graphql", "-f"])
        .arg(format!("query={query}"));
    for (name, value) in vars {
        // -F types numbers; -f keeps strings strings.
        let flag = if value.bytes().all(|b| b.is_ascii_digit()) {
            "-F"
        } else {
            "-f"
        };
        cmd.arg(flag).arg(format!("{name}={value}"));
    }
    let out = cmd.stdin(Stdio::null()).output().context("running gh")?;
    if !out.status.success() {
        bail!(
            "gh api graphql: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    let response: Response<T> =
        serde_json::from_slice(&out.stdout).context("parsing gh's response")?;
    if let Some(err) = response.errors.first() {
        bail!("GitHub: {}", err.message);
    }
    response.data.context("GitHub answered without data")
}

/// A search's pull requests, then the rest of their stacks.
fn collect(nodes: Vec<Node>) -> Vec<Pr> {
    let mut prs: Vec<Pr> = Vec::new();
    let mut entries = Vec::new();
    for mut node in nodes {
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
    for (node, place) in entries {
        if !prs.iter().any(|pr| pr.url == node.url) {
            prs.push(node.into_pr(false, Some(place)));
        }
    }
    prs
}

pub fn fetch(query: Query) -> Result<Vec<Pr>> {
    let data: Data = graphql(QUERY, &[("q", query.search())])?;
    Ok(collect(data.search.nodes))
}

/// Uploads to GitHub (`github.com/user-attachments/...`, `*user-images.githubusercontent.com`)
/// only load in a logged-in browser.
pub fn needs_signing(src: &str) -> bool {
    src.starts_with("https://github.com/user-attachments/")
        || src
            .strip_prefix("https://")
            .and_then(|s| s.split('/').next())
            .is_some_and(|host| host.ends_with("user-images.githubusercontent.com"))
}

/// The UUID naming an upload, kept by its signed URL.
pub fn asset_id(src: &str) -> Option<&str> {
    let is_uuid = |s: &str| {
        s.len() == 36
            && s.char_indices().all(|(i, c)| {
                if matches!(i, 8 | 13 | 18 | 23) {
                    c == '-'
                } else {
                    c.is_ascii_hexdigit()
                }
            })
    };
    let path = src.split(['?', '#']).next()?;
    (0..path.len().saturating_sub(35))
        .filter(|&i| path.is_char_boundary(i) && path.is_char_boundary(i + 36))
        .map(|i| &path[i..i + 36])
        .find(|s| is_uuid(s))
}

/// Image sources of a pull request's rendered description, where GitHub signs
/// its uploads' URLs for a few minutes.
pub fn signed_images(repo_full: &str, number: u64) -> Result<Vec<String>> {
    #[derive(Deserialize)]
    struct Data {
        repository: Repo,
    }
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Repo {
        pull_request: Body,
    }
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Body {
        #[serde(rename = "bodyHTML")]
        body_html: String,
    }
    let (owner, name) = repo_full.split_once('/').context("repo without owner")?;
    let data: Data = graphql(
        "query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { bodyHTML } } }",
        &[
            ("owner", owner.to_owned()),
            ("name", name.to_owned()),
            ("number", number.to_string()),
        ],
    )?;
    let html = data.repository.pull_request.body_html;
    Ok(html
        .split("<img")
        .skip(1)
        .filter_map(|tag| {
            let start = tag.find("src=\"")? + 5;
            let len = tag[start..].find('"')?;
            Some(tag[start..start + len].replace("&amp;", "&"))
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::{asset_id, date, needs_signing, parse_timestamp};

    #[test]
    fn timestamps() {
        assert_eq!(parse_timestamp("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_timestamp("2000-03-01T00:00:00Z"), Some(951868800));
        assert_eq!(parse_timestamp("2026-10-06T10:27:58Z"), Some(1791282478));
        assert_eq!(parse_timestamp("2026-10-06T10:27:58+02:00"), None);
    }

    #[test]
    fn dates_round_trip() {
        for s in ["1970-01-01", "2000-02-29", "2026-10-12", "2100-03-01"] {
            let secs = parse_timestamp(&format!("{s}T12:00:00Z")).unwrap();
            assert_eq!(date(secs), s);
        }
    }

    #[test]
    fn uploads_are_matched_to_their_signed_urls() {
        let src = "https://github.com/user-attachments/assets/359d9038-6af2-4f9a-8898-6562902df498";
        let signed = "https://private-user-images.githubusercontent.com/1/665619030-359d9038-6af2-4f9a-8898-6562902df498.png?jwt=x";
        assert!(needs_signing(src) && needs_signing(signed));
        assert!(!needs_signing("https://img.shields.io/badge/x"));
        assert_eq!(asset_id(src), asset_id(signed));
        assert!(asset_id(src).is_some());
    }
}
