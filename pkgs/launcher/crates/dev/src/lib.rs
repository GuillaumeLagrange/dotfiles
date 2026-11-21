//! zellij sessions, PRs to review and files.

use launcher_core::{Ctx, Mode, Source};

mod files;
mod reviews;
mod sessions;

pub use files::Files;
pub use reviews::Reviews;
pub use sessions::Sessions;

/// The enabled ones of: Sessions, Reviews, Files.
pub fn sources(ctx: &Ctx) -> anyhow::Result<Vec<Box<dyn Source>>> {
    let mut sources: Vec<Box<dyn Source>> = Vec::new();
    if ctx.config.enabled(Mode::Sessions) {
        sources.push(Box::new(Sessions::new()));
    }
    if ctx.config.enabled(Mode::Reviews) {
        sources.push(Box::new(Reviews::new(ctx.section(Mode::Reviews)?)));
    }
    if ctx.config.enabled(Mode::Files) {
        sources.push(Box::new(Files::new(ctx.section(Mode::Files)?)));
    }
    Ok(sources)
}

fn argv(args: &[&str]) -> Vec<String> {
    args.iter().map(|a| (*a).to_owned()).collect()
}

#[cfg(test)]
mod testing;
