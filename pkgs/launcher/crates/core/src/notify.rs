//! Desktop notifications, sent over D-Bus rather than through notify-send: notify-send closes
//! its notification as it exits in some modes, and the bar drops a notification its sender closed.

use std::collections::HashMap;

/// Sends on a thread of its own: the bus may be slow, and callers are on the engine's thread.
pub fn send(summary: &str, body: &str) {
    let (summary, body) = (summary.to_owned(), body.to_owned());
    std::thread::spawn(move || {
        if let Err(err) = notify(&summary, &body) {
            eprintln!("launcher: notification {summary:?}: {err:#}");
        }
    });
}

fn notify(summary: &str, body: &str) -> anyhow::Result<()> {
    let bus = zbus::blocking::Connection::session()?;
    let hints: HashMap<&str, zbus::zvariant::Value> = HashMap::new();
    bus.call_method(
        Some("org.freedesktop.Notifications"),
        "/org/freedesktop/Notifications",
        Some("org.freedesktop.Notifications"),
        "Notify",
        &(
            "launcher",
            0u32,
            "",
            summary,
            body,
            Vec::<&str>::new(),
            hints,
            -1i32,
        ),
    )?;
    Ok(())
}
