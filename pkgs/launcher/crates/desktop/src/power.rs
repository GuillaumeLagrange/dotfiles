//! Power: sleep, hibernate, reboot and power off, through `systemctl`.

use std::process::Command;
use std::sync::Arc;

use launcher_core::{Action, Ctx, Entry, Icon, Mode, Outcome, Source, Work};
use serde::Deserialize;

/// The `power` config section.
#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub systemctl: String,
}

impl Default for Settings {
    fn default() -> Settings {
        Settings {
            systemctl: "systemctl".into(),
        }
    }
}

/// `(systemctl verb, title, glyph, keywords, what the panel says meanwhile)`, mildest first:
/// Enter on the first row only suspends.
const VERBS: [(&str, &str, &str, &str, &str); 4] = [
    ("suspend", "Sleep", "sleep", "suspend", "Going to sleep…"),
    ("hibernate", "Hibernate", "hibernate", "", "Hibernating…"),
    ("reboot", "Reboot", "restart", "restart", "Rebooting…"),
    (
        "poweroff",
        "Power off",
        "power",
        "shutdown shut down",
        "Powering off…",
    ),
];

pub struct Power {
    systemctl: String,
    entries: Arc<Vec<Entry>>,
}

impl Power {
    pub fn new(ctx: &Ctx) -> anyhow::Result<Power> {
        let settings: Settings = ctx.config.section(Mode::Power)?;
        let actions: Arc<[Action]> = Arc::new([Action::new("run", "Run", Some("Return"))]);
        let entries = VERBS
            .iter()
            .map(|(verb, title, glyph, keywords, _)| {
                let mut e = Entry::new(*verb, *title, actions.clone());
                e.icon = Icon::Glyph((*glyph).into());
                e.keywords = (*keywords).into();
                e
            })
            .collect();
        Ok(Power {
            systemctl: settings.systemctl,
            entries: Arc::new(entries),
        })
    }
}

impl Source for Power {
    fn mode(&self) -> Mode {
        Mode::Power
    }

    fn entries(&self) -> Arc<Vec<Entry>> {
        self.entries.clone()
    }

    fn activate(&mut self, id: &str, _action: &str, _ctx: &Ctx) -> Outcome {
        let Some((verb, .., status)) = VERBS.iter().find(|(verb, ..)| *verb == id) else {
            return Outcome::Error(format!("no power action {id}"));
        };
        let (systemctl, verb) = (self.systemctl.clone(), *verb);
        // Waited for, so logind refusing (no swap to hibernate to) shows in the panel.
        Outcome::Wait {
            status: (*status).into(),
            work: Work::new(move || {
                let out = Command::new(&systemctl)
                    .arg(verb)
                    .output()
                    .map_err(|err| format!("{systemctl}: {err}"))?;
                if out.status.success() {
                    Ok(())
                } else {
                    Err(String::from_utf8_lossy(&out.stderr).trim().to_owned())
                }
            }),
        }
    }
}
