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
/// one. `ICON_MAX_PX` is the strip's band height; below `ICON_MIN_PX` the
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
    /// Lowercased `app_id` of the app owning the column, for the bar's glyph table.
    pub app_id: String,
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
    /// Ends cut by the crop rather than by the column's own edge; drawn square.
    pub cut_left: bool,
    pub cut_right: bool,
    pub tooltip: String,
    pub app_id: String,
    pub icon: String,
    /// Side of the square the icon is drawn at; 0 when the block is too narrow
    /// to carry one or is cut by the crop.
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
    /// On-screen part of the whole workspace, scaled onto the strip's width, as
    /// `(x, w)`; only when the strip is cropped and no longer shows it all.
    pub thumb: Option<(i64, i64)>,
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
            cut_left: false,
            cut_right: false,
            tooltip: column.apps.clone(),
            app_id: column.app_id.clone(),
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
    // neighbour: the widget draws it as an unclipped overlay.
    for block in &mut blocks {
        block.icon_px = ICON_MAX_PX.min(block.w - 2);
        if block.icon_px < ICON_MIN_PX {
            block.icon_px = 0;
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
    let mut thumb = None;
    let mut offset = 0;
    if strip_w > MAX_PX {
        let centred = frame_x as f64 + SCREEN_PX as f64 / 2.0 - MAX_PX as f64 / 2.0;
        offset = centred.round().clamp(0.0, (strip_w - MAX_PX) as f64) as i64;
        let shrink = |px: i64| (px as f64 * MAX_PX as f64 / strip_w as f64).round() as i64;
        let w = shrink(SCREEN_PX).max(2);
        thumb = Some((shrink(frame_x).clamp(0, MAX_PX - w), w));
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
        block.cut_left = x > block.x - offset;
        block.cut_right = x + w < block.x - offset + block.w;
        if block.cut_left || block.cut_right {
            block.icon_px = 0;
        }
        (block.x, block.w, block.pad) = (x, w, x - cursor);
        cursor = x + w;
        true
    });

    // A frame edge landing in the gap carved next to a block would run the rails
    // past the block; pull it onto the block's edge instead.
    let covered = |px: i64| blocks.iter().any(|b| b.x <= px && px < b.x + b.w);
    let mut frame_end = frame_x + SCREEN_PX;
    if !covered(frame_end - 1) {
        let end = blocks.iter().map(|b| b.x + b.w).filter(|&e| e > frame_x && e < frame_end).max();
        if let Some(end) = end.filter(|&e| frame_end - e <= SEP_PX) {
            frame_end = end;
        }
    }
    if !covered(frame_x) {
        let start = blocks.iter().map(|b| b.x).filter(|&s| s > frame_x && s < frame_end).min();
        if let Some(start) = start.filter(|&s| s - frame_x <= SEP_PX) {
            frame_x = start;
        }
    }
    for block in &mut blocks {
        (block.dim_left, block.dim_right) = outside_frame(block.x, block.w, frame_x, frame_end);
    }

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
        frame_w: frame_end - frame_x,
        thumb,
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
                // A stack takes the app of its topmost tile.
                app_id: tiles[0].app_id.to_lowercase(),
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
            app_id: "kitty".into(),
            icon: "/icons/kitty.png".into(),
        }
    }

    #[test]
    fn icons_are_sized_to_their_block_and_dropped_when_it_is_a_sliver() {
        // Drawn as an unclipped overlay, so an icon wider than its
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
        assert_eq!(sliver.icon_px, 0, "no icon rather than a smudge");
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
        // The bar lays blocks out by padding alone, so pad must be the gap to the
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
    fn frame_is_one_screenful_less_at_most_a_carved_gap() {
        for columns in [
            vec![column(1, 640.0, &[1])],
            vec![column(1, FULL, &[1])],
            row(7),
        ] {
            let strip = build(&columns, 1);
            assert!((SCREEN_PX - SEP_PX..=SCREEN_PX).contains(&strip.frame_w));
            assert!(strip.frame_x >= 0 && strip.frame_x + strip.frame_w <= strip.w);
        }
    }

    #[test]
    fn frame_stops_at_the_block_rather_than_the_gap_beside_it() {
        let columns = [column(1, FULL, &[1]), column(2, FULL, &[2])];
        let left = build(&columns, 1);
        let block = &left.columns[0];
        assert_eq!(
            (left.frame_x, left.frame_x + left.frame_w),
            (block.x, block.x + block.w)
        );
        let right = build(&columns, 2);
        let block = &right.columns[1];
        assert_eq!(
            (right.frame_x, right.frame_x + right.frame_w),
            (block.x, block.x + block.w)
        );
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
        assert!(strip.frame_x >= 0 && strip.frame_x + strip.frame_w <= strip.w);
        assert!(
            strip.columns.len() < 12,
            "columns outside the crop are dropped"
        );
        assert_eq!(strip.count, 12, "but all windows are still counted");
    }

    #[test]
    fn blocks_cut_by_the_crop_are_flagged_and_lose_their_icon() {
        let strip = build(&row(12), 6);
        let (first, last) = (&strip.columns[0], strip.columns.last().unwrap());
        assert!(first.cut_left && !first.cut_right && first.icon_px == 0);
        assert!(last.cut_right && !last.cut_left && last.icon_px == 0);
        let inner = &strip.columns[1..strip.columns.len() - 1];
        assert!(inner.iter().all(|b| !b.cut_left && !b.cut_right && b.icon_px > 0));
    }

    #[test]
    fn thumb_places_the_screen_within_the_whole_workspace() {
        assert_eq!(build(&row(2), 1).thumb, None, "an uncropped strip is the whole workspace");
        let columns = row(12);
        let (x, w) = build(&columns, 1).thumb.unwrap();
        assert_eq!(x, 0);
        assert!(w >= 2 && w < MAX_PX);
        let (x, w) = build(&columns, 12).thumb.unwrap();
        assert_eq!(x + w, MAX_PX);
        let (mid, _) = build(&columns, 6).thumb.unwrap();
        assert!(0 < mid && mid < x, "moves with the view");
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
