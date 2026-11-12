//! Serialisation of one bar snapshot: the line the bar's `SplitParser` reads.

use std::collections::BTreeMap;

use crate::json::push_str_escaped;
use crate::model::{State, Workspace};
use crate::strip::{build_strip, columns_of, Strip, View, FALLBACK_VIEW_W};

pub fn snapshot(state: &mut State) -> String {
    // Taken out so the view of each workspace can be advanced while the rest of
    // the state is read; dropped for workspaces niri no longer has.
    let mut views = std::mem::take(&mut state.views);
    views.retain(|id, _| state.workspaces.contains_key(id));
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
        out.push_str("{\"name\":");
        push_str_escaped(&mut out, ws.name.as_deref().unwrap_or(""));
        out.push_str(",\"output\":");
        push_str_escaped(&mut out, ws.output.as_deref().unwrap_or(""));
        out.push_str(&format!(
            ",\"is_active\":{},\"is_focused\":{},\"is_urgent\":{},\"strip\":",
            ws.active, ws.focused, ws.urgent
        ));
        push_strip(&mut out, &strip_of(state, ws, &mut views));
        out.push('}');
    }
    out.push_str("],\"titles\":{");

    let mut first = true;
    for ws in state.workspaces.values().filter(|ws| ws.active) {
        let Some(output) = ws.output.as_deref() else {
            continue;
        };
        if !first {
            out.push(',');
        }
        first = false;
        let title = ws
            .active_window
            .and_then(|id| state.windows.get(&id))
            .map_or("", |w| w.title.as_str());
        push_str_escaped(&mut out, output);
        out.push(':');
        push_str_escaped(&mut out, title);
    }
    out.push_str("},\"focused_output\":");
    // Focus is exclusive across outputs, and unnamed workspaces hold it too, so
    // this cannot be read off the named workspaces the bar draws.
    let focused = state
        .workspaces
        .values()
        .find(|ws| ws.focused)
        .and_then(|ws| ws.output.as_deref())
        .unwrap_or("");
    push_str_escaped(&mut out, focused);
    out.push('}');
    state.views = views;
    out
}

fn strip_of(state: &State, ws: &Workspace, views: &mut BTreeMap<u64, View>) -> Strip {
    let view_w = ws
        .output
        .as_deref()
        .and_then(|output| state.outputs.get(output))
        .copied()
        .unwrap_or(FALLBACK_VIEW_W);
    let floats: Vec<(f64, f64)> = state
        .windows
        .values()
        .filter(|w| w.workspace_id == ws.id && w.scroll_pos.is_none())
        .filter_map(|w| w.view_x.map(|x| (x, w.tile_w)))
        .collect();
    build_strip(
        &columns_of(state, ws.id),
        &floats,
        view_w,
        ws.active_window,
        views.entry(ws.id).or_default(),
    )
}

pub fn push_strip(out: &mut String, strip: &Strip) {
    out.push_str(&format!(
        "{{\"count\":{},\"w\":{},\"frame\":{{\"x\":{},\"w\":{}}},\"thumb\":",
        strip.count, strip.w, strip.frame_x, strip.frame_w
    ));
    match strip.thumb {
        Some((x, w)) => out.push_str(&format!("{{\"x\":{x},\"w\":{w}}}")),
        None => out.push_str("null"),
    }
    out.push_str(",\"columns\":[");
    for (i, block) in strip.columns.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push_str(&format!(
            "{{\"idx\":{},\"window\":{},\"pad\":{},\"w\":{},\"state\":\"{}\",\"tiles\":[",
            block.idx, block.window, block.pad, block.w, block.state
        ));
        for (j, active) in block.tiles.iter().enumerate() {
            if j > 0 {
                out.push(',');
            }
            out.push_str(&format!("{{\"active\":{active}}}"));
        }
        out.push_str(&format!(
            "],\"dim\":{{\"left\":{},\"right\":{}}},\"cut\":{{\"left\":{},\"right\":{}}},\"tooltip\":",
            block.dim_left, block.dim_right, block.cut_left, block.cut_right
        ));
        push_str_escaped(out, &block.tooltip);
        out.push_str(",\"app_id\":");
        push_str_escaped(out, &block.app_id);
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
