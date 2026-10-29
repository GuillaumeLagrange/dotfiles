//! The map of a tab's panes, drawn as an image sent with the kitty graphics protocol,
//! which zellij passes on to terminals that support it.
//! Everything but `tab_bar` is free of zellij, so it builds and tests natively.
//! zellij's tab-bar compiles this file as its `minimap` module, see `_package.nix`.

use std::fmt::Write;

#[cfg(target_family = "wasm")]
pub mod tab_bar;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rect {
    pub x: usize,
    pub y: usize,
    pub w: usize,
    pub h: usize,
}

impl Rect {
    fn right(&self) -> usize {
        self.x + self.w
    }

    fn bottom(&self) -> usize {
        self.y + self.h
    }

    fn contains(&self, x: usize, y: usize) -> bool {
        (self.x..self.right()).contains(&x) && (self.y..self.bottom()).contains(&y)
    }

    fn union(&self, other: &Rect) -> Rect {
        let x = self.x.min(other.x);
        let y = self.y.min(other.y);
        Rect {
            x,
            y,
            w: self.right().max(other.right()) - x,
            h: self.bottom().max(other.bottom()) - y,
        }
    }
}

#[derive(Clone, Debug)]
pub struct Pane {
    pub rect: Rect,
    pub focused: bool,
    pub fullscreen: bool,
}

#[derive(Clone, Debug, Default)]
pub struct Tab {
    pub tiled: Vec<Pane>,
    pub floating: Vec<Pane>,
    pub floating_visible: bool,
}

pub type Rgb = [u8; 3];

#[derive(Clone, Debug)]
pub struct Palette {
    pub focused: Rgb,
    pub tiled: Rgb,
    pub floating: Rgb,
}

impl Default for Palette {
    fn default() -> Self {
        Palette {
            focused: [0xd3, 0x86, 0x9b],
            tiled: [0x50, 0x49, 0x45],
            floating: [0xe7, 0x8a, 0x4e],
        }
    }
}

/// While a pane is fullscreen zellij reports it at the size of the whole tab and the
/// others where they were. Tiled panes cover the tab, so its place is what they leave.
fn restore_fullscreen(tiled: &mut [Pane]) {
    let Some(full) = tiled.iter().position(|p| p.fullscreen) else {
        return;
    };
    let bounds = tiled[full].rect;
    let others: Vec<Rect> = (tiled.iter().enumerate())
        .filter(|&(i, _)| i != full)
        .map(|(_, p)| p.rect)
        .collect();
    let mut hole: Option<Rect> = None;
    for y in bounds.y..bounds.bottom() {
        for x in bounds.x..bounds.right() {
            if !others.iter().any(|r| r.contains(x, y)) {
                let cell = Rect { x, y, w: 1, h: 1 };
                hole = Some(hole.map_or(cell, |h| h.union(&cell)));
            }
        }
    }
    if let Some(hole) = hole {
        tiled[full].rect = hole;
    }
}

/// Image pixels per terminal cell; the terminal scales the image to the cells it covers.
const CELL_W: usize = 12;
const CELL_H: usize = 24;

/// RGBA, transparent where no pane is, so that the bar shows through.
struct Canvas {
    w: usize,
    h: usize,
    rgba: Vec<u8>,
}

impl Canvas {
    fn fill(&mut self, x0: usize, y0: usize, x1: usize, y1: usize, color: Option<Rgb>) {
        let px = match color {
            Some([r, g, b]) => [r, g, b, 255],
            None => [0; 4],
        };
        for y in y0..y1.min(self.h) {
            for x in x0..x1.min(self.w) {
                self.rgba[(y * self.w + x) * 4..][..4].copy_from_slice(&px);
            }
        }
    }

    /// Scales `rect` from `bounds` to the canvas, less a pixel on the right and bottom,
    /// so that neighbours are apart. A pane always keeps at least one pixel.
    fn place(&self, bounds: &Rect, rect: &Rect) -> (usize, usize, usize, usize) {
        let scale = |v: usize, from: usize, len: usize, to: usize| {
            (v.saturating_sub(from).min(len) * to + len / 2) / len
        };
        let x0 = scale(rect.x, bounds.x, bounds.w, self.w);
        let y0 = scale(rect.y, bounds.y, bounds.h, self.h);
        let x1 = scale(rect.right(), bounds.x, bounds.w, self.w).saturating_sub(1);
        let y1 = scale(rect.bottom(), bounds.y, bounds.h, self.h).saturating_sub(1);
        (x0, y0, x1.max(x0 + 1), y1.max(y0 + 1))
    }

    fn pane(&mut self, bounds: &Rect, rect: &Rect, color: Rgb) {
        let (x0, y0, x1, y1) = self.place(bounds, rect);
        self.fill(x0, y0, x1, y1, Some(color));
    }

    /// A visible floating pane: filled, with a clear ring to set it apart from the tiles.
    fn floating(&mut self, bounds: &Rect, rect: &Rect, color: Rgb) {
        let (x0, y0, x1, y1) = self.place(bounds, rect);
        self.fill(
            x0.saturating_sub(1),
            y0.saturating_sub(1),
            x1 + 1,
            y1 + 1,
            None,
        );
        self.fill(x0, y0, x1, y1, Some(color));
    }

    /// A hidden floating pane: its outline only.
    fn outline(&mut self, bounds: &Rect, rect: &Rect, color: Rgb) {
        let (x0, y0, x1, y1) = self.place(bounds, rect);
        let c = Some(color);
        self.fill(x0, y0, x1, y0 + 1, c);
        self.fill(x0, y1 - 1, x1, y1, c);
        self.fill(x0, y0, x0 + 1, y1, c);
        self.fill(x1 - 1, y0, x1, y1, c);
    }
}

fn canvas(tab: &Tab, palette: &Palette, w: usize, h: usize) -> Option<Canvas> {
    let mut tiled = tab.tiled.clone();
    restore_fullscreen(&mut tiled);
    let bounds = tiled.iter().map(|p| p.rect).reduce(|a, b| a.union(&b))?;
    if w == 0 || h == 0 || bounds.w == 0 || bounds.h == 0 {
        return None;
    }
    let mut canvas = Canvas {
        w,
        h,
        rgba: vec![0; w * h * 4],
    };
    let floating_focused = tab.floating_visible && tab.floating.iter().any(|p| p.focused);
    for pane in &tiled {
        let color = match pane.focused && !floating_focused {
            true => palette.focused,
            false => palette.tiled,
        };
        canvas.pane(&bounds, &pane.rect, color);
    }
    // Focused last, on top of the others.
    let mut floating: Vec<&Pane> = tab.floating.iter().collect();
    floating.sort_by_key(|p| p.focused);
    for pane in floating {
        match tab.floating_visible {
            true if pane.focused => canvas.floating(&bounds, &pane.rect, palette.focused),
            true => canvas.floating(&bounds, &pane.rect, palette.floating),
            false => canvas.outline(&bounds, &pane.rect, palette.floating),
        }
    }
    Some(canvas)
}

fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = chunk
            .iter()
            .enumerate()
            .fold(0u32, |n, (i, &b)| n | (b as u32) << (16 - 8 * i));
        for i in 0..4 {
            out.push(match i <= chunk.len() {
                true => ALPHABET[(n >> (18 - 6 * i) & 63) as usize] as char,
                false => '=',
            });
        }
    }
    out
}

/// The escape sequence that draws the map over `cols` × `rows` cells at the cursor,
/// replacing the image `id` drew before.
pub fn render(tab: &Tab, palette: &Palette, rows: usize, cols: usize, id: u32) -> String {
    let Some(canvas) = canvas(tab, palette, cols * CELL_W, rows * CELL_H) else {
        return String::new();
    };
    let data = base64(&canvas.rgba);
    // Transmissions over 4096 bytes are split into chunks, all but the last with m=1.
    let chunks: Vec<&str> = (0..data.len())
        .step_by(4096)
        .map(|i| &data[i..(i + 4096).min(data.len())])
        .collect();
    let mut out = String::new();
    for (i, chunk) in chunks.iter().enumerate() {
        let more = (i + 1 < chunks.len()) as u8;
        match i {
            0 => write!(
                out,
                "\x1b_Ga=T,f=32,s={},v={},c={cols},r={rows},i={id},C=1,q=2,m={more};{chunk}\x1b\\",
                canvas.w, canvas.h
            ),
            _ => write!(out, "\x1b_Gm={more};{chunk}\x1b\\"),
        }
        .unwrap();
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pane(x: usize, y: usize, w: usize, h: usize) -> Pane {
        Pane {
            rect: Rect { x, y, w, h },
            focused: false,
            fullscreen: false,
        }
    }

    /// Wide pane on the left, three stacked on the right, as in the `main` swap layout.
    fn main_layout() -> Tab {
        Tab {
            tiled: vec![
                pane(0, 1, 98, 38),
                pane(98, 1, 42, 13),
                pane(98, 14, 42, 13),
                pane(98, 27, 42, 12),
            ],
            ..Tab::default()
        }
    }

    fn pixels(tab: &Tab) -> Vec<u8> {
        canvas(tab, &Palette::default(), 96, 24).unwrap().rgba
    }

    #[test]
    fn fullscreen_pane_keeps_its_place() {
        let mut normal = main_layout();
        normal.tiled[2].focused = true;
        let mut full = normal.clone();
        full.tiled[2].fullscreen = true;
        full.tiled[2].rect = Rect {
            x: 0,
            y: 1,
            w: 140,
            h: 38,
        };
        assert_eq!(pixels(&full), pixels(&normal));
    }

    #[test]
    fn stacked_panes_are_apart() {
        let c = canvas(&main_layout(), &Palette::default(), 96, 24).unwrap();
        let alpha = |y: usize| c.rgba[(y * c.w + c.w - 2) * 4 + 3];
        let gaps = (1..c.h)
            .filter(|&y| alpha(y) == 0 && alpha(y - 1) != 0)
            .count();
        assert_eq!(gaps, 3);
    }

    #[test]
    fn base64_pads() {
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
        assert_eq!(base64(b"foob"), "Zm9vYg==");
    }
}
