# 2025-10-23 Headless Profiling Snapshot

Source data: `docs/perf/baseline-1.csv` (300 frames, normal difficulty, view distance 10).

## High-Level Metrics

- **Average frame time:** 6.51 ms (≈153 FPS)
- **Peak frame time:** 16.63 ms (frame 1 warm-up)
- **Steady state peaks:** 13.7 ms at the first LOD tier transition (frame 48) and 13.0 ms at the second (frame 160)
- **Max loaded chunks:** 25 (≈ 5×5 footprint around the anchor point)
- **Total rendered meshes after warm-up:** 7 LOD buckets (full detail 4, mid 3, far 0)
- **Streaming averages:** 0.19 ms average update, 70 ms historical max recorded during the initial warm-up burst
- **Pending generation queue:** stabilises at ~148 entries once the view settles

## Observations

- All spikes correspond to LOD tier promotions (`regenerations = 2`). Once the new meshes are built the frame time drops back under 7 ms.
- `budget_skipped` remains zero for the full capture, showing current per-frame chunk limits are generous. Any tuning should focus on smoothing mesh regeneration rather than increasing budgets.
- Pending generation count is high because the far-LOD scheduler keeps pointing at additional distant chunks; with the current `surfaceFar` impostor this does not impact frame time but is worth monitoring when async meshing becomes more aggressive.

## Recommendations

1. **Keep existing chunk budgets** (normal difficulty: 4 chunk uploads per frame). They are not the bottleneck and ensure the world warms up quickly.
2. **Dynamic LOD regeneration throttle** — now implemented (2025-10-23). The runtime loop clamps mesh regenerations to 1/2/3 per frame based on the previous frame’s ms budget (>10 ms ↦ 1, >8 ms ↦ 2, otherwise 3). Monitor future captures to ensure this flattens the spikes without starving near-field updates.
3. **Scheduled maintenance cadence** — chunk streaming now queues region-compaction jobs every 10 minutes (with cooldown and retry), and the HUD surfaces a notice whenever a batch is enqueued.
4. **Add an aggregate profiler** that computes summary stats automatically (avg/max frame time, highest pending queue) for future runs to speed up regression analysis.

Next focus: confirm the throttle’s effect in an interactive capture, then move on to the persistence polish efforts.
