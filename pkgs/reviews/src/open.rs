//! Opens a PR in zellij: one to review in a tab `<repo>#<number>` of the
//! `reviews` wt session, one of mine on its repo's tab of the wt session holding
//! its branch, else of the main checkout's session.

use std::io::IsTerminal;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use wt_core::zellij;

pub enum Pick {
    Review { url: String },
    Mine { url: String, branch: String },
}

const PANE_VARS: [&str; 3] = ["ZELLIJ", "ZELLIJ_SESSION_NAME", "ZELLIJ_PANE_ID"];

/// Run from the bar, there is no terminal to print a failure in: it becomes a
/// notification. Returns only on failure, as an exit status.
pub fn run(pick: Pick) -> i32 {
    let Err(err) = open(pick);
    if std::io::stderr().is_terminal() {
        eprintln!("review: {err:#}");
    } else {
        notify(&["review failed", &format!("{err:#}")]);
    }
    1
}

fn notify(args: &[&str]) {
    let _ = Command::new("notify-send")
        .args(["-a", "review"])
        .args(args)
        .stdin(Stdio::null())
        .status();
}

/// https://github.com/<owner>/<repo>/pull/<number>
fn repo_of(url: &str) -> Result<&str> {
    url.strip_prefix("https://github.com/")
        .and_then(|rest| rest.split('/').nth(1))
        .filter(|repo| !repo.is_empty())
        .ok_or_else(|| anyhow!("not a GitHub PR URL: {url}"))
}

/// A command's trimmed stdout, its stderr in the error when it fails.
fn output(cmd: &mut Command) -> Result<String> {
    let out = cmd
        .stdin(Stdio::null())
        .output()
        .with_context(|| format!("failed to run {cmd:?}"))?;
    if !out.status.success() {
        bail!(
            "{cmd:?} failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_owned())
}

fn wt(args: &[&str]) -> Result<String> {
    output(Command::new("wt").args(args))
}

fn git_ok(dir: &Path, args: &[&str]) -> bool {
    Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// Uncommitted work: a submodule merely at another commit than recorded is not,
/// since `git submodule update` after the checkout puts it back; edits inside one are.
fn dirty(dir: &Path) -> bool {
    !git_ok(dir, &["diff", "--quiet", "--ignore-submodules=all"])
        || !git_ok(dir, &["diff", "--cached", "--quiet"])
        || !git_ok(
            dir,
            &[
                "submodule",
                "--quiet",
                "foreach",
                "--recursive",
                "git diff --quiet && git diff --cached --quiet",
            ],
        )
}

/// Checks the branch out in the main checkout, before its tab opens so its shell
/// starts on it. Uncommitted changes leave it alone: the tab still opens, to deal
/// with them.
fn check_out(dir: &Path, repo: &str, url: &str, branch: &str) -> Result<()> {
    let current = output(
        Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(["branch", "--show-current"]),
    )?;
    if current == branch {
        return Ok(());
    }
    let body = format!("{branch} is not checked out in {}", dir.display());
    if dirty(dir) {
        notify(&[
            "-u",
            "critical",
            &format!("{repo}: uncommitted changes"),
            &body,
        ]);
        return Ok(());
    }
    let checked_out = output(
        Command::new("gh")
            .args(["pr", "checkout", url])
            .current_dir(dir),
    )
    .and_then(|_| {
        output(
            Command::new("git")
                .args(["submodule", "--quiet", "update", "--init", "--recursive"])
                .current_dir(dir),
        )
    });
    if let Err(err) = checked_out {
        eprintln!("review: {err:#}");
        notify(&["-u", "critical", &format!("{repo}: checkout failed"), &body]);
    }
    Ok(())
}

/// The checkout runs in an interactive zsh so direnv loads the repo on cd, and the
/// pane falls back to a shell once nvim exits or a step fails. Diffy opens in a tab
/// of its own: the startup tab, an empty [No Name], is closed behind it.
const CHECKOUT: &str = r#"cd -- "$1" && git fetch --all && gh pr checkout --force "$2" && nvim -c "Diffy branch" -c "1tabclose"; exec zsh -i"#;

struct Target {
    session: String,
    root: PathBuf,
    repo: String,
    url: String,
    /// A wt session whose members' tabs `wt tabs` lays out.
    members: bool,
    kind: Kind,
}

enum Kind {
    Review { tab: String },
    Mine { dir: PathBuf },
}

fn target(pick: Pick) -> Result<Target> {
    match pick {
        Pick::Mine { url, branch } => {
            let repo = repo_of(&url)?.to_owned();
            let listed: Vec<serde_json::Value> =
                serde_json::from_str(&wt(&["ls", "--json"])?).context("parsing `wt ls --json`")?;
            let holding = listed.iter().find_map(|s| {
                s["members"]
                    .as_array()?
                    .iter()
                    .any(|m| m["repo"] == repo.as_str() && m["branch"] == branch.as_str())
                    .then(|| s["id"].as_str())?
            });
            let (session, root, members) = match holding {
                Some(id) => (id.to_owned(), wt(&["path", "--exact", id])?, true),
                None => (wt(&["main"])?, wt(&["main", "--path"])?, false),
            };
            let root = PathBuf::from(root);
            let dir = root.join(&repo);
            if !dir.is_dir() {
                bail!("no checkout of {repo} in {}", root.display());
            }
            if !members {
                check_out(&dir, &repo, &url, &branch)?;
            }
            Ok(Target {
                session,
                root,
                repo,
                url,
                members,
                kind: Kind::Mine { dir },
            })
        }
        Pick::Review { url } => {
            let repo = repo_of(&url)?.to_owned();
            let session = "reviews".to_owned();
            let root = PathBuf::from(
                wt(&["path", "--exact", &session])
                    .map_err(|_| anyhow!("no wt session {session}, create it with wt new"))?,
            );
            // A mirror symlink, or a repo the mirror lacks (cloned after the session
            // was made), becomes a worktree; wt refuses a name the workspace has no
            // repo for.
            let path = root.join(&repo);
            if path.is_symlink() || !path.exists() {
                output(Command::new("wt").args(["add", &repo]).current_dir(&root))?;
            }
            let number = url.rsplit('/').next().unwrap_or_default();
            Ok(Target {
                session,
                root,
                kind: Kind::Review {
                    tab: format!("{repo}#{number}"),
                },
                repo,
                url,
                members: false,
            })
        }
    }
}

/// A tab takes its size from a client: with none attached its layout fails. A
/// temporary client sizes it, and the size stays until a real client shows the tab.
struct TemporaryClient(Option<Child>);

impl TemporaryClient {
    /// Started again whenever it has exited: zellij lists a fresh server before it
    /// takes clients, and a first client can drop out. However long it takes, for
    /// as long as the session is up.
    fn ensure(&mut self, session: &str) -> Result<()> {
        loop {
            let running = self
                .0
                .as_mut()
                .is_some_and(|c| matches!(c.try_wait(), Ok(None)));
            if !running {
                if !zellij::is_live(session)? {
                    bail!("zellij session {session} went away");
                }
                self.0 = Some(
                    Command::new("script")
                        .args([
                            "-q",
                            "-c",
                            &format!(
                                "stty rows 50 cols 160; exec zellij attach {}",
                                wt_core::util::shell_quote(session)
                            ),
                            "/dev/null",
                        ])
                        .env("TERM", "xterm-256color")
                        .stdin(Stdio::null())
                        .stdout(Stdio::null())
                        .stderr(Stdio::null())
                        .spawn()
                        .context("failed to run script")?,
                );
            }
            if zellij::has_client(session).unwrap_or(false) {
                return Ok(());
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    }
}

impl Drop for TemporaryClient {
    fn drop(&mut self) {
        if let Some(mut child) = self.0.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

/// The first shell pane, as (pane, tab), once the session has one.
fn shell_pane(session: &str, tab: Option<u32>) -> Result<(u32, u32)> {
    loop {
        if let Some(pane) = zellij::panes(session)?
            .into_iter()
            .find(|p| !p.is_plugin && tab.is_none_or(|t| p.tab_id == t))
        {
            return Ok((pane.id, pane.tab_id));
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn open(pick: Pick) -> Result<std::convert::Infallible> {
    let t = target(pick)?;
    let session = t.session.as_str();

    // Outside a pane: zellij refuses to start a session from inside one, and
    // actions then target the session rather than the pane's.
    let pane_env: Option<Vec<(&str, String)>> = std::env::var_os("ZELLIJ").map(|_| {
        PANE_VARS
            .iter()
            .map(|v| (*v, std::env::var(v).unwrap_or_default()))
            .collect()
    });
    for var in PANE_VARS {
        std::env::remove_var(var);
    }

    let mut client = TemporaryClient(None);
    let mut created = false;
    let mut startup = None;
    if !zellij::has_client(session).unwrap_or(false) {
        created = !zellij::exists(session)?;
        // The server is started on its own first, as wt does: forked by the
        // temporary client, it could die with that client. Panes inherit the
        // server's TERM, unset when run from the bar.
        if !zellij::is_live(session)? {
            std::env::set_var("TERM", "xterm-256color");
            zellij::start_detached(session, &t.root)?;
        }
        client.ensure(session)?;
        // Kept from here: zellij can answer a later query with nothing.
        startup = Some(shell_pane(session, None)?);
        // The members' tabs, as attaching with wt lays them out. The client can
        // still drop out between being listed and wt asking for it.
        if t.members {
            let mut tries = 0;
            loop {
                client.ensure(session)?;
                tries += 1;
                match wt(&["tabs", session]) {
                    Ok(_) => break,
                    Err(err) if tries == 5 => return Err(err),
                    Err(_) => {}
                }
            }
        }
        client.ensure(session)?;
    }

    match &t.kind {
        Kind::Review { tab } => open_review_tab(&t, tab, startup.filter(|_| created))?,
        Kind::Mine { dir } => {
            // wt tabs already replaced a wt session's startup tab with the members'.
            let lone = startup
                .filter(|_| created && !t.members)
                .map(|(_, tab)| tab);
            open_repo_tab(&t, dir, lone)?
        }
    }
    drop(client);

    if let Some(vars) = pane_env {
        for (var, value) in vars {
            std::env::set_var(var, value);
        }
        zellij::switch_to(session)?;
        std::process::exit(0);
    }
    // A window already showing the session is focused rather than attached to a
    // second time, and run without a terminal, the session opens in a window of its own.
    let err = Command::new("zellij-attach")
        .args(["--focus", session])
        .exec();
    Err(err).context("failed to run zellij-attach")
}

fn open_review_tab(t: &Target, tab: &str, startup: Option<(u32, u32)>) -> Result<()> {
    let session = t.session.as_str();
    let root = t.root.to_string_lossy();
    let cmd = [
        "--cwd", &root, "--", "zsh", "-i", "-c", CHECKOUT, "zsh", &t.repo, &t.url,
    ];
    if let Some((pane, tab_id)) = startup {
        // A fresh session's lone shell tab becomes the PR's.
        zellij::rename_tab(session, tab_id, tab)?;
        let pane = format!("terminal_{pane}");
        let mut action = vec![
            "new-pane",
            "--in-place",
            "--close-replaced-pane",
            "--pane-id",
            &pane,
            "--name",
            tab,
        ];
        action.extend(cmd);
        zellij::act(session, &action, "open the PR in")?;
        return Ok(());
    }
    let tabs = zellij::tabs(session)?;
    if let Some(existing) = tabs.iter().find(|x| x.name == tab) {
        return zellij::go_to_tab(session, existing.tab_id);
    }
    // Another PR of the repo shares its worktree: its tab is closed once the new
    // one exists, so the session never runs out of tabs, which would end it.
    let prefix = format!("{}#", t.repo);
    let stale: Vec<u32> = tabs
        .iter()
        .filter(|x| x.name.starts_with(&prefix))
        .map(|x| x.tab_id)
        .collect();
    let id = zellij::new_tab_with(session, tab, &cmd)?;
    // Named after the tab, the pane titles the window "reviews | <tab>", as the
    // other panes do.
    let (pane, _) = shell_pane(session, Some(id))?;
    zellij::rename_pane(session, pane, tab)?;
    for id in stale {
        zellij::close_tab(session, id)?;
    }
    Ok(())
}

/// The tab of a repo, by the last word of its name as wt matches it, or a review
/// tab of the repo (<repo>#<number>) in the reviews session.
fn open_repo_tab(t: &Target, dir: &Path, lone: Option<u32>) -> Result<()> {
    let session = t.session.as_str();
    let prefix = format!("{}#", t.repo);
    let found = zellij::tabs(session).ok().and_then(|tabs| {
        tabs.into_iter().find(|x| {
            zellij::tab_is_for(&x.name, &t.repo)
                || x.name
                    .split_whitespace()
                    .last()
                    .is_some_and(|w| w.starts_with(&prefix))
        })
    });
    if let Some(tab) = found {
        return zellij::go_to_tab(session, tab.tab_id);
    }
    zellij::new_tab(session, dir, &zellij::tab_name(dir, &t.repo))?;
    // A fresh session's lone shell tab goes once the repo's exists, so the
    // session never empties.
    if let Some(lone) = lone {
        zellij::close_tab(session, lone)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repo_of_takes_the_repo_from_a_pr_url() {
        assert_eq!(
            repo_of("https://github.com/acme/app/pull/7").unwrap(),
            "app"
        );
        assert!(repo_of("https://example.com/acme/app/pull/7").is_err());
    }
}
