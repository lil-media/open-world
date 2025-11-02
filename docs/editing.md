# Building Tools & Multi-Block Selection

## Overview
The chunk streaming manager now exposes first-class helpers for selecting blocks across multiple chunks, copying them into a clipboard, and pasting the captured volume elsewhere in the world. These APIs provide the foundation for creative tooling such as region duplication, templates, and future rotation/mirroring workflows.

## Selection Flow
1. **Begin a selection** with `ChunkStreamingManager.beginSelection(x, z, y)` using world coordinates for the anchor corner.
2. **Update the selection** by calling `updateSelection` as the cursor moves. The manager normalizes the bounds so that `selectionBounds()` always returns min/max ranges regardless of drag direction.
3. **Inspect the active selection** through `selectionBounds()` or `selectionActive()` before triggering clipboard operations.
4. **Clear the selection** via `clearSelection()` when the user cancels or after a paste.

The bounds are stored as `SelectionBounds` which reports the inclusive dimensions with the helper methods `width()`, `depth()`, and `height()`.

## Clipboard Operations
- **Copy**: `copySelection()` captures the current bounds, clamps vertical extents to the chunk height, and fills an internal clipboard with the blocks retrieved via `getBlockWorld`. It returns the normalized bounds so callers can display sizing feedback.
- **Inspect clipboard**: `clipboardDimensions()` yields the stored width, depth, and height while `clipboardIsEmpty()` reports whether data is present.
- **Paste**: `pasteClipboard(dest_x, dest_z, dest_y)` replays the buffered blocks relative to the destination corner. The manager skips writes outside the valid vertical range and reuses `setBlockWorld` so chunk modification flags are preserved.

If `copySelection()` is invoked without an active selection an `error.NoSelection` is returned. Attempting to paste with an empty clipboard produces `error.ClipboardEmpty`.

## Regression Coverage
Two new tests in `src/terrain/streaming.zig` cover the workflow:
- `selection copy captures blocks and paste restores volume` drives copy → paste across offsets and validates that the clipboard dimensions and block contents round-trip correctly.
- `copy selection and paste validate error paths` asserts that the helper surfaces `NoSelection` and `ClipboardEmpty` in edge cases.

## Next Steps
With the core data structures in place the UI layer can bind drag inputs to the selection helpers, expose volume sizing in the HUD, and add rotation/mirroring modes before paste execution.
