//! Firefox's open tabs through TabCtl: every `dev.slastra.TabCtl.*` name on the session bus is a
//! browser profile, pulled again whenever one says its tabs changed or a name comes or goes.

use std::fs;
use std::path::PathBuf;
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use launcher_core::niri;
use zbus::blocking::{connection, Connection, MessageIterator};
use zbus::message::Type;
use zbus::MatchRule;

pub(crate) const PREFIX: &str = "dev.slastra.TabCtl.";
pub(crate) const IFACE: &str = "dev.slastra.TabCtl.Browser";
const TIMEOUT: Duration = Duration::from_secs(3);

/// Where the bus is: the session's, or an address (tests).
#[derive(Debug, Clone)]
pub enum Bus {
    Session,
    Address(String),
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Tab {
    /// The bus name's last part: `Firefox`, `Firefox2`, …
    pub instance: String,
    /// The profile directory of the Firefox running the instance, when found.
    pub profile: Option<PathBuf>,
    pub window: i32,
    pub id: i32,
    pub title: String,
    pub url: String,
    pub active: bool,
    pub pinned: bool,
    pub icon: String,
}

impl Tab {
    pub fn bus_name(&self) -> String {
        format!("{PREFIX}{}", self.instance)
    }
}

pub(crate) fn object_path(instance: &str) -> String {
    format!("/dev/slastra/TabCtl/Browser/{instance}")
}

/// The watcher's handles: the connection, once made, and a way to ask for a fresh pull.
#[derive(Default)]
pub(crate) struct Watcher {
    conn: Mutex<Option<Connection>>,
    refresh: Mutex<Option<Sender<()>>>,
}

impl Watcher {
    pub fn conn(&self) -> Option<Connection> {
        self.conn.lock().unwrap().clone()
    }

    pub fn refresh(&self) {
        if let Some(tx) = &*self.refresh.lock().unwrap() {
            let _ = tx.send(());
        }
    }
}

/// Watches the bus on a thread; `changed(tabs, connected)` runs whenever either changes.
pub(crate) fn watch(bus: Bus, changed: impl Fn(Vec<Tab>, bool) + Send + 'static) -> Arc<Watcher> {
    let watcher = Arc::new(Watcher::default());
    let handle = watcher.clone();
    thread::spawn(move || {
        if run(bus, &handle, &changed).is_err() {
            changed(Vec::new(), false);
        }
    });
    watcher
}

fn connect(bus: &Bus) -> zbus::Result<Connection> {
    let builder = match bus {
        Bus::Session => connection::Builder::session()?,
        Bus::Address(address) => connection::Builder::address(address.as_str())?,
    };
    builder.method_timeout(TIMEOUT).build()
}

fn run(bus: Bus, watcher: &Watcher, changed: &impl Fn(Vec<Tab>, bool)) -> zbus::Result<()> {
    let conn = connect(&bus)?;
    let (tx, rx) = mpsc::channel();
    let rules = [
        MatchRule::builder()
            .msg_type(Type::Signal)
            .interface(IFACE)?
            .member("TabsUpdated")?
            .build(),
        MatchRule::builder()
            .msg_type(Type::Signal)
            .sender("org.freedesktop.DBus")?
            .interface("org.freedesktop.DBus")?
            .member("NameOwnerChanged")?
            .arg0ns(&PREFIX[..PREFIX.len() - 1])?
            .build(),
    ];
    // Subscribed before the first pull, so no change falls in between.
    for rule in rules {
        let messages = MessageIterator::for_match_rule(rule, &conn, None)?;
        let tx = tx.clone();
        thread::spawn(move || {
            for message in messages {
                if message.is_ok() && tx.send(()).is_err() {
                    break;
                }
            }
        });
    }
    *watcher.refresh.lock().unwrap() = Some(tx);
    *watcher.conn.lock().unwrap() = Some(conn.clone());

    let mut last: Option<(Vec<Tab>, bool)> = None;
    loop {
        let (mut tabs, connected) = pull(&conn)?;
        last_focused_last(&mut tabs);
        if last.as_ref() != Some(&(tabs.clone(), connected)) {
            changed(tabs.clone(), connected);
            last = Some((tabs, connected));
        }
        if rx.recv().is_err() {
            return Ok(());
        }
        // A page load sends a burst of updates: pull once for all of them.
        thread::sleep(Duration::from_millis(30));
        while rx.try_recv().is_ok() {}
    }
}

type WithIcons = (i32, i32, String, String, i32, bool, bool, String);
type Plain = (i32, i32, String, String, i32, bool, bool);

/// Every instance's tabs, in name then (window, index) order, and whether any instance is up.
fn pull(conn: &Connection) -> zbus::Result<(Vec<Tab>, bool)> {
    let dbus = zbus::blocking::fdo::DBusProxy::new(conn)?;
    let mut names: Vec<String> = dbus
        .list_names()?
        .into_iter()
        .map(|n| n.to_string())
        .filter(|n| n.starts_with(PREFIX))
        .collect();
    names.sort_by_key(|n| (n.len(), n.clone()));
    let mut tabs = Vec::new();
    for name in &names {
        let instance = &name[PREFIX.len()..];
        let mut rows = match list(conn, name, instance) {
            Ok(rows) => rows,
            Err(_) => continue,
        };
        let profile = zbus::names::BusName::try_from(name.as_str())
            .ok()
            .and_then(|n| dbus.get_connection_unix_process_id(n).ok())
            .and_then(host_profile);
        rows.sort_by_key(|(t, index)| (t.window, *index));
        tabs.extend(rows.into_iter().map(|(mut t, _)| {
            t.profile = profile.clone();
            t
        }));
    }
    Ok((tabs, !names.is_empty()))
}

/// The profile of the Firefox that started the native host `pid`: the directory of the
/// `places.sqlite` it holds open.
pub(crate) fn host_profile(pid: u32) -> Option<PathBuf> {
    let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // `pid (comm) state ppid …`; comm may hold spaces and parentheses.
    let ppid = stat.rsplit_once(')')?.1.split_whitespace().nth(1)?;
    fs::read_dir(format!("/proc/{ppid}/fd"))
        .ok()?
        .filter_map(|fd| fs::read_link(fd.ok()?.path()).ok())
        .find(|target| target.file_name().is_some_and(|n| n == "places.sqlite"))
        .and_then(|target| target.parent().map(PathBuf::from))
}

fn list(conn: &Connection, name: &str, instance: &str) -> zbus::Result<Vec<(Tab, i32)>> {
    let path = object_path(instance);
    let tab = |window, id, title, url, active, pinned, icon| Tab {
        instance: instance.to_owned(),
        profile: None,
        window,
        id,
        title,
        url,
        active,
        pinned,
        icon,
    };
    match conn.call_method(
        Some(name),
        path.as_str(),
        Some(IFACE),
        "ListTabsWithIcons",
        &(),
    ) {
        Ok(reply) => Ok(reply
            .body()
            .deserialize::<Vec<WithIcons>>()?
            .into_iter()
            .map(|(w, id, title, url, index, active, pinned, icon)| {
                (tab(w, id, title, url, active, pinned, icon), index)
            })
            .collect()),
        Err(_) => {
            let reply =
                conn.call_method(Some(name), path.as_str(), Some(IFACE), "ListTabs", &())?;
            Ok(reply
                .body()
                .deserialize::<Vec<Plain>>()?
                .into_iter()
                .map(|(w, id, title, url, index, active, pinned)| {
                    (tab(w, id, title, url, active, pinned, String::new()), index)
                })
                .collect())
        }
    }
}

/// Moves the tab the focused Firefox window shows to the end: it is the one already in sight.
fn last_focused_last(tabs: &mut Vec<Tab>) {
    let Ok(windows) = niri::windows() else { return };
    let Some(focused) = windows
        .iter()
        .find(|w| w.is_focused && is_firefox(w))
        .and_then(|w| w.title.as_deref())
    else {
        return;
    };
    if let Some(i) = tabs
        .iter()
        .position(|t| t.active && shows(focused, &t.title))
    {
        let tab = tabs.remove(i);
        tabs.push(tab);
    }
}

fn is_firefox(w: &niri::Window) -> bool {
    w.app_id
        .as_deref()
        .is_some_and(|a| a.to_lowercase().contains("firefox"))
}

/// Whether a Firefox window titled `window` shows a tab titled `tab` (`<title> — Mozilla Firefox`).
fn shows(window: &str, tab: &str) -> bool {
    !tab.is_empty() && window.starts_with(tab)
}

/// Activates a tab and focuses the window showing it. Runs on its own thread.
pub(crate) fn switch(conn: &Connection, tab: &Tab) -> anyhow::Result<()> {
    conn.call_method(
        Some(tab.bus_name().as_str()),
        object_path(&tab.instance).as_str(),
        Some(IFACE),
        "ActivateTab",
        &(tab.id, true),
    )?;
    // Firefox retitles its window once the tab is shown.
    for _ in 0..20 {
        if let Ok(windows) = niri::windows() {
            if let Some(w) = windows
                .iter()
                .find(|w| is_firefox(w) && w.title.as_deref().is_some_and(|t| shows(t, &tab.title)))
            {
                return niri::focus_window(w.id);
            }
        }
        thread::sleep(Duration::from_millis(50));
    }
    Ok(())
}

pub(crate) fn close(conn: &Connection, tab: &Tab) -> anyhow::Result<()> {
    conn.call_method(
        Some(tab.bus_name().as_str()),
        object_path(&tab.instance).as_str(),
        Some(IFACE),
        "CloseTabs",
        &(vec![tab.id],),
    )?;
    Ok(())
}
