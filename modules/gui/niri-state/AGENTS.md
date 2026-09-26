# niri-state

One niri IPC tap feeding the left side of a status bar: workspaces, the focused
window title per output, the focused output itself, and the strip - a scale
model of the active workspace's scrolling layout. Emits one JSON line per
change on stdout.

The quickshell bar (`modules/gui/quickshell/`) reads it through a
`SplitParser`. It lives beside the bar as its own package, built by
`callPackage ../niri-state/_package.nix`.

```
src/json.rs   minimal JSON reader/writer for niri's shapes
src/model.rs  workspace/window model, updated from event deltas
src/strip.rs  the strip geometry and its tests
src/icons.rs  app_id -> icon file, via .desktop entries
src/emit.rs   one snapshot line per change
src/main.rs   socket, coalescing, dedupe
```

No dependencies, so the lock file is trivial and nothing is vendored. `cargo
test` runs in the check phase, so a broken invariant fails the rebuild.

```bash
cargo test        # geometry and model invariants
```

## Design

**The view is tracked, not reported.** niri sets
`tile_pos_in_workspace_view` for floating tiles only; it is None for every
tiled one, so `strip.rs` carries a `View` per workspace and advances it by the
rule niri guarantees - the focused column is fully on screen. A column already
on screen leaves the view alone; one off screen scrolls by the least that
brings it fully in. That is why focusing rightwards leaves the column behind
half visible rather than pushing it off.

The offset is anchored to a window of the focused column, not to an absolute
position, so columns opening, closing or resizing elsewhere do not drag the
view.

**Geometry is emitted in final pixels**, so the bar does no arithmetic: the
strip is `SCREEN_PX` per screenful, grows behind a fixed frame up to `MAX_PX`,
and is cropped around the frame past that. A column that straddles the frame
edge stays one block with `dim_left`/`dim_right` pixels for the bar to shade -
splitting it into two boxes would read as a cut. A cropped strip also carries a
`thumb`: the screen's place in the whole workspace, scaled onto the strip's
width, which the bar draws as a minimap under it. Blocks cut by the crop are
flagged `cut` and lose their icon.

**The frame is snapped onto block edges.** Separation is carved out of the left
block of each pair, so a frame edge that lands in that `SEP_PX` gap is pulled
onto the block beside it; otherwise the rails run past the focused column.
`frame_w` is therefore up to `SEP_PX` short of `SCREEN_PX`.

**Icons are keyed twice.** Each block carries its lowercased `app_id`, which
the bar looks up in its own glyph table, and the resolved icon file, which it
falls back to (greyed) for apps the table does not know.

**The scale is the output's logical width, and niri has no output event.**
`SCREEN_PX / view_w` is what makes a block proportional, so the width has to be
right on the output the workspace is on - a 2560-wide screen measured as 1920
draws a maximised window 63px wide against a 32px frame and shades the third of
it that "does not fit", which is the whole point of the frame. The event stream
carries nothing about outputs (no variant for hotplug, mode or scale), so
`Outputs` is re-queried: at once when an active workspace sits on an output
that is not in the map, which is a monitor that appeared after startup, and
otherwise throttled to `OUTPUT_REFRESH`, because asking is the only way to
notice a resolution or scale change. Idle costs nothing: the query only happens
when a snapshot is being emitted anyway.

**Only widths are modelled.** A column's tiles split the band equally; no tile
height and no output height is carried, so the strip says nothing about how a
column is split vertically.

**One process, blocked on a socket read.** The model is kept in memory and
updated from event deltas, snapshots are printed only when they differ, and a
burst of events (the startup dump, a drag moving every column) folds into one
line.

**`focused_output` is read off every workspace, not the emitted ones.** The
`workspaces` array carries only named workspaces, because that is what the bars
draw, while focus can sit on a dynamic one; the quickshell bar places
notification popups on that output, so it needs the answer even then.

