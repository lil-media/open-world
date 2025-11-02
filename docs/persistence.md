# Persistence & Maintenance Overview

## Autosave Flow
- Autosave runs on the configured interval or when forced manually.
- Each autosave records:
  - `saved_chunks`: number of modified chunks written to disk.
  - `errors`: failed chunk saves.
  - `duration_ns`: elapsed time.
  - `reason`: whether the save was timer-driven or manual.
  - Maintenance queue metrics:
    - `queued_regions_total`: total region compaction jobs pending after the autosave.
    - `queued_regions_added`: how many new jobs the autosave contributed.

## Maintenance Queue Feedback
- When new jobs are enqueued, the console prints:
  - Total queued regions, newly added regions, and estimated cooldown remaining.
- The interactive HUD shows notifications:
  - `Maintenance: +N (total T, ~Cs)` when new jobs were added.
  - `Maintenance queued` if no additional jobs were needed.

## Save Settings Panel
- Open the world management menu and press `F6` to toggle the save settings panel.
- Use `UP/DOWN` to select between autosave cadence and backup retention.
- Adjust the highlighted value with `LEFT/RIGHT` to cycle through supported presets (including `OFF` for autosave).
- Press `ESC` or `F6` again to close the panel; changes persist immediately and surface in the autosave/backup status lines.

## Cooldown & Scheduling
- Region compaction requests respect a cooldown (`backup_queue_cooldown_ns`).
- Scheduled maintenance retries after the cooldown and only surfaces notices when new work was added.
- Back-to-back queue attempts inside the cooldown reuse the existing totals and suppress duplicate notices, keeping feedback noiseless.
- The cadence automatically tunes between 5 and 20 minutes based on the rolling maintenance activity score.
- Activity score weights newly queued regions and total queue depth to shorten the interval during heavy editing sessions and
  lengthen it when the world is idle.
- HUD and menu surfaces show the current cadence (minutes) plus the activity score so players can predict when the next
  maintenance sweep will occur.

## Maintenance Processing
- `WorldPersistence.serviceMaintenance(max_jobs)` drains the pending compaction queue and runs up to `max_jobs` batches per tick.
- Each compaction snapshots the previous region file to the backups directory, rewrites the active data set, and updates
  maintenance metrics (`total_compactions`, `last_compaction_timestamp`, and `last_compaction_duration_ns`).
- Backup retention rules are enforced after every compaction so `retained_backups` and `last_backup_timestamp` always reflect the
  current on-disk state.

## Regression Coverage
  - `autosave persists modified chunk data to disk` exercises a full autosave → maintenance enqueue → reload flow using the chunk streaming manager, ensuring modified blocks survive a forced autosave and can be reloaded after maintenance service drains the queue.
  - `timer-driven autosave surfaces summary once` verifies interval-based saves publish a single summary/notice pair, update cooldown metrics, and leave maintenance queues ready for servicing.

## Roadmap Status
- Roadmap entry "Autosave-triggered region maintenance queue" now tracks total/delta counts.
