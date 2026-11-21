//! Windows: niri's windows, most recently focused first and the focused one last.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use launcher_core::niri::{self, Window, Workspace};
use launcher_core::{Action, Ctx, Entry, Icon, Mode, Outcome, Source, Status};

use crate::apps::icon;
use crate::entry::{self, App};

#[derive(Default)]
struct State {
    entries: Arc<Vec<Entry>>,
    error: Option<String>,
}

pub struct Windows {
    data_dirs: Vec<PathBuf>,
    actions: Arc<[Action]>,
    state: Arc<Mutex<State>>,
}

impl Windows {
    pub fn new(data_dirs: Vec<PathBuf>) -> Windows {
        Windows {
            data_dirs,
            actions: vec![
                Action::new("focus", "Focus", Some("Return")),
                Action::new("close", "Close window", Some("Shift+Delete")),
            ]
            .into(),
            state: Arc::default(),
        }
    }

    fn refresh(&self, ctx: &Ctx) {
        let (dirs, actions, state, ctx) = (
            self.data_dirs.clone(),
            self.actions.clone(),
            self.state.clone(),
            ctx.clone(),
        );
        std::thread::spawn(move || {
            let listed = niri::windows().and_then(|w| Ok((w, niri::workspaces()?)));
            {
                let mut guard = state.lock().unwrap();
                match listed {
                    Ok((windows, workspaces)) => {
                        let apps = entry::scan(&dirs, &[]);
                        guard.entries = Arc::new(build(windows, &workspaces, &apps, &actions));
                        guard.error = None;
                    }
                    Err(err) => guard.error = Some(format!("{err:#}")),
                }
            }
            ctx.updated(Mode::Windows);
        });
    }
}

/// The desktop entry of an app_id: `<app_id>.desktop`, then StartupWMClass, case-insensitively.
fn find_app<'a>(apps: &'a [App], app_id: &str) -> Option<&'a App> {
    if app_id.is_empty() {
        return None;
    }
    let app_id = app_id.to_lowercase();
    let file = format!("{app_id}.desktop");
    apps.iter()
        .find(|a| a.id.to_lowercase() == file)
        .or_else(|| {
            apps.iter()
                .find(|a| a.startup_wm_class.to_lowercase() == app_id)
        })
}

fn build(
    mut windows: Vec<Window>,
    workspaces: &[Workspace],
    apps: &[App],
    actions: &Arc<[Action]>,
) -> Vec<Entry> {
    let stamp = |w: &Window| w.focus_timestamp.as_ref().map(|t| (t.secs, t.nanos));
    windows.sort_by(|a, b| {
        a.is_focused
            .cmp(&b.is_focused)
            .then(stamp(b).cmp(&stamp(a)))
            .then(a.id.cmp(&b.id))
    });
    let workspaces: HashMap<u64, &Workspace> = workspaces.iter().map(|w| (w.id, w)).collect();
    let outputs: HashSet<_> = workspaces
        .values()
        .filter_map(|w| w.output.as_deref())
        .collect();
    windows
        .into_iter()
        .map(|w| {
            let app_id = w.app_id.unwrap_or_default();
            let app = find_app(apps, &app_id);
            let mut entry = Entry::new(
                w.id.to_string(),
                w.title.unwrap_or_default(),
                actions.clone(),
            );
            entry.subtitle = app.map_or_else(|| app_id.clone(), |a| a.name.clone());
            entry.keywords = app_id;
            entry.icon = app.map_or(Icon::None, |a| icon(&a.icon));
            if let Some(ws) = w.workspace_id.and_then(|id| workspaces.get(&id)) {
                let mut accessory = ws.name.clone().unwrap_or_else(|| ws.idx.to_string());
                if let (true, Some(output)) = (outputs.len() > 1, &ws.output) {
                    accessory = format!("{accessory} · {output}");
                }
                entry.accessory = accessory;
            }
            entry
        })
        .collect()
}

impl Source for Windows {
    fn mode(&self) -> Mode {
        Mode::Windows
    }

    fn open(&mut self, ctx: &Ctx) {
        self.refresh(ctx);
    }

    fn entries(&self) -> Arc<Vec<Entry>> {
        self.state.lock().unwrap().entries.clone()
    }

    fn status(&self) -> Option<Status> {
        self.state.lock().unwrap().error.clone().map(Status::error)
    }

    fn activate(&mut self, id: &str, action: &str, ctx: &Ctx) -> Outcome {
        let Ok(window) = id.parse::<u64>() else {
            return Outcome::Error(format!("no window {id}"));
        };
        match action {
            "close" => {
                if let Err(err) = niri::close_window(window) {
                    return Outcome::Error(format!("{err:#}"));
                }
                {
                    let mut state = self.state.lock().unwrap();
                    let kept = state
                        .entries
                        .iter()
                        .filter(|e| e.id != id)
                        .cloned()
                        .collect();
                    state.entries = Arc::new(kept);
                }
                self.refresh(ctx);
                Outcome::Stay
            }
            _ => match niri::focus_window(window) {
                Ok(()) => Outcome::Close,
                Err(err) => Outcome::Error(format!("{err:#}")),
            },
        }
    }
}
