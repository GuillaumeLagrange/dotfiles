use std::io::{BufRead, BufReader, IsTerminal, Write};
use std::process::{Command, Stdio};

use anyhow::{Context, Result};

pub struct Choice {
    pub key: String,
    pub display: String,
}

impl Choice {
    pub fn new(key: impl Into<String>, display: impl Into<String>) -> Self {
        Self {
            key: key.into(),
            display: display.into(),
        }
    }
}

pub fn interactive() -> bool {
    std::io::stdin().is_terminal() || std::fs::File::open("/dev/tty").is_ok()
}

/// Run fzf over `choices`, returning the keys of whatever was picked.
fn fzf(choices: &[Choice], prompt: &str, multi: bool) -> Result<Vec<String>> {
    anyhow::ensure!(!choices.is_empty(), "nothing to pick from");
    anyhow::ensure!(
        interactive(),
        "`{prompt}` needs a terminal; pass the choice explicitly instead"
    );

    let mut args = vec![
        "--ansi".to_string(),
        "--delimiter=\t".to_string(),
        "--with-nth=2..".to_string(),
        format!("--prompt={prompt} "),
        "--height=~60%".to_string(),
        "--layout=reverse".to_string(),
    ];
    if multi {
        args.push("--multi".to_string());
        args.push("--bind=ctrl-a:select-all,ctrl-d:deselect-all".to_string());
        args.push("--header=tab toggles · enter accepts".to_string());
    }

    let mut child = Command::new("fzf")
        .args(&args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .context("failed to run fzf")?;

    {
        let stdin = child.stdin.as_mut().expect("piped");
        for c in choices {
            writeln!(stdin, "{}\t{}", c.key, c.display)?;
        }
    }

    let out = child.wait_with_output()?;
    // A cancelled picker exits non-zero, and cancelling is not an error.
    if !out.status.success() {
        return Ok(Vec::new());
    }
    Ok(String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| l.split('\t').next())
        .filter(|k| !k.is_empty())
        .map(str::to_string)
        .collect())
}

pub fn pick_one(choices: &[Choice], prompt: &str) -> Result<Option<String>> {
    Ok(fzf(choices, prompt, false)?.into_iter().next())
}

/// Multi-select, empty when nothing was picked — which a cancelled picker also
/// returns, so callers cannot tell the two apart.
pub fn pick_many(choices: &[Choice], prompt: &str) -> Result<Vec<String>> {
    fzf(choices, prompt, true)
}

pub fn confirm(question: &str, default_yes: bool) -> Result<bool> {
    if !interactive() {
        return Ok(false);
    }
    let tty = std::fs::File::open("/dev/tty").context("no terminal to ask on")?;
    let hint = if default_yes { "[Y/n]" } else { "[y/N]" };
    eprint!("{question} {hint} ");
    std::io::stderr().flush()?;
    let mut line = String::new();
    BufReader::new(tty).read_line(&mut line)?;
    let answer = line.trim().to_lowercase();
    Ok(match answer.as_str() {
        "" => default_yes,
        "y" | "yes" => true,
        _ => false,
    })
}
