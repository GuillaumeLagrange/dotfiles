//! The workspace and window model, updated from niri's event deltas.

use std::collections::BTreeMap;

use crate::icons::Icons;
use crate::json::Json;
use crate::strip::View;

#[derive(Debug, Clone, Default)]
pub struct Window {
    pub id: u64,
    pub title: String,
    pub app_id: String,
    pub workspace_id: u64,
    pub urgent: bool,
    /// (column, tile) in the scrolling layout, 1-based. None for floating.
    pub scroll_pos: Option<(u32, u32)>,
    pub tile_w: f64,
    /// Position in the view; niri reports it for floating tiles only.
    pub view_x: Option<f64>,
    /// Icon file for `app_id`; empty when it cannot be resolved.
    pub icon: String,
}

impl Window {
    pub fn from_json(value: &Json, icons: &Icons) -> Option<Window> {
        let layout = value.get("layout");
        let pos = layout.get("pos_in_scrolling_layout");
        let view = layout.get("tile_pos_in_workspace_view");
        let app_id = value.get("app_id").str().unwrap_or_default().to_string();
        Some(Window {
            id: value.get("id").u64()?,
            title: value.get("title").str().unwrap_or_default().to_string(),
            icon: icons.path_for(&app_id),
            app_id,
            workspace_id: value.get("workspace_id").u64().unwrap_or(0),
            urgent: value.get("is_urgent").truthy(),
            scroll_pos: match (pos.at(0).u64(), pos.at(1).u64()) {
                (Some(col), Some(tile)) => Some((col as u32, tile as u32)),
                _ => None,
            },
            tile_w: layout.get("tile_size").at(0).num().unwrap_or(0.0),
            view_x: view.at(0).num(),
        })
    }
}

#[derive(Debug, Clone, Default)]
pub struct Workspace {
    pub id: u64,
    pub idx: u64,
    pub name: Option<String>,
    pub output: Option<String>,
    pub active: bool,
    pub focused: bool,
    pub urgent: bool,
    pub active_window: Option<u64>,
}

impl Workspace {
    pub fn from_json(value: &Json) -> Option<Workspace> {
        Some(Workspace {
            id: value.get("id").u64()?,
            idx: value.get("idx").u64().unwrap_or(0),
            name: value.get("name").str().map(str::to_string),
            output: value.get("output").str().map(str::to_string),
            active: value.get("is_active").truthy(),
            focused: value.get("is_focused").truthy(),
            urgent: value.get("is_urgent").truthy(),
            active_window: value.get("active_window_id").u64(),
        })
    }
}

#[derive(Default)]
pub struct State {
    pub outputs: BTreeMap<String, f64>,
    pub workspaces: BTreeMap<u64, Workspace>,
    pub windows: BTreeMap<u64, Window>,
    pub icons: Icons,
    /// Reconstructed scroll position per workspace, since niri reports none.
    pub views: BTreeMap<u64, View>,
}

impl State {
    /// Applies one event, returning false for events that cannot change the bar.
    pub fn apply(&mut self, event: &Json) -> bool {
        let Some((name, body)) = event.fields().first() else {
            return false;
        };
        match name.as_str() {
            "WorkspacesChanged" => {
                self.workspaces = body
                    .get("workspaces")
                    .items()
                    .iter()
                    .filter_map(Workspace::from_json)
                    .map(|ws| (ws.id, ws))
                    .collect();
            }
            "WorkspaceActivated" => {
                let Some(id) = body.get("id").u64() else {
                    return false;
                };
                let focused = body.get("focused").truthy();
                let output = self.workspaces.get(&id).and_then(|ws| ws.output.clone());
                for ws in self.workspaces.values_mut() {
                    // Activation is exclusive per output; focus is exclusive globally.
                    if ws.output == output {
                        ws.active = ws.id == id;
                    }
                    if focused {
                        ws.focused = ws.id == id;
                    }
                }
            }
            "WorkspaceUrgencyChanged" => {
                let Some(ws) = body
                    .get("id")
                    .u64()
                    .and_then(|id| self.workspaces.get_mut(&id))
                else {
                    return false;
                };
                ws.urgent = body.get("urgent").truthy();
            }
            "WorkspaceActiveWindowChanged" => {
                let Some(ws) = body
                    .get("workspace_id")
                    .u64()
                    .and_then(|id| self.workspaces.get_mut(&id))
                else {
                    return false;
                };
                ws.active_window = body.get("active_window_id").u64();
            }
            "WindowsChanged" => {
                self.windows = body
                    .get("windows")
                    .items()
                    .iter()
                    .filter_map(|w| Window::from_json(w, &self.icons))
                    .map(|w| (w.id, w))
                    .collect();
            }
            "WindowOpenedOrChanged" => {
                let Some(window) = Window::from_json(body.get("window"), &self.icons) else {
                    return false;
                };
                self.windows.insert(window.id, window);
            }
            "WindowClosed" => {
                let Some(id) = body.get("id").u64() else {
                    return false;
                };
                self.windows.remove(&id);
            }
            "WindowUrgencyChanged" => {
                let Some(window) = body
                    .get("id")
                    .u64()
                    .and_then(|id| self.windows.get_mut(&id))
                else {
                    return false;
                };
                window.urgent = body.get("urgent").truthy();
            }
            "WindowLayoutsChanged" => {
                for change in body.get("changes").items() {
                    let (Some(id), layout) = (change.at(0).u64(), change.at(1)) else {
                        continue;
                    };
                    let Some(window) = self.windows.get_mut(&id) else {
                        continue;
                    };
                    let pos = layout.get("pos_in_scrolling_layout");
                    window.scroll_pos = match (pos.at(0).u64(), pos.at(1).u64()) {
                        (Some(col), Some(tile)) => Some((col as u32, tile as u32)),
                        _ => None,
                    };
                    window.tile_w = layout.get("tile_size").at(0).num().unwrap_or(window.tile_w);
                    window.view_x = layout.get("tile_pos_in_workspace_view").at(0).num();
                }
            }
            // WindowFocusChanged is ignored on purpose: the active window per
            // workspace already arrives with WorkspaceActiveWindowChanged.
            _ => return false,
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HALF: f64 = 957.0;

    use crate::json::Parser;
    use crate::strip::columns_of;

    #[test]
    fn columns_are_ordered_and_floating_windows_excluded() {
        let mut state = State::default();
        for (id, pos) in [
            (3u64, Some((2, 1))),
            (1, Some((1, 1))),
            (2, Some((1, 2))),
            (4, None),
        ] {
            state.windows.insert(
                id,
                Window {
                    id,
                    workspace_id: 1,
                    scroll_pos: pos,
                    tile_w: HALF,
                    ..Window::default()
                },
            );
        }
        state.windows.insert(
            9,
            Window {
                id: 9,
                workspace_id: 2,
                scroll_pos: Some((1, 1)),
                ..Window::default()
            },
        );
        let columns = columns_of(&state, 1);
        assert_eq!(columns.iter().map(|c| c.idx).collect::<Vec<_>>(), [1, 2]);
        assert_eq!(columns[0].tiles, [1, 2]);
        assert_eq!(columns[1].tiles, [3]);
    }

    #[test]
    fn workspace_activation_is_exclusive_per_output() {
        let mut state = State::default();
        for (id, output, active) in [
            (1u64, "eDP-1", true),
            (2, "eDP-1", false),
            (3, "HDMI-1", true),
        ] {
            state.workspaces.insert(
                id,
                Workspace {
                    id,
                    output: Some(output.into()),
                    active,
                    focused: active && id == 1,
                    ..Workspace::default()
                },
            );
        }
        let event = Parser::parse(r#"{"WorkspaceActivated":{"id":2,"focused":true}}"#).unwrap();
        assert!(state.apply(&event));
        let active: Vec<u64> = state
            .workspaces
            .values()
            .filter(|w| w.active)
            .map(|w| w.id)
            .collect();
        assert_eq!(
            active,
            [2, 3],
            "the other output keeps its own active workspace"
        );
        let focused: Vec<u64> = state
            .workspaces
            .values()
            .filter(|w| w.focused)
            .map(|w| w.id)
            .collect();
        assert_eq!(focused, [2], "focus is exclusive across outputs");
    }

    #[test]
    fn layout_events_update_column_geometry() {
        let mut state = State::default();
        state.windows.insert(
            7,
            Window {
                id: 7,
                workspace_id: 1,
                scroll_pos: Some((1, 1)),
                tile_w: HALF,
                ..Window::default()
            },
        );
        let event = Parser::parse(
            r#"{"WindowLayoutsChanged":{"changes":[[7,{"pos_in_scrolling_layout":[3,2],
               "tile_size":[640.0,900.0],"tile_pos_in_workspace_view":null}]]}}"#,
        )
        .unwrap();
        assert!(state.apply(&event));
        let window = &state.windows[&7];
        assert_eq!(window.scroll_pos, Some((3, 2)));
        assert_eq!(window.tile_w, 640.0);
        assert_eq!(window.view_x, None);
    }

    #[test]
    fn irrelevant_events_do_not_trigger_a_repaint() {
        let mut state = State::default();
        let event = Parser::parse(r#"{"KeyboardLayoutSwitched":{"idx":1}}"#).unwrap();
        assert!(!state.apply(&event));
    }
}
