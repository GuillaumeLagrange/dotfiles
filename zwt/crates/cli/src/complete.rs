//! Candidate lists for shell completion.
//!
//! Computed by running zwt, so `zwt rm <TAB>` offers the sessions that exist now
//! rather than whatever existed when the completion script was generated.
//! Everything here fails to an empty list: a broken completion must never be
//! noisier than no completion.

use clap_complete::CompletionCandidate;

use zwt_core::config::Config;
use zwt_core::registry::Registry;
use zwt_core::session::{self, RepoState, Session};
use zwt_core::workspace;

pub fn sessions() -> Vec<CompletionCandidate> {
    let Ok(cfg) = Config::load() else {
        return Vec::new();
    };
    let Ok(reg) = Registry::open_raw(&cfg) else {
        return Vec::new();
    };
    reg.sessions
        .iter()
        .map(|(id, entry)| {
            let members = Session::from_registry(&reg, id)
                .and_then(|s| s.member_names())
                .unwrap_or_default();
            CompletionCandidate::new(id).help(Some(describe(entry.title.as_deref(), &members)))
        })
        .collect()
}

/// Repos that could join the current session: the selectable ones that are not
/// already worktrees.
pub fn addable_repos() -> Vec<CompletionCandidate> {
    repos_where(|state| state != RepoState::Worktree)
}

/// Repos that could be handed back to the main checkout.
pub fn member_repos() -> Vec<CompletionCandidate> {
    repos_where(|state| state == RepoState::Worktree)
}

fn repos_where(keep: fn(RepoState) -> bool) -> Vec<CompletionCandidate> {
    let Ok(cfg) = Config::load() else {
        return Vec::new();
    };
    let Ok(reg) = Registry::open_raw(&cfg) else {
        return Vec::new();
    };
    let Ok(names) = workspace::selectable(&cfg) else {
        return Vec::new();
    };
    // Outside a session there is nothing to compare against, so offer every repo
    // and let the command explain itself.
    let Ok(Some(current)) = session::current(&reg) else {
        return names.into_iter().map(CompletionCandidate::new).collect();
    };
    names
        .into_iter()
        .filter(|repo| keep(current.repo_state(repo)))
        .map(|repo| {
            let branch = current
                .members()
                .unwrap_or_default()
                .into_iter()
                .find(|m| m.repo == repo)
                .and_then(|m| m.branch);
            let candidate = CompletionCandidate::new(&repo);
            match branch {
                Some(branch) => candidate.help(Some(branch.into())),
                None => candidate,
            }
        })
        .collect()
}

fn describe(title: Option<&str>, members: &[String]) -> clap::builder::StyledStr {
    match (title, members.is_empty()) {
        (Some(title), true) => title.to_string(),
        (Some(title), false) => format!("{title} [{}]", members.join(" ")),
        (None, true) => "no members".to_string(),
        (None, false) => members.join(" "),
    }
    .into()
}
