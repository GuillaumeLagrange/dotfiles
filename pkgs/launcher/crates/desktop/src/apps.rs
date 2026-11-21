//! Apps: the visible desktop entries, launched through niri.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use launcher_core::{Action, Ctx, Entry, Icon, Mode, Outcome, Source};

use crate::entry::{self, App};

#[derive(Default)]
struct State {
    apps: Vec<App>,
    entries: Arc<Vec<Entry>>,
}

pub struct Apps {
    data_dirs: Vec<PathBuf>,
    desktops: Vec<String>,
    state: Arc<Mutex<State>>,
}

impl Apps {
    pub fn new(ctx: &Ctx, data_dirs: Vec<PathBuf>, desktops: Vec<String>) -> Apps {
        let apps = Apps {
            data_dirs,
            desktops,
            state: Arc::default(),
        };
        apps.rescan(ctx);
        apps
    }

    fn rescan(&self, ctx: &Ctx) {
        let (dirs, desktops, state, ctx) = (
            self.data_dirs.clone(),
            self.desktops.clone(),
            self.state.clone(),
            ctx.clone(),
        );
        std::thread::spawn(move || {
            let mut apps: Vec<App> = entry::scan(&dirs, &desktops)
                .into_iter()
                .filter(|a| a.visible)
                .collect();
            apps.sort_by_cached_key(|a| (a.name.to_lowercase(), a.id.clone()));
            let mut guard = state.lock().unwrap();
            if guard.apps == apps {
                return;
            }
            guard.entries = Arc::new(apps.iter().map(to_entry).collect());
            guard.apps = apps;
            drop(guard);
            ctx.updated(Mode::Apps);
        });
    }
}

fn to_entry(app: &App) -> Entry {
    let mut actions = vec![Action::new("open", "Open", Some("Return"))];
    actions.extend(
        app.actions
            .iter()
            .map(|a| Action::new(&format!("action:{}", a.id), &a.name, None)),
    );
    let mut entry = Entry::new(&app.id, &app.name, actions.into());
    entry.subtitle = if app.generic_name.is_empty() {
        app.comment.clone()
    } else {
        app.generic_name.clone()
    };
    let mut keywords = app.keywords.clone();
    keywords.extend(app.categories.iter().cloned());
    keywords.extend(entry::program(app));
    entry.keywords = keywords.join(" ");
    entry.icon = icon(&app.icon);
    entry
}

pub fn icon(name: &str) -> Icon {
    if name.is_empty() {
        Icon::None
    } else if name.starts_with('/') {
        Icon::Path(name.into())
    } else {
        Icon::Name(name.to_owned())
    }
}

impl Source for Apps {
    fn mode(&self) -> Mode {
        Mode::Apps
    }

    fn open(&mut self, ctx: &Ctx) {
        self.rescan(ctx);
    }

    fn entries(&self) -> Arc<Vec<Entry>> {
        self.state.lock().unwrap().entries.clone()
    }

    fn frecency(&self) -> bool {
        true
    }

    fn activate(&mut self, id: &str, action: &str, ctx: &Ctx) -> Outcome {
        let state = self.state.lock().unwrap();
        let Some(app) = state.apps.iter().find(|a| a.id == id) else {
            return Outcome::Error(format!("no application {id}"));
        };
        let exec = match action.strip_prefix("action:") {
            None => &app.exec,
            Some(name) => match app.actions.iter().find(|a| a.id == name) {
                Some(a) => &a.exec,
                None => return Outcome::Error(format!("{id} has no action {name}")),
            },
        };
        match entry::launch_argv(exec, app, &ctx.config.terminal) {
            Some(argv) => ctx.spawn(&argv),
            None => Outcome::Error(format!("{id}: invalid Exec")),
        }
    }
}
