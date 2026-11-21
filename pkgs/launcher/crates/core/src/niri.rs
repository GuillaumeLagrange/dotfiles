//! What the daemon asks of niri, through `niri msg`: launching a command with the session's
//! environment, focusing and closing windows, and the window and workspace lists.

use std::process::{Command, Stdio};

use anyhow::{bail, Context, Result};
use serde::Deserialize;

#[derive(Debug, Clone, Deserialize)]
pub struct Timestamp {
    pub secs: u64,
    pub nanos: u32,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Window {
    pub id: u64,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub app_id: Option<String>,
    #[serde(default)]
    pub pid: Option<i32>,
    #[serde(default)]
    pub workspace_id: Option<u64>,
    #[serde(default)]
    pub is_focused: bool,
    #[serde(default)]
    pub is_floating: bool,
    #[serde(default)]
    pub focus_timestamp: Option<Timestamp>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Workspace {
    pub id: u64,
    pub idx: u32,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub output: Option<String>,
    #[serde(default)]
    pub is_focused: bool,
}

fn msg(args: &[&str]) -> Result<Vec<u8>> {
    let out = Command::new("niri")
        .arg("msg")
        .args(args)
        .stdin(Stdio::null())
        .output()
        .context("running niri msg")?;
    if !out.status.success() {
        bail!(
            "niri msg {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(out.stdout)
}

/// Runs `argv` as niri's child, so it gets the session's environment rather than the daemon's.
/// The program is resolved on the daemon's own PATH first, which its wrapper sets, so what runs
/// does not depend on the session's.
pub fn spawn(argv: &[String]) -> Result<()> {
    let Some((program, rest)) = argv.split_first() else {
        bail!("nothing to run");
    };
    let program = resolve(program);
    let mut args = vec!["action", "spawn", "--", program.as_str()];
    args.extend(rest.iter().map(String::as_str));
    msg(&args).map(drop)
}

/// `program` as an absolute path when the daemon's PATH has it, else unchanged.
fn resolve(program: &str) -> String {
    if program.contains('/') {
        return program.to_owned();
    }
    std::env::var_os("PATH")
        .iter()
        .flat_map(std::env::split_paths)
        .map(|dir| dir.join(program))
        .find(|path| {
            use std::os::unix::fs::PermissionsExt;
            path.metadata()
                .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        })
        .map_or_else(
            || program.to_owned(),
            |path| path.to_string_lossy().into_owned(),
        )
}

pub fn focus_window(id: u64) -> Result<()> {
    msg(&["action", "focus-window", "--id", &id.to_string()]).map(drop)
}

pub fn close_window(id: u64) -> Result<()> {
    msg(&["action", "close-window", "--id", &id.to_string()]).map(drop)
}

pub fn windows() -> Result<Vec<Window>> {
    serde_json::from_slice(&msg(&["--json", "windows"])?).context("parsing niri's windows")
}

pub fn workspaces() -> Result<Vec<Workspace>> {
    serde_json::from_slice(&msg(&["--json", "workspaces"])?).context("parsing niri's workspaces")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn programs_resolve_on_the_daemons_path() {
        let sh = resolve("sh");
        assert!(sh.starts_with('/') && sh.ends_with("/sh"), "{sh}");
        assert_eq!(resolve("/opt/x/tool"), "/opt/x/tool");
        assert_eq!(
            resolve("no-such-program-anywhere"),
            "no-such-program-anywhere"
        );
    }
}
