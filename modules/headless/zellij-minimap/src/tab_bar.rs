//! What zellij's tab-bar calls, patched in by `tab-bar.patch`.

use zellij_tile::prelude::*;

use super::{render, Palette, Pane, Rect, Rgb, Tab};

/// Columns taken at the right end of the tab bar.
pub const WIDTH: usize = 6;

#[derive(Debug, Default)]
pub struct Minimap {
    plugin_id: u32,
    panes: PaneManifest,
}

impl Minimap {
    /// Loaded from a file, the tab bar no longer gets the permissions built-in plugins have.
    pub fn load(&mut self) {
        self.plugin_id = get_plugin_ids().plugin_id;
        request_permission(&[
            PermissionType::ReadApplicationState,
            PermissionType::ChangeApplicationState,
        ]);
        subscribe(&[EventType::PaneUpdate]);
    }

    pub fn update(&mut self, panes: PaneManifest) -> bool {
        let changed = self.panes != panes;
        self.panes = panes;
        changed
    }

    pub fn render(&self, tabs: &[TabInfo], colors: &Styling) -> String {
        match self.tab(tabs) {
            // Image ids are per pane in zellij, so any non-zero one does.
            Some(tab) => render(&tab, &palette(colors), 1, WIDTH, 1),
            None => String::new(),
        }
    }

    /// The tab this instance is in, rather than the active one: each tab has its own bar.
    fn tab(&self, tabs: &[TabInfo]) -> Option<Tab> {
        let ours = |p: &PaneInfo| p.is_plugin && p.id == self.plugin_id;
        let (&position, panes) =
            (self.panes.panes.iter()).find(|(_, panes)| panes.iter().any(ours))?;
        let info = tabs.iter().find(|t| t.position == position)?;
        let shown = |p: &&PaneInfo| p.is_selectable && !p.is_suppressed;
        let pane = |p: &PaneInfo| Pane {
            rect: Rect {
                x: p.pane_x,
                y: p.pane_y,
                w: p.pane_columns,
                h: p.pane_rows,
            },
            focused: p.is_focused,
            fullscreen: !p.is_floating
                && (p.is_fullscreen || (info.is_fullscreen_active && p.is_focused)),
        };
        let (floating, tiled): (Vec<_>, Vec<_>) =
            panes.iter().filter(shown).partition(|p| p.is_floating);
        Some(Tab {
            tiled: tiled.into_iter().map(pane).collect(),
            floating: floating.into_iter().map(pane).collect(),
            floating_visible: info.are_floating_panes_visible,
        })
    }
}

/// Images need RGB; a theme in 256 colours falls back to the defaults.
fn color(c: PaletteColor, fallback: Rgb) -> Rgb {
    match c {
        PaletteColor::Rgb((r, g, b)) => [r, g, b],
        PaletteColor::EightBit(_) => fallback,
    }
}

/// The focused pane takes the colour of the selected tab, the others that of the
/// unselected ones.
fn palette(s: &Styling) -> Palette {
    let d = Palette::default();
    Palette {
        focused: color(s.ribbon_selected.background, d.focused),
        tiled: color(s.ribbon_unselected.background, d.tiled),
        floating: color(s.frame_selected.emphasis_0, d.floating),
    }
}
