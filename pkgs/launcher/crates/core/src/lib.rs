//! The launcher daemon's core: the wire, the engine, matching, and the contract sources
//! implement. See AGENTS.md at the root of the workspace.

pub mod clipboard;
pub mod config;
pub mod engine;
pub mod frecency;
pub mod matcher;
pub mod niri;
pub mod notify;
pub mod protocol;
pub mod server;
pub mod source;
pub mod testing;

pub use clipboard::{Clipboard, Offer};
pub use config::Config;
pub use source::{
    Action, Ctx, Dirs, Entry, Icon, Mode, Outcome, Preview, Source, Status, StatusKind, Work,
};
