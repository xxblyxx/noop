# Pending validation — claims shipped but not yet confirmed on real data

Some changes here cannot be validated when they land. The strap produces the confirming data hours
or nights later, and some of it only when the wearer's body, the phone's connection state, or the
firmware happens to do the thing the code is watching for. That gap is where a fix quietly becomes
folklore: it was reasoned about carefully, the tests pass, nobody ever saw it work.

**This file is the list of those debts.** `Tools/pending-validation.py` reads it from a
`SessionStart` hook (see `.claude/settings.json`) and surfaces the entries whose `check-after` date
has arrived, so a new session opens by ASKING whether you want to check — regardless of what that
session was actually about.

## Scope — keep this narrow

Only **claims awaiting evidence**: something shipped, whose correctness rests on data that did not
exist yet. Not a TODO list, not a wishlist, not refactors. The moment "would be nice to clean up X"
lands here, the session-start reminder becomes wallpaper and stops working for the entries that
matter. Ordinary follow-ups belong in the tracker.

## How to use it

**Adding.** Any change whose correctness rests on unobserved data gets an entry before the work is
called done. Fill in every field — an entry that cannot be acted on in six months is noise:

| field | what it must answer |
|---|---|
| `id` | short kebab-case slug, unique |
| `shipped` | commit + issue + date, so the code is findable |
| `claim` | what we asserted is true and have not seen |
| `needs` | the DATA EVENT that must occur before checking is even possible |
| `blocked-because` | why it hasn't happened yet — the honest reason, not a placeholder |
| `check` | the exact command to run |
| `passes-if` | what would count as confirmation, decided NOW rather than after seeing the result |
| `check-after` | earliest date a check could be informative |

`check-after` is the whole anti-nag mechanism. Set it to when the data could *plausibly* exist, not
to tomorrow.

⚠️ A missing or malformed `check-after` is treated as **ripe**, deliberately — a typo must make noise
rather than bury an item forever.

**Checking.** Run the `check` command. If it passes, move the entry to `## Settled` with one line
saying what was actually observed. If the data still isn't there, bump `check-after` and, if the
reason changed, update `blocked-because`. Bumping is honest; deleting an unvalidated entry is not.

**Settling.** Entries move to `## Settled` rather than being deleted. It costs one line and it is the
difference between "we checked and it held" and "someone got tired of seeing it."

---

## Open

### The `@82` SpO2 candidate is shown as a track, and still is not a validated percentage
- id: spo2-candidate-82-timeline
- shipped: `main` 2026-08-20 (#103) — `Repository.timelineRawMetric` `.spo2` + `FullDayChartView`,
  Kotlin twin in `FullDayChartScreen.kt`. The Deep Timeline's SINGLE SpO₂ track now falls back to the
  raw `@82` byte when the strap banked no `spo2Sample` (i.e. any 5/MG) and the default-off
  Experimental toggle (`PuffinExperiment.spo2CandidateDisplayKey`) is on, plotting only the
  `70...100` in-band bytes. Source selection is data-driven. The track is labelled plainly "SpO₂"
  whichever source feeds it — an earlier "SpO₂ Candidate (raw)" relabel was REMOVED by explicit owner
  decision on 2026-08-20. ⚠️ That raises the stakes of this entry: nothing on screen now separates the
  unvalidated `@82` byte from a calibrated reading, and the default-off Experimental toggle is the
  only thing still holding that line. The structural guards are untouched — no `spo2Pct` write, no
  gate input, `Interpreter.swift` prohibition and the `Whoop5HistoricalTests` tripwire both intact.
- claim: the byte at `@82` is a strap-computed SpO2 percentage. NOT asserted by anything shipped —
  the track is labelled "SpO₂ Candidate (raw)", carries no `%` suffix, writes no `spo2Pct`, and
  feeds no gate. This entry exists because SHOWING a number invites a reader to believe it, and the
  belief is the thing that is unvalidated.
- needs: nights where the `@82` in-band series can be compared against an independent oximeter
  ON A PER-TIMESTAMP BASIS. The nightly-mean route is CLOSED, not merely unfinished: the only
  reference available on this machine (Apple Health `metricSeries` key `spo2`) has SD **0.430** over
  31 days (range 96.08-97.76), so there is no variance to correlate against and r would be
  meaningless. Only the ~3.9-point constant offset would show, which proves nothing about tracking.
- blocked-because: 🟡 PARTIAL EVIDENCE, CONTRADICTORY ACROSS DEVICES. An 8-night independent
  validation tracked at corr +0.99 against the WHOOP app, but two nights on the original #103 device
  moved OPPOSITE — device/firmware variance still unresolved. A third strap now adds one clean
  night (2026-08-19→20, WHOOP 5.0): 22 duty windows of exactly 30 samples spaced exactly 1200 s,
  355 in-band readings, mean 93.07 / median 94 / range 72-100, against an Apple Health reference of
  96.08 for the same night. One night is not validation, and the reference is a DIFFERENT SENSOR:
  the SpO2 in Apple Health here is written by a RingConn Gen 2 via OpenCircuit, which NOOP files
  under a generic `apple-health` / "Apple Watch" device row. An Apple Watch Series 6 is also paired
  and writes `OxygenSaturation`, and `AppleHealthAggregator` does not filter by `sourceName`, so the
  daily figure may be a two-sensor blend.
- check: two steps, in order. (1) SOURCE PURITY AND CADENCE — export from the Health app
  (profile → Export All Health Data) and parse `export.xml` read-only for `Record` rows of type
  `OxygenSaturation`: report the `sourceName` distribution, the median inter-sample interval, and
  the count of RingConn records landing inside the `@82` duty windows at ±30 s and ±60 s.
  `Packages/StrandImport/.../AppleHealthImporter.swift` already parses these with `startDate` and
  `sourceName`. (2) ONLY IF that count is non-trivial — pull the store
  (`xcrun devicectl device copy from --device 00008150-000E434E3AD8401C --domain-type
  appDataContainer --domain-identifier com.bly.noop --source "Library/Application
  Support/OpenWhoop/whoop.sqlite" …`, plus `-wal`/`-shm`) and run
  `Tools/linux-capture/validate_spo2_candidate.py` for the `@82` side, which auto-detects the duty
  cycle rather than assuming it.
- passes-if: across ≥5 nights and ≥200 matched pairs, the paired per-timestamp comparison holds
  r ≥ 0.7 with MAE ≤ 2.5 points after removing a constant per-device offset, AND the sign of the
  correlation is consistent on every night. Anything that reproduces the split seen on the #103
  device — nights of opposite sign — settles this as NOT PROMOTABLE and the toggle stays the
  ceiling. Promotion additionally requires clearing the standing prohibition in `Interpreter.swift`
  and the `Whoop5HistoricalTests` tripwire, which are deliberate and must be removed knowingly.
- check-after: 2026-09-20

### Duplicate R-R ingest: the historical-wins rule has never run against a real night
- id: rr-historical-authority
- shipped: branch `fix/rr-duplicate-ingest` 2026-08-19 (#1451) — `WhoopStore.insertHistorical` +
  Kotlin `WhoopRepository.insertHistorical`. A batch decoded from the strap's banked history now
  CLEARS each wall-second it carries beats for before writing its own, so the live stream's copy of
  those same heartbeats no longer survives beside it.
- claim: (a) on a night with the phone connected throughout, stored R-R lands at ~1.0x the strap's
  own `Σ rr_count` instead of the measured 1.65x, and no second carries beats from two batches;
  (b) nothing legitimate is lost — seconds the strap banked no beats for keep their live rows, and
  overall beat coverage does not fall below what the strap itself claims.
- needs: one overnight offload on the fixed build, with the phone connected for the whole night
  (that is the condition that produced the duplication — a disconnected stretch banks once and would
  pass trivially).
- blocked-because: 🟡 MEASURED 2026-08-20, BUT THE NIGHT DOES NOT COUNT — it ran on a PRE-FIX
  binary. The fix landed on `main` at 2026-08-19 21:17 -0700, ~2 h before the night began, but the
  phone was not rebuilt until 2026-08-20 09:13, so the overnight ingest used the old code. The night
  therefore measures the BUG, not the fix, and cannot settle this entry.
  WHAT IT DOES GIVE: the first real overnight baseline, and it is worse than the daytime figure
  that motivated the fix. Over the full sleep window (2026-08-19 23:28:01→2026-08-20 07:43:16,
  `v18AuxSample` n=29,711, phone connected throughout): claimed Σ rr_count 26,722 vs stored 53,123 —
  **ratio 1.988** — with 23,483 duplicated `(ts, ord)` pairs across 26,300 reporting seconds
  (**89.3 %**). Every hour from 00:00 to 08:00 sits at 1.95–1.99 with 85–93 % duplication, i.e. a
  steady ~2.0, which this entry's own passes-if calls "the clear is not firing at all" — correct, it
  was not in the binary. The 1.65x daytime measurement understated the nightly cost.
  THE FIX DOES APPEAR TO WORK, on a window that cannot satisfy `needs`. Hourly ratios
  break sharply at the install: 08:00 = 1.992 (86.2 % dup), 09:00 = 1.138 (7.2 %), 10:00 = 1.102
  (0.59 %). A clean post-install slice, 09:20→10:22, reads **ratio 1.069 with 10 duplicated pairs
  over 1,241 reporting seconds**. Ratio is inside the 1.0–1.1 pass band and the residual is the
  handful `testALiveInsertNeverClearsAnything` predicts. But it is a ~1 h DAYTIME window, which is
  exactly the case `needs` rules out as passing trivially, so it is corroboration, not the check.
  NO OVER-DELETION: 3,411 seconds in the night carried a claimed count of 0, and 1,678 of them still
  hold R-R rows, so the clear is not eating seconds the strap banked nothing for. Ratio never went
  below 1.0 in any window.
- check: pull the store and re-run the Phase 0 analysis over the new night —
  `xcrun devicectl device copy from --device 00008150-000E434E3AD8401C --domain-type
  appDataContainer --domain-identifier com.bly.noop --source "Library/Application
  Support/OpenWhoop/whoop.sqlite" …` (plus `-wal`/`-shm`), decode `v18AuxSample` with the repo's own
  `V18AuxCodec`, then compare `Σ rr_count` against stored `rrInterval` rows for the night and count
  seconds holding two rows with the same `ord`.
- passes-if: stored ÷ claimed sits at 1.0–1.1 across the night (it was 1.65 before, ~2.0 per
  connected half-hour), AND duplicated-`ord` seconds are either 0 or a handful — under 0.5 % of
  reporting seconds, clustered at offload boundaries rather than spread through every connected
  half-hour. That residual is EXPECTED and is pinned by `testALiveInsertNeverClearsAnything`: a live
  flush landing after the historical batch for the same second still leaves both rows, and the
  Collector buffers ~30 readings before flushing. A steady ~2.0 means the clear is not firing at all;
  a ratio well BELOW 1.0 means it deletes more than it replaces and is the worse failure — check that
  seconds the strap claimed 0 beats for still hold their live rows.
- check-after: 2026-08-21

### The sync-rescore-storm fix reduces re-score CPU and Commit 5's BGProcessingTask actually fires
- id: sync-rescore-storm-fix
- shipped: `fix/sync-rescore-storm` branch, commits `59771a02`..`3f434482` (#1005-STORM), 2026-08-23
  — pending merge to `main`
- claim: the five commits together turn the measured re-score storm (10 passes / 21.5 min of
  re-score CPU in a 47-minute window, one 573s pass from a 12x overlap inflation) into ≤2 passes /
  <2 min with no overlapping pass, AND Commit 5's `SyncAnalyzeBackgroundScheduler` fires and scores
  a deferred night when the strap disconnects right after HISTORY_COMPLETE before the foreground
  analyze pass (`refreshAfterCompletedBackfill`) gets to run.
- needs: a real morning sync against a repopulated store from a live overnight WHOOP offload.
  Confirming Commit 5 specifically needs the narrower case: the strap coming off / going out of
  range right after HISTORY_COMPLETE while NOOP is backgrounded, before its 30s post-offload
  debounce fires.
- blocked-because: implemented same-day, 2026-08-23; no morning sync has occurred yet on this build.
- check:
  ```
  xcrun devicectl device copy from --device 819D37A3-B45A-56CF-9FEC-40D460EC74F8 \
    --domain-type appDataContainer --domain-identifier com.bly.noop \
    --source "Library/Preferences/com.bly.noop.plist" --destination /tmp/prefs.plist
  ```
  then in `strapLog.tail`: count `re-score: done` lines and sum their durations per sync window, and
  separately grep for `background analyze:` (Commit 5's own log tag, added specifically so this
  check can tell "never fired" apart from "fired and no-opped") to see whether/how often the
  BGProcessingTask ran.
- passes-if: | metric | baseline (2026-08-23) | target |
  |---|---|---|
  | re-score passes per ~47 min | 10 | ≤ 2 |
  | total re-score CPU per ~47 min | 21.5 min | < 2 min |
  | passes overlapping a backfill | 1 (573 s) | **0** |
  | worst single pass | 573 s | ≤ 60 s |

  For Commit 5: if any `background analyze:` line appears, `scored=true` only on a pass that
  genuinely had nothing scored yet (not on every backgrounding), and at most one "Sync complete"
  notification per deferred night. **Expect zero `background analyze:` lines, or one with
  `scored=false`, most mornings — that is the LIKELY outcome, not a failure.**
  `BGProcessingTaskRequest` scheduling is discretionary; iOS strongly prefers running it while
  charging and idle, typically hours after submission, by which point the user has almost always
  already reopened the app and the foreground path (`refreshAfterCompletedBackfill`) already scored
  the night — so the deferred wake finds nothing new and correctly no-ops. Treat a quiet log as
  untested, not broken; only a `BGProcessingTask submit failed` line, or a `scored=true` line that
  should have been `false` (or vice versa), is evidence of an actual defect.
- check-after: 2026-08-24

## Settled

_(nothing yet)_
