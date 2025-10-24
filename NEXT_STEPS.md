# Phase 1 Optimization & Persistence Execution Plan

This plan translates the roadmap “In Progress” and “Next Up” buckets into actionable steps so we can close out Phase 1 and stage the next phase.

---

## 1. Performance Profiling & Optimization *(roadmap: In Progress)*

**Objective:** Capture real metrics for chunk streaming, LOD budgets, and frame timings so tuning is evidence-driven.

- **Instrumentation**
  - HUD lines in `src/demo.zig` already emit chunk counts, vertex/triangle totals, LOD tiers, and streaming timings.
  - `ChunkStreamingManager.profilingStats()` exposes avg/max update times plus queue depths.
  - Metal Performance HUD available via `MTL_HUD_ENABLED=1`.
- **Capture loop**
  1. Build latest code: `zig build render -Dskip-run=true`.
  2. Run the headless profiler to capture CSV metrics: `ZIG_GLOBAL_CACHE_DIR=zig-global-cache ./zig-out/bin/render-demo --profile-log docs/perf/<name>.csv --profile-frames 300`.
  3. Optionally, capture visual sweeps via `--scenario lod-sweep --scenario-settle 180` when a display is available.
  3. Every ~10 s record HUD metrics + Metal HUD screenshots; dump to `docs/perf/baseline-YYYYMMDD.csv`.
  4. Note spikes (budget skipped, streaming avg >6 ms, etc.) with context (camera position, view distance).
- **Follow-up**
  - Adjust `max_chunks_per_frame`, LOD radii, or async queue sizes based on bottlenecks.
  - Re-run captures after each tuning round and archive deltas.

---

## 2. Chunk Persistence Polish *(roadmap: In Progress)*

**Objective:** Make autosave/backup workflows hands-off and transparent.

- **Autosave-triggered compaction**
  - After `forceAutosave()` success, enqueue `queueLoadedRegionBackups()` if cooldown permits.
  - Surface queue status in HUD + console.
- **Settings UI**
  - Extend world-management menu with autosave interval picker, backup retention slider, and last-run timestamps.
  - Persist selections per world.
- **Scheduled compaction**
  - Add timer-based enqueue (e.g., every 20 min of play) so long sessions get periodic maintenance.
  - Ensure requests coalesce and respect cooldowns.
- **Docs & roadmap**
  - Summarize behaviour in new `docs/persistence.md`.
  - Move checklist items to “Completed” once shipped.

---

## 3. Test Coverage for LOD & Persistence *(roadmap: In Progress)*

**Objective:** Lock regressions before expanding features.

- **LOD scheduler tests**
  - Drive scheduler with synthetic camera positions verifying hysteresis and tier thresholds.
  - Assert counts for near/mid/far buckets.
- **Persistence workflow tests**
  - Integration test: generate chunks → autosave → backup enqueue → reload and verify data integrity.
  - Mock filesystem via temp directories to keep CI clean.
- **Test harness**
  - Add `tests/streaming.zig` (or similar) and wire into `zig build test`.

---

## 4. Multi-Block Selection & Copy/Paste *(roadmap: Next Up)*

**Objective:** Introduce creative tooling without breaking single-block flow.

- Design selection data structure (min/max corners + block palette).
- Prototype input binding (e.g., hold `Shift` to start selection, drag span).
- Render selection volume via existing line mesh system.
- Implement clipboard apply/rotate; start as in-memory only.
- After playtesting, expose in UI with clear affordances.

---

## 5. Automated Backup Scheduling & Incremental Snapshots *(roadmap: Next Up)*

**Objective:** Give worlds restore points even when players forget.

- Scheduler that triggers on wall-clock and playtime thresholds.
- Incremental snapshot format building on existing RLE region files.
- Retention strategy (ring buffer sized by UI setting) with pruning logs.
- HUD + menu indicators whenever snapshots run or are pruned.

---

## 6. World Management UI Polish *(roadmap: Next Up)*

**Objective:** Make save administration approachable.

- Add panels for:
  - Difficulty history + overrides.
  - Autosave/backup configuration with quick actions.
  - Recent maintenance events (autosaves, backups, compactions, errors).
- Reuse HUD notification store to populate the history list.
- Audit all buffers vs. limits (`max_world_name_len`, etc.) to prevent input overflows.

---

## 7. Environmental Simulation Design Pass *(roadmap: Next Up)*

**Objective:** Frame Phase 2 scope for weather, fluids, and temperature.

- Document requirements (performance budgets, persistence impact, rendering hooks).
- Outline block-state extensions (liquid levels, temperature metadata).
- Plan tick scheduling and chunk update flow (threading implications).
- Produce `docs/environment_sim.md` draft with phased rollout milestones.

---

## Execution Rhythm

- **Weekly loop:** Capture profiling baseline → adjust → update `ROADMAP.md`.
- **Definition of done:** Code + docs + tests all land before moving items to “Completed”.
- **Communication:** Reference roadmap section in commit messages and session notes.
