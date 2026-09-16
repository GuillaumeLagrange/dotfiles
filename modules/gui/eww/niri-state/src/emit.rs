//! Serialisation of one bar snapshot: the line eww's `deflisten` reads.

use crate::json::push_str_escaped;
use crate::model::{State, Workspace};
use crate::strip::{build_strip, columns_of, Strip, FALLBACK_VIEW_W};

pub fn snapshot(state: &State) -> String {
    let mut out = String::with_capacity(1024);
    out.push_str("{\"workspaces\":[");
    let mut named: Vec<&Workspace> = state
        .workspaces
        .values()
        .filter(|ws| ws.name.is_some())
        .collect();
    named.sort_by(|a, b| (&a.output, a.idx).cmp(&(&b.output, b.idx)));
    for (i, ws) in named.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        let empty =
            ws.active_window.is_none() && !state.windows.values().any(|w| w.workspace_id == ws.id);
        out.push_str(&format!("{{\"id\":{},\"idx\":{},\"name\":", ws.id, ws.idx));
        push_str_escaped(&mut out, ws.name.as_deref().unwrap_or(""));
        out.push_str(",\"output\":");
        push_str_escaped(&mut out, ws.output.as_deref().unwrap_or(""));
        out.push_str(&format!(
            ",\"is_active\":{},\"is_focused\":{},\"is_urgent\":{},\"is_empty\":{}}}",
            ws.active, ws.focused, ws.urgent, empty
        ));
    }
    out.push_str("],\"by_output\":{");

    let mut first = true;
    for ws in state.workspaces.values().filter(|ws| ws.active) {
        let Some(output) = ws.output.as_deref() else {
            continue;
        };
        if !first {
            out.push(',');
        }
        first = false;

        let view_w = state
            .outputs
            .get(output)
            .copied()
            .unwrap_or(FALLBACK_VIEW_W);
        let columns = columns_of(state, ws.id);
        let floats: Vec<(f64, f64)> = state
            .windows
            .values()
            .filter(|w| w.workspace_id == ws.id && w.scroll_pos.is_none())
            .filter_map(|w| w.view_x.map(|x| (x, w.tile_w)))
            .collect();
        let strip = build_strip(&columns, &floats, view_w, ws.active_window);
        let title = ws
            .active_window
            .and_then(|id| state.windows.get(&id))
            .map_or("", |w| w.title.as_str());

        push_str_escaped(&mut out, output);
        out.push_str(":{\"title\":");
        push_str_escaped(&mut out, title);
        out.push_str(",\"strip\":");
        push_strip(&mut out, &strip);
        out.push('}');
    }
    out.push_str("}}");
    out
}

pub fn push_strip(out: &mut String, strip: &Strip) {
    out.push_str(&format!(
        "{{\"count\":{},\"w\":{},\"frame\":{{\"x\":{},\"w\":{}}},\"crop\":{{\"left\":{},\"right\":{}}},\"columns\":[",
        strip.count, strip.w, strip.frame_x, strip.frame_w, strip.crop_left, strip.crop_right
    ));
    for (i, block) in strip.columns.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push_str(&format!(
            "{{\"idx\":{},\"pad\":{},\"w\":{},\"state\":\"{}\",\"tiles\":[",
            block.idx, block.pad, block.w, block.state
        ));
        for (j, active) in block.tiles.iter().enumerate() {
            if j > 0 {
                out.push(',');
            }
            out.push_str(&format!("{{\"active\":{active}}}"));
        }
        out.push_str(&format!(
            "],\"dim\":{{\"left\":{},\"right\":{}}},\"tooltip\":",
            block.dim_left, block.dim_right
        ));
        push_str_escaped(out, &block.tooltip);
        out.push_str(&format!(",\"icon_px\":{},\"icon\":", block.icon_px));
        push_str_escaped(out, &block.icon);
        out.push('}');
    }
    out.push_str("],\"floating\":[");
    for (i, float) in strip.floating.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push_str(&format!("{{\"pad\":{},\"w\":{}}}", float.pad, float.w));
    }
    out.push_str("]}");
}
