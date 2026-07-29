use std::path::{Path, PathBuf};

use anyhow::Result;

use zwt_core::config::Config;
use zwt_core::hydrate;
use zwt_core::registry::Registry;
use zwt_core::{envrc, git, layout, mirror, session, util, workspace};

use crate::ui::{self, Choice};

pub struct Args {
    pub name: String,
    pub title: Option<String>,
    pub at: Option<PathBuf>,
    pub repos: Vec<String>,
    pub empty: bool,
}

pub fn run(cfg: &Config, args: Args) -> Result<()> {
    let id = slug(&args.name);
    let (mut reg, _) = Registry::open(cfg)?;
    anyhow::ensure!(
        reg.get(&id).is_none(),
        "session `{id}` already exists — `zwt {id}` prints its root"
    );

    let path = args.at.clone().unwrap_or_else(|| cfg.session_path(&id));
    anyhow::ensure!(!util::exists(&path), "{} already exists", path.display());

    let members = if args.empty {
        Vec::new()
    } else if args.repos.is_empty() {
        choose_members(&workspace::selectable(cfg)?)?
    } else {
        for repo in &args.repos {
            workspace::repo_path(cfg, repo)?;
        }
        args.repos.clone()
    };

    let scaffold = mirror::build(cfg, &path, &members)
        .and_then(|()| envrc::write_session(cfg, &path))
        .and_then(|()| session::write_marker(&path, &id, &cfg.workspace))
        .and_then(|()| layout::write(&path));
    if let Err(err) = scaffold {
        // Safe to wipe: only symlinks and copies exist at this point, and no
        // worktree yet, so nothing here is the only copy of anything.
        let _ = std::fs::remove_dir_all(&path);
        return Err(err);
    }

    // Registered before the worktrees are built: a session directory that no
    // command knows about is worse than one that is half populated.
    reg.insert(&id, &path, args.title.clone());
    reg.save()?;
    println!("{id} -> {}", path.display());

    if let Err(err) = hydrate::allow_direnv(&path) {
        eprintln!("zwt: could not allow direnv in the session root: {err:#}");
    }

    let mut failed = Vec::new();
    for repo in &members {
        if let Err(err) = check_out(cfg, &path, repo) {
            let _ = mirror::relink_repo(cfg, &path, repo);
            failed.push((repo.clone(), err));
        }
    }
    for (repo, err) in &failed {
        eprintln!("zwt: {repo}: {err:#}");
    }
    if !failed.is_empty() {
        eprintln!(
            "zwt: {} repo(s) left as symlinks; `zwt add <repo>` retries one",
            failed.len()
        );
    }
    Ok(())
}

/// Give a repo a detached worktree at its own main branch, plus the environment
/// `git worktree add` leaves behind.
pub fn check_out(cfg: &Config, session: &Path, repo: &str) -> Result<()> {
    let repo_path = workspace::repo_path(cfg, repo)?;
    let worktree = session.join(repo);
    let base = git::base_ref(&repo_path)?;

    println!("{repo}: detached at {base}");
    if let Some(warning) = git::add_worktree(&repo_path, &worktree, &base)? {
        eprintln!("zwt: {repo}: the checkout succeeded but a git hook failed:\n{warning}");
    }

    let report = hydrate::hydrate(&git::main_worktree(&repo_path)?, &worktree)?;
    for (path, err) in &report.failed {
        eprintln!("zwt: {repo}: could not copy {path}: {err}");
    }
    Ok(())
}

fn choose_members(selectable: &[String]) -> Result<Vec<String>> {
    anyhow::ensure!(
        !selectable.is_empty(),
        "no repos to choose from: none of the configured ones are cloned"
    );
    let choices: Vec<Choice> = selectable
        .iter()
        .map(|repo| Choice::new(repo.clone(), repo.clone()))
        .collect();
    ui::pick_many(&choices, "members>")
}

/// A session id that is safe as a directory name.
fn slug(name: &str) -> String {
    name.chars()
        .map(|c| match c {
            'a'..='z' | 'A'..='Z' | '0'..='9' | '-' | '_' | '.' => c,
            _ => '-',
        })
        .collect::<String>()
        .trim_matches('-')
        .to_lowercase()
}

#[cfg(test)]
mod tests {
    use super::slug;

    #[test]
    fn slugs_are_directory_safe() {
        assert_eq!(slug("spike-perf"), "spike-perf");
        assert_eq!(slug("COD-2931"), "cod-2931");
        assert_eq!(slug("guiom/dev sandbox"), "guiom-dev-sandbox");
    }
}
