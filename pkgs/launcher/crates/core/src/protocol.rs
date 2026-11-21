//! The wire: one JSON object per line each way (see AGENTS.md).

use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::source::{Action, Icon, Mode, Preview, Status};

#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Request {
    Open {
        mode: Mode,
    },
    Query {
        text: String,
        #[serde(default)]
        seq: u64,
    },
    Activate {
        id: String,
        #[serde(default)]
        action: Option<String>,
    },
    Preview {
        id: String,
    },
    Close,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ModeInfo {
    pub mode: Mode,
    pub short: &'static str,
    pub title: &'static str,
    pub glyph: &'static str,
}

impl From<Mode> for ModeInfo {
    fn from(mode: Mode) -> ModeInfo {
        ModeInfo {
            mode,
            short: mode.short(),
            title: mode.title(),
            glyph: mode.glyph(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Item {
    pub id: String,
    pub title: String,
    pub subtitle: String,
    pub hl: Vec<[u32; 2]>,
    pub shl: Vec<[u32; 2]>,
    pub icon: Icon,
    pub accessory: String,
    pub color: Option<String>,
    pub section: String,
    pub actions: Arc<[Action]>,
    pub preview: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Event {
    Hello {
        modes: Vec<ModeInfo>,
    },
    Results {
        seq: u64,
        mode: Mode,
        query: String,
        total: usize,
        status: Option<Status>,
        items: Vec<Item>,
    },
    Preview {
        id: String,
        preview: Option<Preview>,
    },
    /// An activation runs on: the panel waits, saying `text`, for its `done` or `error`.
    Working {
        text: String,
    },
    Done {
        close: bool,
    },
    Switch {
        mode: Mode,
    },
    Error {
        message: String,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requests_parse_from_the_panels_json() {
        let parse = |s: &str| serde_json::from_str::<Request>(s).unwrap();
        assert_eq!(
            parse(r#"{"op":"open","mode":"clipboard"}"#),
            Request::Open {
                mode: Mode::Clipboard
            }
        );
        assert_eq!(
            parse(r#"{"op":"query","text":"fi","seq":3}"#),
            Request::Query {
                text: "fi".into(),
                seq: 3
            }
        );
        assert_eq!(
            parse(r#"{"op":"activate","id":"x"}"#),
            Request::Activate {
                id: "x".into(),
                action: None
            }
        );
        assert_eq!(parse(r#"{"op":"close"}"#), Request::Close);
    }

    #[test]
    fn events_serialise_to_the_documented_shape() {
        let item = Item {
            id: "firefox.desktop".into(),
            title: "Firefox".into(),
            subtitle: String::new(),
            hl: vec![[0, 2]],
            shl: vec![],
            icon: Icon::Name("firefox".into()),
            accessory: String::new(),
            color: None,
            section: String::new(),
            actions: Arc::from(vec![Action::new("open", "Open", Some("Return"))]),
            preview: false,
        };
        let event = Event::Results {
            seq: 1,
            mode: Mode::Apps,
            query: "fi".into(),
            total: 1,
            status: Some(Status::loading("Loading")),
            items: vec![item],
        };
        let json: serde_json::Value = serde_json::to_value(&event).unwrap();
        assert_eq!(
            json,
            serde_json::json!({
                "type": "results", "seq": 1, "mode": "apps", "query": "fi", "total": 1,
                "status": {"kind": "loading", "text": "Loading"},
                "items": [{
                    "id": "firefox.desktop", "title": "Firefox", "subtitle": "", "hl": [[0, 2]], "shl": [],
                    "icon": {"kind": "name", "value": "firefox"}, "accessory": "", "color": null,
                    "section": "", "actions": [{"id": "open", "label": "Open", "key": "Return"}],
                    "preview": false
                }]
            })
        );
        let preview = Event::Preview {
            id: "c:1".into(),
            preview: Some(Preview::Fields {
                fields: vec![("Username".into(), "bob".into())],
            }),
        };
        assert_eq!(
            serde_json::to_value(&preview).unwrap(),
            serde_json::json!({"type":"preview","id":"c:1","preview":{"kind":"fields","fields":[["Username","bob"]]}})
        );
    }
}
