//! Geometry of the strip: the active workspace's scrolling layout scaled down
//! to pixels for the bar to draw.

use std::collections::BTreeMap;

use crate::model::{State, Window};

/// One screenful of workspace, in pixels. The frame is therefore a constant-size
/// reference and the strip grows behind it as columns are added.
pub const SCREEN_PX: i64 = 32;
/// Past this the strip is cropped around the frame rather than rescaled: beyond
/// ~2.5 screenfuls the blocks stop being distinguishable anyway.
pub const MAX_PX: i64 = 80;
/// Gap between distinct columns, carved out of the left one. This is the only
/// break in the strip, so it must dominate the shading seam inside a column that
/// straddles the frame edge.
pub const SEP_PX: i64 = 2;
pub const MIN_COL_PX: i64 = 3;
/// Tiles stacked in a column; past three the slices are thinner than a pixel of
/// visible colour.
pub const MAX_TILES: usize = 3;
/// Icons are square and drawn inside the block, so a narrow column gets a smaller
/// one. `ICON_MAX_PX` is the band's height in eww.scss; below `ICON_MIN_PX` the
/// icon is dropped rather than drawn as a smudge.
pub const ICON_MAX_PX: i64 = 16;
pub const ICON_MIN_PX: i64 = 8;
pub const GAP_LOGICAL: f64 = 2.0;
pub const FALLBACK_VIEW_W: f64 = 1920.0;

#[derive(Debug, Clone)]
pub struct Column {
    pub idx: u32,
    pub width: f64,
    /// Window ids, top to bottom.
    pub tiles: Vec<u64>,
    pub urgent: bool,
    pub apps: String,
    /// Icon file of the app owning the column; empty when it cannot be resolved.
    pub icon: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Block {
    pub idx: u32,
    pub x: i64,
    pub w: i64,
    pub pad: i64,
    pub state: &'static str,
    pub tiles: Vec<bool>,
    /// Pixels of this block that fall outside the view, from each end. The widget
    /// shades that much of the block, keeping it a single shape: the only break in
    /// the strip is the `SEP_PX` gap between columns.
    pub dim_left: i64,
    pub dim_right: i64,
    pub tooltip: String,
    /// Icon to draw on the block; empty when it is too narrow to carry one.
    pub icon: String,
    /// Side of the square the icon is drawn at.
    pub icon_px: i64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Float {
    pub x: i64,
    pub w: i64,
    pub pad: i64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Strip {
    pub count: usize,
    pub w: i64,
    pub frame_x: i64,
    pub frame_w: i64,
    pub crop_left: bool,
    pub crop_right: bool,
    pub columns: Vec<Block>,
    pub floating: Vec<Float>,
}

/// Reconstructed scroll position of a workspace's view, carried between
/// snapshots because niri never reports it.
#[derive(Debug, Clone, Default)]
pub struct View {
    /// Window identifying the column `offset` is measured from. Anchoring to a
    /// column, the form niri keeps internally, holds the view still when
    /// columns elsewhere open, close, or resize.
    anchor: Option<u64>,
    /// Distance from the anchor column's left edge to the view's.
    offset: f64,
    /// Fallback for when the anchor's column is gone, e.g. it was just closed.
    start: f64,
}

impl View {
    /// Moves the view onto the focused column, returning where it now starts.
    fn follow(
        &mut self,
        columns: &[Column],
        positions: &[f64],
        focused: usize,
        view_w: f64,
        total: f64,
    ) -> f64 {
        let prev = self
            .anchor
            .and_then(|id| columns.iter().position(|c| c.tiles.contains(&id)))
            .map_or(self.start, |i| positions[i] + self.offset);
        let (x, w) = (positions[focused], columns[focused].width);
        let start = view_start(prev, x, w, view_w, total);
        *self = View {
            anchor: columns[focused].tiles.first().copied(),
            offset: start - x,
            start,
        };
        start
    }
}

/// Where niri's view starts, moved the way niri moves it: a focused column
/// already on screen leaves the view alone, one off screen scrolls it by the
/// least that brings the column fully in. The view never runs past either end
/// of the workspace.
pub fn view_start(prev: f64, focused_x: f64, focused_w: f64, view_w: f64, total: f64) -> f64 {
    let fit = |start: f64| start.clamp(0.0, (total - view_w).max(0.0));
    // Nothing to fit: niri aligns its left edge and lets the rest hang off.
    if focused_w >= view_w {
        return fit(focused_x);
    }
    let prev = fit(prev);
    if prev <= focused_x && focused_x + focused_w <= prev + view_w {
        prev
    } else if focused_x < prev {
        fit(focused_x)
    } else {
        fit(focused_x + focused_w - view_w)
    }
}

/// How many pixels of a block lie left of the view, and how many lie right of it.
pub fn outside_frame(x: i64, w: i64, frame_start: i64, frame_end: i64) -> (i64, i64) {
    let left = (frame_start - x).clamp(0, w);
    let right = (x + w - frame_end).clamp(0, w - left);
    (left, right)
}

pub fn build_strip(
    columns: &[Column],
    floats: &[(f64, f64)],
    view_w: f64,
    active: Option<u64>,
    view: &mut View,
) -> Strip {
    let count = columns.iter().map(|c| c.tiles.len()).sum::<usize>() + floats.len();
    let view_w = if view_w > 0.0 {
        view_w
    } else {
        FALLBACK_VIEW_W
    };

    let mut positions = Vec::with_capacity(columns.len());
    let mut cursor = 0.0;
    for column in columns {
        positions.push(cursor);
        cursor += column.width + GAP_LOGICAL;
    }
    let total = (cursor - GAP_LOGICAL).max(0.0);

    let focused = columns
        .iter()
        .position(|c| active.is_some_and(|id| c.tiles.contains(&id)))
        .or(if columns.is_empty() { None } else { Some(0) });
    let start = focused.map_or(0.0, |i| view.follow(columns, &positions, i, view_w, total));

    let scale = SCREEN_PX as f64 / view_w;
    // Strictly proportional. niri's gaps are ~0.05px at this scale; drawing them
    // at one pixel each would make a screenful of columns wider than the frame and
    // push the focused column outside it, so separation is carved out of the
    // blocks below instead.
    let to_px = |logical_x: f64| -> i64 { (logical_x * scale).round() as i64 };

    let mut blocks: Vec<Block> = columns
        .iter()
        .enumerate()
        .map(|(i, column)| Block {
            idx: column.idx,
            x: to_px(positions[i]),
            w: ((column.width * scale).round() as i64).max(MIN_COL_PX),
            pad: 0,
            state: if column.urgent {
                "urgent"
            } else if focused == Some(i) {
                "focused"
            } else {
                "normal"
            },
            // niri reports the active window per workspace, not per column, so a
            // column that does not hold it has no tile to single out.
            tiles: {
                let holds_active = active.is_some_and(|id| column.tiles.contains(&id));
                column
                    .tiles
                    .iter()
                    .take(MAX_TILES)
                    .map(|id| !holds_active || active == Some(*id))
                    .collect()
            },
            dim_left: 0,
            dim_right: 0,
            tooltip: column.apps.clone(),
            icon: column.icon.clone(),
            icon_px: 0,
        })
        .collect();

    // Touching blocks give up pixels so neighbours stay distinct. Taken from the
    // block, never added after it, so the strip only ever shrinks.
    for i in 0..blocks.len().saturating_sub(1) {
        let touching = blocks[i].x + blocks[i].w >= blocks[i + 1].x;
        if touching && blocks[i].w > MIN_COL_PX {
            blocks[i].w -= SEP_PX;
        }
    }

    // After the carve, so the size is chosen against the drawn width. The icon
    // stays inside its block, which is what keeps it from spilling over a
    // neighbour: the widget draws it as an overlay and GTK does not clip those.
    for block in &mut blocks {
        block.icon_px = ICON_MAX_PX.min(block.w - 2);
        if block.icon_px < ICON_MIN_PX {
            block.icon.clear();
        }
    }

    let mut frame_x = to_px(start);
    let mut strip_w = blocks.last().map_or(0, |b| b.x + b.w).max(SCREEN_PX);
    let mut drawn_floats: Vec<Float> = floats
        .iter()
        .map(|&(x, w)| Float {
            x: frame_x + (x * scale).round() as i64,
            w: ((w * scale).round() as i64).max(MIN_COL_PX),
            pad: 0,
        })
        .collect();

    // Crop around the frame, clipping whatever straddles the cut.
    let mut crop_left = false;
    let mut crop_right = false;
    let mut offset = 0;
    if strip_w > MAX_PX {
        let centred = frame_x as f64 + SCREEN_PX as f64 / 2.0 - MAX_PX as f64 / 2.0;
        offset = centred.round().clamp(0.0, (strip_w - MAX_PX) as f64) as i64;
        crop_left = offset > 0;
        crop_right = offset + MAX_PX < strip_w;
        strip_w = MAX_PX;
    }
    frame_x -= offset;

    let clip = |x: i64, w: i64| -> Option<(i64, i64)> {
        let (lo, hi) = ((x - offset).max(0), (x - offset + w).min(strip_w));
        (hi > lo).then_some((lo, hi - lo))
    };

    let mut cursor = 0;
    blocks.retain_mut(|block| {
        let Some((x, w)) = clip(block.x, block.w) else {
            return false;
        };
        (block.x, block.w, block.pad) = (x, w, x - cursor);
        cursor = x + w;
        // The frame's position is final only after cropping.
        (block.dim_left, block.dim_right) = outside_frame(x, w, frame_x, frame_x + SCREEN_PX);
        true
    });

    let mut cursor = 0;
    drawn_floats.retain_mut(|float| {
        let Some((x, w)) = clip(float.x, float.w) else {
            return false;
        };
        (float.x, float.w, float.pad) = (x, w, x - cursor);
        cursor = x + w;
        true
    });

    Strip {
        count,
        w: strip_w,
        frame_x,
        frame_w: SCREEN_PX,
        crop_left,
        crop_right,
        columns: blocks,
        floating: drawn_floats,
    }
}

/// Tiled windows of a workspace, grouped into columns, left to right.
pub fn columns_of(state: &State, workspace_id: u64) -> Vec<Column> {
    let mut grouped: BTreeMap<u32, Vec<&Window>> = BTreeMap::new();
    for window in state.windows.values() {
        if window.workspace_id != workspace_id {
            continue;
        }
        if let Some((column, _)) = window.scroll_pos {
            grouped.entry(column).or_default().push(window);
        }
    }
    grouped
        .into_iter()
        .map(|(idx, mut tiles)| {
            tiles.sort_by_key(|w| w.scroll_pos.map_or(0, |(_, tile)| tile));
            Column {
                idx,
                width: tiles.iter().map(|w| w.tile_w).fold(0.0, f64::max),
                urgent: tiles.iter().any(|w| w.urgent),
                apps: tiles
                    .iter()
                    .map(|w| w.app_id.as_str())
                    .collect::<Vec<_>>()
                    .join(", "),
                // A stack takes the icon of its topmost tile.
                icon: tiles[0].icon.clone(),
                tiles: tiles.iter().map(|w| w.id).collect(),
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const VIEW: f64 = 1920.0;
    const HALF: f64 = 957.0;
    const FULL: f64 = 1916.0;

    fn column(idx: u32, width: f64, tiles: &[u64]) -> Column {
        Column {
            idx,
            width,
            tiles: tiles.to_vec(),
            urgent: false,
            apps: "kitty".into(),
            icon: "/icons/kitty.png".into(),
        }
    }

    #[test]
    fn icons_are_sized_to_their_block_and_dropped_when_it_is_a_sliver() {
        // Drawn as an overlay, which GTK does not clip, so an icon wider than its
        // block would spill over the neighbouring one.
        let strip = build(
            &[
                column(1, FULL, &[1]),
                column(2, HALF, &[2]),
                column(3, 120.0, &[3]),
            ],
            1,
        );
        let [wide, half, sliver] = [0, 1, 2].map(|i| &strip.columns[i]);
        assert_eq!(wide.icon_px, ICON_MAX_PX);
        assert!(half.icon_px < ICON_MAX_PX && half.icon_px <= half.w - 2);
        assert_eq!(sliver.icon, "", "no icon rather than a smudge");
    }

    fn urgent(idx: u32, width: f64, tiles: &[u64]) -> Column {
        Column {
            urgent: true,
            ..column(idx, width, tiles)
        }
    }

    fn row(count: u32) -> Vec<Column> {
        (1..=count).map(|i| column(i, HALF, &[i as u64])).collect()
    }

    fn build(columns: &[Column], active: u64) -> Strip {
        build_strip(columns, &[], VIEW, Some(active), &mut View::default())
    }

    /// Successive focus changes on one workspace, sharing its view.
    fn refocus(view: &mut View, columns: &[Column], active: u64) -> Strip {
        build_strip(columns, &[], VIEW, Some(active), view)
    }

    fn states(strip: &Strip) -> Vec<&'static str> {
        strip.columns.iter().map(|c| c.state).collect()
    }

    #[test]
    fn blocks_stay_inside_the_strip() {
        for count in [1, 2, 5, 9, 20] {
            let strip = build(&row(count), 1);
            assert!(strip.w <= MAX_PX, "{count} columns overflowed the cap");
            for block in &strip.columns {
                assert!(
                    block.x >= 0 && block.x + block.w <= strip.w,
                    "{count} columns"
                );
                assert!(block.pad >= 0);
            }
        }
    }

    #[test]
    fn pads_reconstruct_positions() {
        // The yuck lays blocks out by padding alone, so pad must be the gap to the
        // previous block, not to the strip origin.
        let strip = build(&row(4), 2);
        let mut cursor = 0;
        for block in &strip.columns {
            cursor += block.pad;
            assert_eq!(cursor, block.x);
            cursor += block.w;
        }
    }

    #[test]
    fn frame_is_always_one_screenful() {
        for columns in [
            vec![column(1, 640.0, &[1])],
            vec![column(1, FULL, &[1])],
            row(7),
        ] {
            let strip = build(&columns, 1);
            assert_eq!(strip.frame_w, SCREEN_PX);
            assert!(strip.frame_x >= 0 && strip.frame_x + strip.frame_w <= strip.w);
        }
    }

    #[test]
    fn focused_column_is_inside_the_frame() {
        let columns = row(5);
        for active in 1..=5 {
            let strip = build(&columns, active);
            let block = strip.columns.iter().find(|b| b.state == "focused").unwrap();
            assert!(block.x >= strip.frame_x, "active={active}");
            assert!(
                block.x + block.w <= strip.frame_x + strip.frame_w,
                "active={active}"
            );
        }
    }

    #[test]
    fn column_wider_than_the_view_anchors_the_frame() {
        // niri cannot fit it, so it aligns the column's left edge with the view.
        let strip = build(&[column(1, HALF, &[1]), column(2, 3000.0, &[2])], 2);
        let block = strip.columns.iter().find(|b| b.state == "focused").unwrap();
        assert_eq!(block.x, strip.frame_x);
    }

    #[test]
    fn focusing_rightwards_scrolls_the_least_it_can() {
        // Focusing the middle column brings its right edge into the view, so the
        // screen-wide column behind it is left half on screen rather than
        // scrolled off.
        let columns = [
            column(1, FULL, &[1]),
            column(2, HALF, &[2]),
            column(3, HALF, &[3]),
        ];
        let view = &mut View::default();
        assert_eq!(refocus(view, &columns, 1).frame_x, 0);

        let strip = refocus(view, &columns, 2);
        let focused = &strip.columns[1];
        assert!(focused.x > strip.frame_x, "not flush with the view's left");
        assert!(focused.x + focused.w <= strip.frame_x + SCREEN_PX);
        let behind = &strip.columns[0];
        assert!(
            behind.dim_left > 0 && behind.dim_left < behind.w,
            "the wide column stays half visible"
        );
    }

    #[test]
    fn a_column_already_on_screen_does_not_move_the_view() {
        let columns = row(3);
        let view = &mut View::default();
        let before = refocus(view, &columns, 1);
        // Two halves fit one screenful, so niri has nothing to scroll.
        assert_eq!(refocus(view, &columns, 2).frame_x, before.frame_x);
    }

    #[test]
    fn the_view_rides_the_focused_column_when_the_layout_shifts_under_it() {
        // niri holds the view relative to the focused column, so a column
        // widening to its left pushes the view along with it instead of leaving
        // the focused column to be refitted against the view's edge.
        let narrow: Vec<Column> = (1..=7).map(|i| column(i, 400.0, &[i as u64])).collect();
        let view = &mut View::default();
        let before = refocus(view, &narrow, 3);
        let mut widened = narrow.clone();
        widened[0].width = 1200.0;
        let after = refocus(view, &widened, 3);

        let place = |strip: &Strip| strip.columns[2].x - strip.frame_x;
        assert!(
            (place(&after) - place(&before)).abs() <= 1,
            "focused column moved in the view: {} -> {}",
            place(&before),
            place(&after)
        );
    }

    #[test]
    fn widths_are_proportional_with_a_floor() {
        // A screen-wide column spans the frame, a half-width one spans half of it,
        // and a sliver is floored so it cannot vanish.
        let strip = build(&[column(1, FULL, &[1])], 1);
        assert_eq!(strip.columns[0].w, SCREEN_PX);
        let strip = build(
            &[
                column(1, HALF, &[1]),
                column(2, FULL, &[2]),
                column(3, 20.0, &[3]),
            ],
            1,
        );
        assert!((strip.columns[0].w - SCREEN_PX / 2).abs() <= SEP_PX);
        assert_eq!(strip.columns[2].w, MIN_COL_PX);
    }

    #[test]
    fn touching_blocks_are_separated_by_shrinking_the_left_one() {
        // Drawing the separation between blocks instead would make a screenful of
        // columns wider than the frame and push the focused column outside it.
        let strip = build(&row(2), 1);
        let (left, right) = (&strip.columns[0], &strip.columns[1]);
        assert_eq!(left.x + left.w + SEP_PX, right.x);
        assert_eq!(right.pad, SEP_PX);
    }

    #[test]
    fn offscreen_columns_are_dimmed_end_to_end() {
        let strip = build(&[column(1, FULL, &[1]), column(2, FULL, &[2])], 1);
        let (visible, offscreen) = (&strip.columns[0], &strip.columns[1]);
        assert_eq!((visible.dim_left, visible.dim_right), (0, 0));
        assert_eq!(
            offscreen.dim_left + offscreen.dim_right,
            offscreen.w,
            "no pixel is in view"
        );
    }

    #[test]
    fn a_column_straddling_the_frame_is_dimmed_up_to_the_edge() {
        // The case a flat block could not express: one window half scrolled off
        // plus one fully visible must not look like two fully visible windows.
        let straddling = build(&[column(1, FULL, &[1]), column(2, HALF, &[2])], 2);
        let cut = &straddling.columns[0];
        assert_eq!(cut.dim_left, strip_frame_offset(&straddling, cut));
        assert!(
            cut.dim_left > 0 && cut.dim_left < cut.w,
            "part of it is on screen"
        );
        assert_eq!(cut.dim_right, 0);

        let side_by_side = build(&[column(1, HALF, &[1]), column(2, HALF, &[2])], 2);
        assert!(side_by_side
            .columns
            .iter()
            .all(|b| (b.dim_left, b.dim_right) == (0, 0)));
    }

    /// Pixels of the block that sit left of the frame, computed independently of
    /// the code under test.
    fn strip_frame_offset(strip: &Strip, block: &Block) -> i64 {
        (strip.frame_x - block.x).clamp(0, block.w)
    }

    #[test]
    fn a_column_wider_than_the_screen_is_dimmed_on_both_sides() {
        let strip = build(&[column(1, 5760.0, &[1])], 1);
        let block = &strip.columns[0];
        assert!(block.dim_left == 0 && block.dim_right > 0);
        assert_eq!(block.w - block.dim_left - block.dim_right, SCREEN_PX);
    }

    #[test]
    fn urgent_outranks_focus_and_visibility() {
        let columns = [
            column(1, HALF, &[1]),
            urgent(2, HALF, &[2]),
            urgent(3, FULL, &[3]),
        ];
        assert_eq!(states(&build(&columns, 1)), ["focused", "urgent", "urgent"]);
    }

    #[test]
    fn cropping_keeps_the_frame_and_clips_the_edges() {
        let strip = build(&row(12), 6);
        assert_eq!(strip.w, MAX_PX);
        assert!(strip.crop_left && strip.crop_right);
        assert!(strip.frame_x >= 0 && strip.frame_x + strip.frame_w <= strip.w);
        assert!(
            strip.columns.len() < 12,
            "columns outside the crop are dropped"
        );
        assert_eq!(strip.count, 12, "but all windows are still counted");
    }

    #[test]
    fn crop_flags_follow_the_focused_column() {
        let columns = row(12);
        let left = build(&columns, 1);
        assert!(!left.crop_left && left.crop_right);
        let right = build(&columns, 12);
        assert!(right.crop_left && !right.crop_right);
    }

    #[test]
    fn tiles_are_capped_and_the_active_one_is_marked() {
        let strip = build(&[column(1, HALF, &[1, 2, 3, 4, 5])], 3);
        assert_eq!(strip.columns[0].tiles, [false, false, true]);
        assert_eq!(strip.count, 5, "the cap is a drawing limit, not a count");
    }

    #[test]
    fn a_column_without_the_active_window_lights_every_tile() {
        // Dimming it instead would make an ordinary unfocused window look like one
        // scrolled off screen.
        let strip = build(&[column(1, HALF, &[1, 2]), column(2, HALF, &[3])], 3);
        assert_eq!(strip.columns[0].tiles, [true, true]);
    }

    #[test]
    fn floating_windows_are_placed_relative_to_the_frame() {
        let strip = build_strip(
            &[column(1, FULL, &[1])],
            &[(960.0, 480.0)],
            VIEW,
            Some(1),
            &mut View::default(),
        );
        let float = &strip.floating[0];
        assert_eq!(float.x, strip.frame_x + SCREEN_PX / 2);
        assert_eq!(float.w, SCREEN_PX / 4);
    }

    #[test]
    fn empty_workspace_yields_an_empty_strip() {
        let strip = build_strip(&[], &[], VIEW, None, &mut View::default());
        assert_eq!((strip.count, strip.w), (0, SCREEN_PX));
        assert!(strip.columns.is_empty());
    }
}
