//! Getting the user to a pane: one terminal window per zellij session, so the
//! window already showing the session is focused, or one is opened for it.

use std::os::unix::process::CommandExt;
use std::process::Command;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use serde::Deserialize;

use crate::zellij;

/// How a window is opened for a session, from the wrapper's environment.
pub struct Launcher {
    /// The terminal's argv prefix for running a command, e.g. `xdg-terminal-exec`.
    pub term_exec: Vec<String>,
    /// Attaches to a session by name the way zsm does.
    pub attach: String,
}

impl Launcher {
    pub fn from_env() -> Result<Self> {
        let term_exec = match std::env::var("OMP_PANEL_TERM_EXEC") {
            Ok(json) => {
                serde_json::from_str(&json).context("OMP_PANEL_TERM_EXEC is not a JSON list")?
            }
            Err(_) => vec!["xdg-terminal-exec".into()],
        };
        let attach = std::env::var("OMP_PANEL_ATTACH").unwrap_or_else(|_| "zellij-attach".into());
        Ok(Self { term_exec, attach })
    }
}

#[derive(Deserialize)]
struct Window {
    id: u64,
    title: Option<String>,
}

/// zellij titles its terminal `<session> | <pane>`.
fn shows_session(title: &str, session: &str) -> bool {
    title == session
        || title
            .strip_prefix(session)
            .is_some_and(|rest| rest.starts_with(" | "))
}

fn niri(args: &[&str]) -> Result<String> {
    let out = Command::new("niri")
        .arg("msg")
        .args(args)
        .output()
        .context("running niri")?;
    if !out.status.success() {
        bail!(
            "`niri msg {}` failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

fn session_window(session: &str) -> Result<Option<u64>> {
    let windows: Vec<Window> =
        serde_json::from_str(&niri(&["-j", "windows"])?).context("parsing niri windows")?;
    Ok(windows
        .into_iter()
        .find(|w| {
            w.title
                .as_deref()
                .is_some_and(|t| shows_session(t, session))
        })
        .map(|w| w.id))
}

pub fn jump(session: &str, pane: u32, launcher: &Launcher) -> Result<()> {
    // niri needs its socket, which only processes under a niri session inherit.
    if std::env::var_os("NIRI_SOCKET").is_some() {
        match session_window(session)? {
            Some(id) => niri(&["action", "focus-window", "--id", &id.to_string()]).map(drop)?,
            None => {
                // Through niri rather than as a child: the window must not inherit this
                // pane's environment, ZELLIJ included, which would make it refuse to attach.
                let mut args = vec!["action", "spawn", "--"];
                args.extend(launcher.term_exec.iter().map(String::as_str));
                args.extend([launcher.attach.as_str(), session]);
                niri(&args)?;
                if !zellij::wait_for_client(session, Duration::from_secs(10)) {
                    bail!("no window attached to `{session}`");
                }
            }
        }
        return zellij::focus_pane(session, pane);
    }

    match std::env::var("ZELLIJ_SESSION_NAME") {
        Ok(current) if current == session => zellij::focus_pane(session, pane),
        Ok(_) => zellij::switch_session(session, pane),
        // A bare terminal, over ssh say: become the session's client.
        Err(_) => {
            zellij::focus_pane(session, pane)?;
            Err(Command::new(&launcher.attach).arg(session).exec()).context("attaching")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::shows_session;

    #[test]
    fn a_window_shows_a_session_by_exact_title_or_prefix() {
        assert!(shows_session("work", "work"));
        assert!(shows_session("work | omp", "work"));
        assert!(!shows_session("work-2 | omp", "work"));
        assert!(!shows_session("workshop", "work"));
    }
}
