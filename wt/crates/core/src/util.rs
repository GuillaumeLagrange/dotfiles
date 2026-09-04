use std::ffi::OsStr;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use anyhow::{anyhow, Context, Result};

pub fn home() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
}

pub fn expand_tilde(s: &str) -> PathBuf {
    match s.strip_prefix('~') {
        Some(rest) => home().join(rest.trim_start_matches('/')),
        None => PathBuf::from(s),
    }
}

/// Inverse of [`expand_tilde`], so stored paths survive a `$HOME` that moves.
pub fn contract_tilde(path: &Path) -> String {
    match path.strip_prefix(home()) {
        Ok(rest) if rest.as_os_str().is_empty() => "~".to_string(),
        Ok(rest) => format!("~/{}", rest.display()),
        Err(_) => path.display().to_string(),
    }
}

pub fn xdg_dir(var: &str, fallback: &str) -> PathBuf {
    std::env::var_os(var)
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| home().join(fallback))
}

pub struct Output {
    pub status: i32,
    pub stdout: String,
    pub stderr: String,
}

impl Output {
    pub fn ok(&self) -> bool {
        self.status == 0
    }
}

fn describe<S: AsRef<OsStr>>(program: &str, args: &[S]) -> String {
    let mut out = program.to_string();
    for a in args {
        out.push(' ');
        out.push_str(&a.as_ref().to_string_lossy());
    }
    out
}

/// Run a command, capturing both streams. A non-zero exit is not an error here —
/// callers that need one use [`checked`].
pub fn capture<S: AsRef<OsStr>>(program: &str, args: &[S], cwd: Option<&Path>) -> Result<Output> {
    let mut cmd = Command::new(program);
    cmd.args(args).stdin(Stdio::null());
    if let Some(dir) = cwd {
        cmd.current_dir(dir);
    }
    let out = cmd
        .output()
        .with_context(|| format!("failed to spawn `{}`", describe(program, args)))?;
    Ok(Output {
        status: out.status.code().unwrap_or(-1),
        stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
    })
}

pub fn checked<S: AsRef<OsStr>>(program: &str, args: &[S], cwd: Option<&Path>) -> Result<String> {
    let out = capture(program, args, cwd)?;
    if !out.ok() {
        return Err(anyhow!(
            "`{}` exited {}: {}",
            describe(program, args),
            out.status,
            out.stderr.trim()
        ));
    }
    Ok(out.stdout)
}

/// Run a command with the parent's streams attached, for anything the user is
/// meant to see or interact with.
pub fn passthrough<S: AsRef<OsStr>>(program: &str, args: &[S], cwd: Option<&Path>) -> Result<i32> {
    let mut cmd = Command::new(program);
    cmd.args(args);
    if let Some(dir) = cwd {
        cmd.current_dir(dir);
    }
    let status = cmd
        .status()
        .with_context(|| format!("failed to spawn `{}`", describe(program, args)))?;
    Ok(status.code().unwrap_or(-1))
}

/// Single-quote a string for a shell command line.
pub fn shell_quote(raw: &str) -> String {
    format!("'{}'", raw.replace('\'', r"'\''"))
}

/// Run `command` in an interactive `$SHELL` that has `cd`-ed into `cwd` first.
///
/// A plain spawn inherits whatever environment wt was started with, but a repo's
/// toolchain is chosen by the per-directory hooks of an interactive shell — fnm
/// picking a node version, direnv loading a flake. Anything that then runs the
/// repo's own hooks needs to have been through that.
pub fn shell_in(cwd: &Path, command: &str) -> Result<Output> {
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "sh".to_string());
    let script = format!("cd {} && {command}", shell_quote(&cwd.to_string_lossy()));
    capture(&shell, &["-i", "-c", &script], None)
}

pub fn which(program: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(program))
        .find(|candidate| candidate.is_file())
}

/// Hand the terminal over to `program` and exit with its status.
pub fn run_and_exit<S: AsRef<OsStr>>(
    program: &str,
    args: &[S],
) -> Result<std::convert::Infallible> {
    let code = passthrough(program, args, None)?;
    std::process::exit(code);
}

pub fn write_atomic(path: &Path, contents: &str) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow!("{} has no parent directory", path.display()))?;
    std::fs::create_dir_all(parent)
        .with_context(|| format!("failed to create {}", parent.display()))?;
    let tmp = parent.join(format!(
        ".{}.tmp{}",
        path.file_name().unwrap_or_default().to_string_lossy(),
        std::process::id()
    ));
    {
        let mut f = std::fs::File::create(&tmp)
            .with_context(|| format!("failed to create {}", tmp.display()))?;
        f.write_all(contents.as_bytes())?;
        f.sync_all()?;
    }
    std::fs::rename(&tmp, path)
        .with_context(|| format!("failed to move {} into place", path.display()))?;
    Ok(())
}

pub fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// True when `path` is a symlink, whether or not its target resolves.
pub fn is_symlink(path: &Path) -> bool {
    std::fs::symlink_metadata(path)
        .map(|m| m.file_type().is_symlink())
        .unwrap_or(false)
}

pub fn exists(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tilde_round_trips() {
        let p = home().join("work/sessions/proj-1");
        assert_eq!(contract_tilde(&p), "~/work/sessions/proj-1");
        assert_eq!(expand_tilde("~/work/sessions/proj-1"), p);
        assert_eq!(expand_tilde("/etc/passwd"), PathBuf::from("/etc/passwd"));
    }
}
