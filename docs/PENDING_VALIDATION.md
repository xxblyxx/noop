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

### The sync-rescore-storm fix reduces re-score CPU and Commit 5's BGProcessingTask actually fires
- id: sync-rescore-storm-fix
- shipped: `fix/sync-rescore-storm` branch, commits `59771a02`..`08a7824f` (#1005-STORM), 2026-08-23
  — pending merge to `main`. **Update 2026-08-24**: `/code-review med` against the branch's diff
  returned 8 confirmed findings, several of them in the exact mechanisms this entry's claim depends
  on — fixed in 6 follow-up commits on the same branch (not yet hashed at the time of this edit; see
  `docs/superpowers/plans/2026-08-23-sync-rescore-storm.md`'s "Corrections made during implementation"
  for the list). Two of the eight meant the progress bar itself could not be trusted on any prior
  device observation:
  - the offload fraction formula divided by the wrong denominator and pinned near
    `offloadWeight` (70%) within seconds of every burst starting, instead of sweeping — so any earlier
    on-device look at "does the bar move smoothly" was watching a bug, not the real behavior;
  - a fast disconnect could re-arm the bar's `.offload` phase on an already-dead session (a queued
    anchor `Task` landing after the disconnect's synchronous `finish()`), and a stale
    `consecutiveAutoContinues` could silently disable the bar's anchor for the next backfill on the
    same connection — so the bar may not have appeared at all on some prior syncs, for reasons
    unrelated to CPU/overlap.
  Also fixed: a reentrancy gap in `refreshAfterCompletedBackfill` that could hide the bar mid-analyze,
  the 120s backfill-wait cap proceeding and hiding the bar even when a backfill was still genuinely
  running, `analyzeRecent`'s background pass having no real cancellation checks (so a
  `BGProcessingTask` expiration didn't actually stop the work), and `analyzeIfStale()` under-reporting
  `scored=false` after a transient `hrFingerprint()` read failure even when a full pass had run.
- claim: the eleven commits together turn the measured re-score storm (10 passes / 21.5 min of
  re-score CPU in a 47-minute window, one 573s pass from a 12x overlap inflation) into ≤2 passes /
  <2 min with no overlapping pass, AND Commit 5's `SyncAnalyzeBackgroundScheduler` fires and scores
  a deferred night when the strap disconnects right after HISTORY_COMPLETE before the foreground
  analyze pass (`refreshAfterCompletedBackfill`) gets to run — AND (added 2026-08-24) the progress bar
  itself sweeps smoothly across the offload phase (not pinned near 70% within seconds), never gets
  stuck or silently re-armed across a disconnect/auto-continue boundary, and never hides itself while
  a backfill is still genuinely in flight.
- needs: a real morning sync against a repopulated store from a live overnight WHOOP offload.
  Confirming Commit 5 specifically needs the narrower case: the strap coming off / going out of
  range right after HISTORY_COMPLETE while NOOP is backgrounded, before its 30s post-offload
  debounce fires. Confirming the progress-bar fixes needs eyes-on during a real sync: watch the bar
  sweep (not jump), watch it survive a strap disconnect/reconnect mid-sync without getting stuck or
  vanishing, and confirm it clears once the analyze pass actually finishes.
- blocked-because: 🟡 **PARTIALLY VALIDATED 2026-08-25 — direction confirmed, targets missed, and
  two halves of the claim remain untested.** First post-fix log pull (window 08:16:09→09:00:32,
  44.4 min, 591 lines). Build identity confirmed: the tail contains `Backfill: strap deferred (a
  rescore is in flight)`, a string introduced by `5478d84f` on this branch and absent on `main`.
  - **Five passes, ~7.9 min of re-score CPU / 44.4 min (18% duty), vs. the 10 passes / 21.5 min /
    47 min (46%) baseline.** A real ~2.5x reduction, well short of the ≤2 passes / <2 min target.
  - ⚠️ **`re-score: done` reports WALL CLOCK, not CPU** (`Date().timeIntervalSince(reScoreStart)`).
    The raw sum was 1217.7 s = 20.3 min, but the 1021.3 s pass spans a ~742 s process suspension —
    `[08:20:47] Reconnecting in 3s (attempt 1)` produced no attempt until `[08:33:09] Connecting`,
    and a 3 s `asyncAfter` taking 12.4 min only happens in a suspended process. Adjusted worst pass
    ≈ 279 s. Every future check of this entry must apply the same correction; the 2026-08-23 573 s
    baseline outlier had two backfills inside it and so was demonstrably awake.
  - **Cause of the miss, confirmed by code reading before the pull:** the original plan's Commit 1
    specified a 15-min minimum interval between FORCED passes, and it was **never implemented** — no
    time-based gate exists in `analyzeRecent`'s entry (`IntelligenceEngine.swift:478-513`) or in
    `refreshAfterCompletedBackfill`. It was not silently dropped: `59771a02`'s commit message defers
    it openly ("Both need more care than the 5h usage window allowed today"), alongside the
    `skipIfUnchanged` whole-store `hrFingerprint()` gate, whose named blocker there is **#1392**, not
    #1196. Only the plan *file*'s corrections section is silent on it. Relatedly, `066d5624` did NOT
    revert a narrowed fingerprint gate — its diff never touches `IntelligenceEngine.swift`; what it
    reverted was the Kotlin `POST_BACKFILL_ANALYZE_DELAY_MS` constant. The narrowing was never
    written at all.
    A pre-pull prediction from the code alone (~6-7 min per 47 min) matched the measurement (~7.9 min
    per 44.4 min), so the mechanism is understood rather than guessed.
  - **What demonstrably works on hardware:** the 30 s debounce coalesced both morning auto-continue
    bursts (3 sessions at 08:45:22/31/32 → one pass; 3 at 08:53:19/25/28 → one pass) — the case the
    evening baseline never exercised; and the `live.analyzing` reverse guard fired for real
    (`[08:33:46] Backfill: strap deferred`).
  - **The `#899-A` re-arm chain is now the visible residue of the storm.** Passes 1→2→3 are one
    causal chain: each post-offload forced call landed while a pass held `computing`, so
    `pendingForcedRescore` re-armed it to run immediately after — 90 s of re-scoring the same 7
    nights, twice, in the 3 minutes after a pass that had just scored them (`dayCache reused=6/21`
    on the third, so not cheap-because-cached).
  - **One residual overlap, small.** Pass 1 was the launch-time cadence-loop pass
    (`AppModel.swift:463-485`, `analyzeRecent(force: false)`), which has no `live.backfilling` check
    — the branch added that guard to `refreshAfterCompletedBackfill` only. It overlapped offloads at
    both ends (the 08:16:11-12 sessions at its start, the 08:33:11 `.connect` session at its finish),
    1-3 s each. Mechanism gap worth closing; not a demonstrated large cost. `BLEManager:3981` defers
    only `.periodic`/`.strap` on `state.analyzing` — `.connect`/`.foreground`/`.manual` never defer,
    by design.
  - **Commit 5: UNTESTED, not failed.** Zero `background analyze:` lines, which `passes-if` below
    already names as the likely outcome. The 08:20:47 disconnect was mid-pass, with work already in
    flight — NOT the narrower target case (disconnect right after HISTORY_COMPLETE, before the 30 s
    debounce fires). ~40 min unplugged is also well inside normal discretionary `BGProcessingTask`
    latency.
  - ⚠️ **2026-08-25, later the same day: the rescore-floor commits (`0f45525e`..`bd03d1e3`) were built
    and installed to device `819D37A3` via `xcrun devicectl device install app` — an UPGRADE install
    over the existing `com.bly.noop`, NOT a fresh uninstall+reinstall.** The original plan's Commit 5
    text says plainly: "a `UIBackgroundModes` change does not take effect on an upgrade install from
    Xcode in all cases; reinstall to be sure." The owner declined a fresh uninstall on 2026-08-25 to
    avoid losing the on-device store (no cloud sync, no `.noopbak` backup taken first) — a reasonable
    call, but it means Commit 5's `processing` background mode / `BGTaskSchedulerPermittedIdentifiers`
    entry may not have actually re-registered with iOS on this device since it first shipped
    (`3f434482`, 2026-08-23), independent of anything the rescore-floor commits changed. **So a
    continued absence of `background analyze:` lines in a future pull is now AMBIGUOUS between two
    causes**: (a) the likely, expected outcome already documented below (opportunistic scheduling,
    foreground usually beats it to the punch), or (b) the entitlement/background-mode registration
    genuinely never took hold on this install. This check cannot tell those apart by itself — if it
    stays quiet past a few real mornings, the next step is a fresh uninstall+reinstall (with a
    `.noopbak` export taken first) specifically to rule out (b), not another log pull on the same
    install.
  - **Progress bar: UNTESTED.** That half is observational only and no log or store pull can answer
    it; nobody was watching Today during this window.
  - **Coverage limit:** `strapLog.generations` held only three short sessions from 08:13-08:15, so
    the overnight backlog offload may have occurred in a rolled-away session. The 08:33 session
    persisted 3,234 rows across 1 night — real, but plausibly the tail of a morning sync rather than
    the sync itself. This measured a morning window, not necessarily the worst one.
  - Follow-up fix plan requested the same day; the floor, the re-arm chain, the cadence-loop guard
    and the unrepaired `hrFingerprint()` gate are its scope.
- check:
  ```
  xcrun devicectl device copy from --device 819D37A3-B45A-56CF-9FEC-40D460EC74F8 \
    --domain-type appDataContainer --domain-identifier com.bly.noop \
    --source "Library/Preferences/com.bly.noop.plist" --destination /tmp/prefs.plist
  ```
  then in `strapLog.tail`: count `re-score: done` lines and sum their durations per sync window, and
  separately grep for `background analyze:` (Commit 5's own log tag, added specifically so this
  check can tell "never fired" apart from "fired and no-opped") to see whether/how often the
  BGProcessingTask ran. For the progress bar: eyes-on during a live sync (no store pull can tell you
  whether the bar visually swept or jumped — this half of the check is observational, not a log grep).
- passes-if: | metric | baseline (2026-08-23, evening) | target | measured (2026-08-25, morning) |
  |---|---|---|---|
  | re-score passes per ~45 min | 10 | ≤ 2 | 5 ❌ |
  | total re-score CPU per ~45 min | 21.5 min | < 2 min | ~7.9 min ❌ (20.3 min wall) |
  | passes overlapping a backfill | 1 (573 s) | **0** | 1 ❌ (1-3 s, cadence-loop pass) |
  | worst single pass | 573 s | ≤ 60 s | ~279 s ❌ (1021 s wall) |

  ⚠️ The wall/CPU distinction in the fourth column is not optional bookkeeping — see
  `blocked-because`. Subtract any process suspension inside a pass's span before comparing it to the
  ≤ 60 s target, or the number is meaningless.

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

  For the progress bar (added 2026-08-24): the bar sweeps visibly during the offload phase rather
  than jumping straight to ~70%; it never sits stuck at a stale fraction after a disconnect/reconnect
  mid-sync; it never vanishes while a backfill is still genuinely running. Any of those failing is
  evidence the epoch guard, entry gating, or reentrancy fix has its own bug.
- check-after: 2026-08-28
  (bumped from 2026-08-25 after the partial check recorded in `blocked-because`. What is still
  owed: the CPU/pass-count half re-measured once the follow-up floor fix lands; one eyes-on morning
  sync for the progress bar; and Commit 5's narrower disconnect-right-after-HISTORY_COMPLETE case.
  The entry stays Open until all three are answered — the 2026-08-25 pull settles none of them.)

## Settled

- **rr-historical-authority** (2026-08-25): duplicate R-R ingest fix (#1451) confirmed against a
  genuine qualifying night (2026-08-24→25, phone connected throughout bar one 61s BLE gap, on-device
  build 227 postdates the fix). Stored ÷ claimed `Σ rr_count` = 1.0022 (was 1.988 pre-fix), 1 of
  30,144 seconds with a duplicated `ord` (0.0033%, at the tail — not the 85–93%-per-half-hour bug
  pattern), no over-deletion (51 of 3,856 zero-claim seconds still hold live rows). Passes-if met.
