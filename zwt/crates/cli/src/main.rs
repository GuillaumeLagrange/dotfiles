mod cmd;
mod complete;
mod ui;

use std::path::PathBuf;

use anyhow::Result;
use clap::{CommandFactory, Parser, Subcommand};
use clap_complete::{ArgValueCandidates, CompleteEnv};

use zwt_core::config::Config;

/// Feature-scoped workspaces spanning several repos: a set of worktrees inside a
/// mirror of the whole checkout.
#[derive(Parser)]
#[command(name = "zwt", version, args_conflicts_with_subcommands = true)]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,

    /// Session whose root to print. Without one, pick from the registry.
    #[arg(value_name = "ID", add = ArgValueCandidates::new(complete::sessions))]
    id: Option<String>,
}

#[derive(Subcommand)]
enum Command {
    /// Create a session: pick its member repos, mirror the workspace, check the
    /// members out detached at their own main branch.
    New {
        /// Names the session and its directory.
        name: String,
        /// Shown in the picker, stored nowhere else.
        #[arg(long)]
        title: Option<String>,
        /// Put the session here instead of the configured root.
        #[arg(long, value_name = "PATH")]
        at: Option<PathBuf>,
        /// Member repos, skipping the picker. Repeatable.
        #[arg(long = "repo", value_name = "REPO")]
        repos: Vec<String>,
        /// Start with no members: just the mirror, to `zwt add` into.
        #[arg(long, conflicts_with = "repos")]
        empty: bool,
    },

    /// Turn a repo's mirror symlink into a detached worktree.
    Add {
        #[arg(add = ArgValueCandidates::new(complete::addable_repos))]
        repo: String,
        #[arg(long, value_name = "ID", add = ArgValueCandidates::new(complete::sessions))]
        session: Option<String>,
    },

    /// The swap backwards: drop the worktree and move the main checkout onto its
    /// branch. The session keeps working, now pointing at the main checkout.
    Promote {
        #[arg(add = ArgValueCandidates::new(complete::member_repos))]
        repo: String,
        #[arg(long, value_name = "ID", add = ArgValueCandidates::new(complete::sessions))]
        session: Option<String>,
    },

    /// Tear a session down, refusing while it still holds work.
    Rm {
        #[arg(add = ArgValueCandidates::new(complete::sessions))]
        id: Option<String>,
        #[arg(long)]
        force: bool,
    },

    /// Sessions, members and branches.
    Ls {
        #[arg(long)]
        json: bool,
    },

    /// Report drift between a session and the workspace.
    Sync {
        #[arg(add = ArgValueCandidates::new(complete::sessions))]
        id: Option<String>,
        /// Repair what can be repaired.
        #[arg(long)]
        fix: bool,
        /// Every registered session.
        #[arg(long)]
        all: bool,
    },

    /// Print a session's root: the one named, else the one holding the cwd.
    Path {
        #[arg(add = ArgValueCandidates::new(complete::sessions))]
        id: Option<String>,
        /// Print the zellij layout to attach with instead of the root.
        #[arg(long)]
        layout: bool,
        /// Take the id literally, rather than as a prefix. For callers handing over
        /// a name they did not get from the registry, where the nearest session is
        /// the wrong answer.
        #[arg(long)]
        exact: bool,
    },
}

fn main() {
    // Answers the shell's completion request and exits; a no-op otherwise. Must
    // come before parsing, since a completion request is not a valid command line.
    CompleteEnv::with_factory(Cli::command).complete();

    if let Err(err) = run() {
        eprintln!("zwt: {err:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let cli = Cli::parse();
    let cfg = Config::load()?;
    match cli.command {
        None => cmd::path::pick(&cfg, cli.id.as_deref()),
        Some(Command::New {
            name,
            title,
            at,
            repos,
            empty,
        }) => cmd::new::run(
            &cfg,
            cmd::new::Args {
                name,
                title,
                at,
                repos,
                empty,
            },
        ),
        Some(Command::Add { repo, session }) => cmd::add::run(&cfg, &repo, session.as_deref()),
        Some(Command::Promote { repo, session }) => {
            cmd::promote::run(&cfg, &repo, session.as_deref())
        }
        Some(Command::Rm { id, force }) => cmd::remove::run(&cfg, id.as_deref(), force),
        Some(Command::Ls { json }) => cmd::ls::run(&cfg, json),
        Some(Command::Sync { id, fix, all }) => cmd::sync::run(&cfg, id.as_deref(), fix, all),
        Some(Command::Path { id, layout, exact }) => {
            cmd::path::run(&cfg, id.as_deref(), layout, exact)
        }
    }
}
