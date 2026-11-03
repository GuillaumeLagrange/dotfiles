use wt_core::config::Config;

/// The main checkout: the workspace itself, and the zellij session working in
/// it, for tools that open something there rather than in a session.
pub fn run(cfg: &Config, path: bool) {
    if path {
        println!("{}", cfg.workspace.display());
    } else {
        println!("{}", cfg.main_session);
    }
}
