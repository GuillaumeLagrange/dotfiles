# niri-state

One niri IPC tap feeding the left side of a status bar: workspaces, the focused
window title per output, and the strip - a scale model of the active
workspace's scrolling layout. Emits one JSON line per change on stdout.

Both bars read it: `modules/gui/eww/` through a `deflisten`, and
`modules/gui/quickshell/` through a `SplitParser`. It lives beside them rather
than inside either, and both `callPackage ../niri-state/_package.nix`, so there
is one derivation and one build.

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

**Geometry is emitted in final pixels**, so neither bar does arithmetic: the
strip is `SCREEN_PX` per screenful, grows behind a fixed frame up to `MAX_PX`,
and is cropped around the frame past that. A column that straddles the frame
edge stays one block with `dim_left`/`dim_right` pixels for the bar to shade -
splitting it into two boxes would read as a cut.

**One process, blocked on a socket read.** The model is kept in memory and
updated from event deltas, snapshots are printed only when they differ, and a
burst of events (the startup dump, a drag moving every column) folds into one
line.

