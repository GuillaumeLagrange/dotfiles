//! Every terminal pane of every live session, with the command in its foreground.
//!
//! zellij only knows what a pane was started with, the shell mostly. What runs in
//! it now comes from /proc: zellij puts `ZELLIJ_SESSION_NAME` and `ZELLIJ_PANE_ID`
//! in the environment of the process it spawns in a pane, whose terminal's
//! foreground process group is led by the command to show.

use std::collections::HashMap;
use std::fs;

use serde::Serialize;

use crate::zellij;

#[derive(Serialize, Debug, Clone)]
pub struct PaneRow {
    pub session: String,
    pub pane_id: u32,
    pub tab: String,
    #[serde(skip)]
    pub tab_position: u32,
    pub title: String,
    pub command: String,
    /// A shell at its prompt.
    pub idle: bool,
    pub cwd: String,
}

impl PaneRow {
    /// Whether every whitespace-separated term of `query` is in the row,
    /// ignoring case.
    pub fn matches(&self, query: &str) -> bool {
        let hay = format!(
            "{} {} {} {} {}",
            self.session, self.tab, self.title, self.command, self.cwd
        )
        .to_lowercase();
        query
            .to_lowercase()
            .split_whitespace()
            .all(|term| hay.contains(term))
    }
}

const SHELLS: &[&str] = &["zsh", "bash", "sh", "dash", "fish", "nu"];
/// Dropped in front of the script they run: `node …/bin/pnpm dev` is `pnpm dev`.
const INTERPRETERS: &[&str] = &[
    "node", "bun", "deno", "python", "python3", "ruby", "perl", "sh", "bash",
];

fn base(arg: &str) -> &str {
    arg.rsplit('/')
        .next()
        .unwrap_or(arg)
        .trim_start_matches('-')
}

/// The command line as shown: program names without their path, on one line.
pub fn display(argv: &[String]) -> String {
    let mut args = argv;
    if args.len() > 1 && INTERPRETERS.contains(&base(&args[0])) && !args[1].starts_with('-') {
        args = &args[1..];
    }
    let Some((program, rest)) = args.split_first() else {
        return String::new();
    };
    std::iter::once(base(program))
        .chain(rest.iter().map(String::as_str))
        .flat_map(str::split_whitespace)
        .collect::<Vec<_>>()
        .join(" ")
}

fn is_idle(argv: &[String]) -> bool {
    argv.first()
        .is_some_and(|program| SHELLS.contains(&base(program)))
        && argv[1..].iter().all(|arg| arg.starts_with('-'))
}

/// `(ppid, tpgid)` from `/proc/<pid>/stat`.
fn stat(pid: u32) -> Option<(u32, i32)> {
    let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // The command name is parenthesised and may hold spaces or parentheses itself.
    let mut fields = stat.get(stat.rfind(')')? + 2..)?.split(' ');
    let ppid = fields.nth(1)?.parse().ok()?;
    let tpgid = fields.nth(3)?.parse().ok()?;
    Some((ppid, tpgid))
}

fn pane_of(pid: u32) -> Option<(String, u32)> {
    let environ = fs::read(format!("/proc/{pid}/environ")).ok()?;
    let (mut session, mut pane) = (None, None);
    for var in environ.split(|&b| b == 0) {
        if let Some(v) = var.strip_prefix(b"ZELLIJ_SESSION_NAME=") {
            session = Some(String::from_utf8_lossy(v).into_owned());
        } else if let Some(v) = var.strip_prefix(b"ZELLIJ_PANE_ID=") {
            pane = std::str::from_utf8(v).ok()?.parse().ok();
        }
    }
    Some((session?, pane?))
}

fn cmdline(pid: u32) -> Option<Vec<String>> {
    let raw = fs::read(format!("/proc/{pid}/cmdline")).ok()?;
    let argv: Vec<String> = raw
        .split(|&b| b == 0)
        .filter(|arg| !arg.is_empty())
        .map(|arg| String::from_utf8_lossy(arg).into_owned())
        .collect();
    (!argv.is_empty()).then_some(argv)
}

struct Foreground {
    argv: Vec<String>,
    cwd: Option<String>,
}

/// What runs in each pane's foreground, by session and pane.
fn foregrounds() -> HashMap<(String, u32), Foreground> {
    let mut out = HashMap::new();
    let Ok(dir) = fs::read_dir("/proc") else {
        return out;
    };
    for entry in dir.flatten() {
        let Some(pid) = entry
            .file_name()
            .to_str()
            .and_then(|n| n.parse::<u32>().ok())
        else {
            continue;
        };
        // A pane's own process is the zellij server's child; the processes it
        // starts inherit its variables, some on terminals of their own.
        let Some((ppid, tpgid)) = stat(pid) else {
            continue;
        };
        let parent_is_zellij = fs::read_to_string(format!("/proc/{ppid}/comm"))
            .is_ok_and(|comm| comm.trim_end() == "zellij");
        if !parent_is_zellij {
            continue;
        }
        let Some(key) = pane_of(pid) else {
            continue;
        };
        let leader = u32::try_from(tpgid).ok().filter(|&p| p > 0);
        let Some((fg, argv)) = leader
            .and_then(|p| Some((p, cmdline(p)?)))
            .or_else(|| Some((pid, cmdline(pid)?)))
        else {
            continue;
        };
        let cwd = fs::read_link(format!("/proc/{fg}/cwd"))
            .ok()
            .map(|p| p.display().to_string());
        out.insert(key, Foreground { argv, cwd });
    }
    out
}

/// Every terminal pane of the live sessions, by session, tab and pane.
pub fn collect() -> Vec<PaneRow> {
    let mut foregrounds = foregrounds();
    let mut rows = Vec::new();
    for session in zellij::live_sessions() {
        // A session can die between the listing and this.
        let Ok(panes) = zellij::terminal_panes(&session) else {
            continue;
        };
        for pane in panes {
            // A process zellij spawned is ours, so this only misses while it starts,
            // or once a held pane's command has exited.
            let found = foregrounds.remove(&(session.clone(), pane.id));
            let argv = found.as_ref().map(|f| f.argv.clone()).unwrap_or_else(|| {
                pane.pane_command
                    .as_deref()
                    .or(pane.terminal_command.as_deref())
                    .unwrap_or_default()
                    .split_whitespace()
                    .map(str::to_owned)
                    .collect()
            });
            let exited = pane.is_held && found.is_none();
            let mut command = display(&argv);
            if exited {
                command.push_str(" (exited)");
            }
            rows.push(PaneRow {
                session: session.clone(),
                pane_id: pane.id,
                tab: pane.tab_name.unwrap_or_default(),
                tab_position: pane.tab_position.unwrap_or_default(),
                title: pane.title.unwrap_or_default(),
                command,
                idle: exited || is_idle(&argv),
                cwd: found
                    .and_then(|f| f.cwd)
                    .or(pane.pane_cwd)
                    .unwrap_or_default(),
            });
        }
    }
    rows.sort_by(|a, b| {
        (&a.session, a.tab_position, a.pane_id).cmp(&(&b.session, b.tab_position, b.pane_id))
    });
    rows
}

#[cfg(test)]
mod tests {
    use super::*;

    fn argv(args: &[&str]) -> Vec<String> {
        args.iter().map(|a| a.to_string()).collect()
    }

    #[test]
    fn display_drops_interpreter_and_paths() {
        let pnpm = argv(&[
            "/nix/store/x-nodejs/bin/node",
            "/run/user/1000/fnm/bin/pnpm",
            "dev",
        ]);
        assert_eq!(display(&pnpm), "pnpm dev");
        // An interpreter given a flag runs no script to name.
        assert_eq!(
            display(&argv(&["bash", "-c", "make\nwatch"])),
            "bash -c make watch"
        );
        assert_eq!(display(&argv(&["-zsh"])), "zsh");
    }

    #[test]
    fn idle_is_a_bare_shell() {
        assert!(is_idle(&argv(&["/run/current-system/sw/bin/zsh"])));
        assert!(is_idle(&argv(&["zsh", "-i"])));
        assert!(!is_idle(&argv(&["zsh", "-c", "pnpm dev"])));
        assert!(!is_idle(&argv(&["nvim"])));
    }

    #[test]
    fn every_term_must_match() {
        let row = PaneRow {
            session: "codspeed".into(),
            pane_id: 1,
            tab: "front".into(),
            tab_position: 0,
            title: String::new(),
            command: "pnpm dev".into(),
            idle: false,
            cwd: "/home/g/platform".into(),
        };
        assert!(row.matches("PNPM platform"));
        assert!(row.matches(""));
        assert!(!row.matches("pnpm build"));
    }
}
