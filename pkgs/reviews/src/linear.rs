//! The Linear issues a pull request is linked to, as Linear's GitHub
//! integration records them: an attachment holding the PR's URL, so the link
//! holds whatever the branch is named. One request through the `linear` CLI
//! (schpet/linear-cli, its login) for a whole list.

use std::collections::HashMap;
use std::process::{Command, Stdio};

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::github::Pr;

/// URLs per request; Linear answers 66 in one under a second.
const CHUNK: usize = 100;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Issue {
    /// `COD-123`.
    pub identifier: String,
    pub title: String,
    pub url: String,
    /// The workflow state's name, `In Review`.
    pub state: String,
    /// Its category: `triage`, `backlog`, `unstarted`, `started`, `completed`
    /// or `canceled`.
    pub kind: String,
}

#[derive(Deserialize)]
struct Response {
    data: Option<HashMap<String, Attachments>>,
    #[serde(default)]
    errors: Vec<GqlError>,
}

#[derive(Deserialize)]
struct GqlError {
    message: String,
}

#[derive(Deserialize)]
struct Attachments {
    nodes: Vec<Attachment>,
}

#[derive(Deserialize)]
struct Attachment {
    issue: Option<IssueNode>,
}

#[derive(Deserialize)]
struct IssueNode {
    identifier: String,
    title: String,
    url: String,
    state: StateNode,
}

#[derive(Deserialize)]
struct StateNode {
    name: String,
    #[serde(rename = "type")]
    kind: String,
}

/// One `attachmentsForURL` per URL, aliased `p<i>`.
fn query(count: usize) -> String {
    let params: Vec<String> = (0..count).map(|i| format!("$u{i}:String!")).collect();
    let fields: String = (0..count)
        .map(|i| {
            format!(
                " p{i}:attachmentsForURL(url:$u{i},first:10){{nodes{{issue{{identifier title url state{{name type}}}}}}}}"
            )
        })
        .collect();
    format!("query({}){{{fields}}}", params.join(","))
}

/// The issues of each URL, in the order Linear lists them, each once.
fn fetch(urls: &[&str]) -> Result<Vec<Vec<Issue>>> {
    let vars: Map<String, Value> = urls
        .iter()
        .enumerate()
        .map(|(i, url)| (format!("u{i}"), Value::from(*url)))
        .collect();
    let out = Command::new("linear")
        .args(["api", "--no-input", &query(urls.len()), "--variables-json"])
        .arg(Value::Object(vars).to_string())
        .stdin(Stdio::null())
        .output()
        .context("running linear")?;
    let response: Response = serde_json::from_slice(&out.stdout).with_context(|| {
        format!(
            "linear api: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )
    })?;
    if let Some(err) = response.errors.first() {
        bail!("Linear: {}", err.message);
    }
    let mut data = response.data.context("Linear answered without data")?;
    Ok((0..urls.len())
        .map(|i| {
            let mut issues: Vec<Issue> = Vec::new();
            let nodes = data
                .remove(&format!("p{i}"))
                .map_or(Vec::new(), |a| a.nodes);
            for issue in nodes.into_iter().filter_map(|a| a.issue) {
                if !issues.iter().any(|i| i.identifier == issue.identifier) {
                    issues.push(Issue {
                        identifier: issue.identifier,
                        title: issue.title,
                        url: issue.url,
                        state: issue.state.name,
                        kind: issue.state.kind,
                    });
                }
            }
            issues
        })
        .collect())
}

/// Fill each pull request's `linear`.
pub fn attach(prs: &mut [Pr]) -> Result<()> {
    let mut urls: Vec<&str> = prs.iter().map(|pr| pr.url.as_str()).collect();
    urls.sort_unstable();
    urls.dedup();
    let mut found: HashMap<String, Vec<Issue>> = HashMap::new();
    for chunk in urls.chunks(CHUNK) {
        for (url, issues) in chunk.iter().zip(fetch(chunk)?) {
            found.insert((*url).to_owned(), issues);
        }
    }
    for pr in prs {
        pr.linear = found.get(&pr.url).cloned().unwrap_or_default();
    }
    Ok(())
}
