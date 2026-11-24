//! Apps, windows, emoji and power.

mod apps;
mod emoji;
mod entry;
mod power;
mod windows;

use launcher_core::{Ctx, Mode, Source};

pub use apps::Apps;
pub use emoji::Emojis;
pub use power::Power;
pub use windows::Windows;

/// The enabled ones of: Apps, Windows, Emoji, Power.
pub fn sources(ctx: &Ctx) -> anyhow::Result<Vec<Box<dyn Source>>> {
    let mut sources: Vec<Box<dyn Source>> = Vec::new();
    if ctx.config.enabled(Mode::Apps) {
        sources.push(Box::new(Apps::new(
            ctx,
            entry::data_dirs_from_env(),
            entry::desktops_from_env(),
        )));
    }
    if ctx.config.enabled(Mode::Windows) {
        sources.push(Box::new(Windows::new(entry::data_dirs_from_env())));
    }
    if ctx.config.enabled(Mode::Emoji) {
        sources.push(Box::new(Emojis::new(ctx)?));
    }
    if ctx.config.enabled(Mode::Power) {
        sources.push(Box::new(Power::new(ctx)?));
    }
    Ok(sources)
}
