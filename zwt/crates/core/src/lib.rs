//! Session-scoped multi-repo workspaces: a set of worktrees mirroring the real
//! checkout, inside a mirror that keeps every sibling path valid.

pub mod config;
pub mod drift;
pub mod envrc;
pub mod git;
pub mod hydrate;
pub mod layout;
pub mod mirror;
pub mod registry;
pub mod session;
pub mod util;
pub mod workspace;
