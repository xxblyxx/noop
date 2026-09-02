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
- **2026-09-01 update: two more commits landed on `fix/analyze-pass-cost`, extending this entry with
  two new claims rather than opening a parallel one (they'll be read from the same device log).**
  Root cause of the 2026-09-01 report (wake time truncated to ~00:51, corrected only on foreground
  open): the last analyze pass before noon ended at 00:53:55 over data ending 00:52:51 — `SleepStager`
  honestly reported the last available sample as wake — and then no analyze pass ran for the next 12
  hours despite other background work (a folder backup, the `.healthwriteback` BGTask) running fine in
  that window. Two commits address the two halves:
  - **claim (d) — `9e273316` (perf(analyze): stop the pass signature churning…):** on a morning with a
    real sync, no `analyzeRecent dayCache DROPPED — sig changed: sleepConsistency` line, and `reused=`
    reads near-total for nights unchanged since the previous pass. *Misread guard:* a drop naming only
    `habitualMidsleepSec` is CORRECT and expected the first time `habitualMidsleepSec` moves from nil
    to a value (cold-start crossing `habitualMinDays`) — do not read that alone as a regression.
  - **claim (f) — `a102372f` (fix(analyze): never evict the computed window from a cancelled pass):**
    a pass cut short by a `BGProcessingTask` expiration leaves the computed window intact rather than
    deleting every day older than the ones it reached. Cannot be forced on demand; only observable if
    `noop.analyze.bg.expireCount` (added in `c785e90d`) ever increments — until the background re-arm
    fix (Commit 5, not yet shipped as of this edit) actually gets a pass running in a window that can
    expire, this has essentially never had the chance to fire, which is exactly why the bug it fixes
    survived undetected.
  - **Flagged, not a claim:** the personalized sleep need + regularity (`IntelligenceEngine.swift:727`
    area) are computed every pass and then discarded — they never reach a displayed number. If a future
    change wires them into `Rest.composite(daily:)`'s `daily:` call sites, claim (d)'s conditional
    signature fold must be revisited (see `9e273316`'s message and
    `RestCompositeDailyDefaultsTests.swift`, which fails loudly if that happens).
  - **claim (e) — `a0fe2398` (fix(background): re-arm the analyze background task…), the overnight
    claim this whole update exists to eventually settle:** `noop.analyze.bg.fireCount` (added in
    `c785e90d`) increments at least once between roughly 01:00 and 08:00 local on a night with a real
    overnight offload, and `noop.analyze.bg.lastOutcome` reads `scored` on the morning after such a
    night — i.e. the strap's overnight data is scored WITHOUT the app being foregrounded. This is the
    direct fix for the 2026-09-01 report and the reason this update exists. Falsifiers each read
    differently: `noop.analyze.bg.lastSubmitOK == false` with a `lastSubmitError` naming
    `.notPermitted` ⇒ the `processing` background mode / `.analyze` task identifier never took effect
    on this install (`project.yml` already warns an upgrade install may not pick it up) — needs a
    delete-and-fresh-install, NOT a further code change; `fireCount` flat across the night with
    `lastSubmitOK == true` ⇒ iOS is declining to run BGProcessing on this device/charging state, a
    scheduling-policy finding distinct from a code bug; `lastOutcome == expired` ⇒ the pass still
    doesn't fit inside whatever wall-clock budget iOS grants a `BGProcessingTask` here, and Half B
    (claims (d)/(f)) needs to go further before this can pass.
- claim-set status as of `a0fe2398` (2026-09-01): (d) and (f) are shipped and awaiting their first real
  morning; (e) additionally needs the phone genuinely backgrounded overnight with the strap in range for
  at least one real offload. Pull the plist per `check` below and read BOTH the `strapLog.tail`
  `analyzeRecent` lines AND the `noop.analyze.bg.*` keys (a debug export's "Background analyze" block —
  new in `c785e90d` — carries the same numbers if a devicectl pull isn't convenient) in the same session;
  a partial answer (only one of the two readable) is not enough to close any of (d)/(e)/(f).
- **2026-09-02 update — device pull done (iPhone `819D37A3`, iOS 26.6.1, NOOP 10.1.1 build 227, WHOOP
  5.0). Claim (e) FALSIFIED for the reason none of its three listed falsifiers named; a new fix branch
  (`fix/analyze-cost-and-visibility`) is in flight.** Two `com.bly.noop.plist` pulls (08:24, 08:27)
  plus three foreground Recompute passes, plus `--domain-type systemCrashLogs`.
  - **Offload was current, scoring was 6.5 h behind.** `noop.analyzeWatermark` = 01:49:11 (unchanged
    between pulls); `noop.analyze.lastPassEndedAt` = 01:52:43; `lastSyncedAt` advanced 08:23:29 →
    08:27:09. The 08:21:46 backfill round logged `reached the end of available history
    (trim=0xFFFFFFFF)` — the strap had handed everything over. The Sleep screen's "Woke 1:48 AM" was
    the watermark, not a detected awakening; the owner slept through.
  - **Claim (e) — the overnight BGProcessingTask DID fire and was KILLED, not deferred.**
    `noop.analyze.bg.fireCount` = 7, `lastFireAt` = **01:56:05** — so iOS is not "declining to run
    BGProcessing" (falsifier 2 does not apply), and `lastSubmitOK` = true with no `lastSubmitError`
    (falsifier 1 does not apply — no fresh install needed on that account). But `lastOutcome` was still
    `scored` from `lastOutcomeAt` = 2026-09-01 **23:25:56** (the evening before), and
    `lastPassEndedAt` (01:52:43) predates `lastFireAt` (01:56:05): the 01:56 pass started and recorded
    no outcome at all — not even `.expired`. The crash logs say why:
  - **iOS killed the pass for CPU. 15 × `cpu_resource_fatal` on 2026-08-31 and 2026-09-01.** Sample
    (`NOOP Staging.cpu_resource_fatal-2026-09-01-172845.ips`): `Action taken: Process killed` /
    `48 seconds cpu time over 48 seconds (100% cpu average), exceeding limit of 80% cpu over 60
    seconds` / `Footprint: 91.48 MB` / `Non-Frontmost App, Thread QoS Background, e-core`. The
    09-01 01:17–01:39 cluster is the night behind the 2026-09-01 truncated-wake report this update
    chain exists for. Memory is ruled out (91 MB; in `JetsamEvent-2026-09-02-061823.ips` NOOP is a
    bystander with no kill reason). So (e)'s third falsifier is the closest — "the pass still doesn't
    fit inside whatever budget iOS grants" — but it is the **CPU** budget (80% / 60 s ≈ 48 s), not a
    wall-clock one, and the process is SIGKILLed rather than expired.
  - **Half B (d)/(f): `prep` alone exceeds the background CPU budget.** Three back-to-back foreground
    passes: `prep=66673ms score=259177ms` → `prep=61873ms score=57400ms` → `reused=14/15
    prep=71603ms score=17906ms`. `score` fell 259 s → 18 s as the cache warmed; **`prep` did not
    move.** On pass 3, `reused=14/15` + `skipHits=6` accounts for all 21 day slots, so exactly one
    day reached `tPrep0` (`IntelligenceEngine.swift:1055`) — i.e. ~71 s is **one day's store reads**
    (`hrSamples` + rr/resp/gravity/steps over a ~54 h window). One day already blows the 48 s
    background budget, which is why no background pass has ever reached the scoring phase. Claim (d)'s
    signature-churn concern checks out fine: `dayCache DROPPED — sig changed: habitualMidsleepSec`
    fired once (cold `habitualMidsleepSec` moving off nil, exactly the "misread guard" case) and the
    cache then held on pass 3 — not a loop.
  - **`SleepStager` is correct and self-healing** — the foreground Recompute advanced the watermark
    01:49:11 → 08:37:20 and re-scored the night as 549 min (9h09m), `source=computed`, via
    `MetricsCache.upsertSleepSessions`' `ON CONFLICT(endTs)`. Nothing in the stager needs a fix; the
    2026-09-01 root-cause paragraph above still stands as written.
  - **Progress bar: still UNTESTED.** Its `.analyze` phase is only reachable from
    `refreshAfterCompletedBackfill`, which did not run during any observed sync this morning — the
    idle-tick pass that ran never touches `syncProgress`. Nobody was watching Today. Unchanged from
    2026-08-25.
  - **Confound noted:** the crash reports show `Low Power Mode: Enabled` — per the owner this was iOS
    26's Adaptive Power, disabled 2026-09-02. Post-fix CPU/scheduling numbers are not directly
    comparable to this baseline.
  - **Next:** `fix/analyze-cost-and-visibility` — cut `prep` below the budget (load-bearing), stop
    doing heavy work on a BLE state-restoration wake, surface pending scoring on the Sleep screen, add
    a `BGContinuedProcessingTask` on-battery backstop, and set `requiresExternalPower` on an extra
    overnight request. Acceptance: zero new `NOOP*.cpu_resource*` reports (baseline **15**) after an
    overnight with the strap worn and the phone unplugged on waking as usual. Plan:
    `~/.claude/plans/check-my-phone-the-graceful-trinket.md`.
- check-after: 2026-09-16
  (bumped from 2026-09-02 — that date's pull is the "2026-09-02 update" above: it answered claim (e)
  in the negative and redirected the work to `fix/analyze-cost-and-visibility`. Re-check once that
  branch has shipped and survived one real overnight.
  Earlier note, still in force: bumped 2026-08-28 → 2026-09-02 with no new device pull recorded against the original
  three items below. What is still owed, unchanged: the CPU/pass-count half re-measured once the
  follow-up floor fix lands; one eyes-on morning sync for the progress bar; and the narrower
  disconnect-right-after-HISTORY_COMPLETE case for the ORIGINAL Commit 5 of this branch's first plan
  (`5478d84f` era — not to be confused with `a0fe2398`, the 2026-09-01 re-arm fix, a different Commit 5
  from a different, later plan). The entry stays Open until all three are answered. Now ALSO covers
  claims (d)/(e)/(f) above — (d)/(f) need only a real morning sync to check; (e) needs that sync to have
  genuinely happened overnight/backgrounded, which the original three items don't require quite as
  strictly. Requires a fresh install per the `a0fe2398` message if claim (e) reads `lastSubmitOK ==
  false` — do not re-check on the same install a second time expecting a different answer.)

### The analyze-pass-cost diagnostics are readable on a real morning, and the #1575 port didn't break trace replay
- id: analyze-pass-cost-instrumentation
- shipped: `fix/analyze-pass-cost` 2026-08-26 — `4104608d` (Commit 1: `analyzeRecent cost prep=/score=`,
  ported from upstream #1559; the honest `reused/(reused+cacheable)` denominator from upstream #1556;
  and our own `analyzeRecent dayCache DROPPED — sig changed:` plus `eligible=`/`ownerFamilyNil=`) and
  `a2eac10d` (Commit 1b: port of upstream #1575 — `dayCacheEligible = true`, and `hrvWindowDetail` added
  to `AnalyzeRecentDayCache.cacheKey`). Plan: `docs/superpowers/plans/2026-08-26-analyze-pass-cost.md`.
  Built and installed to device `819D37A3` 2026-08-26 09:46 (upgrade install, same caveat as the
  sibling entry above).
- claim: **Two claims, neither of them a speedup — do not read this entry as "the perf fix is pending."**
  Commits 1 and 1b make the pass *measurable* and remove a latent trap; they make it no faster, and the
  morning is expected to feel exactly as slow as it did on 2026-08-26.
  (a) The three new diagnostic lines appear on every completed pass, pair up with `re-score: done`, and
  are DECISIVE — i.e. they actually distinguish a pass-signature drop from per-day eligibility, which is
  the ambiguity that made the 2026-08-26 investigation rest on inference.
  (b) With a Test Centre trace active, a reused night now emits the same trace lines as a freshly-scored
  one (the Swift replay path at `IntelligenceEngine.swift:1407/1410/1413` covers `.sleep`/`.hrv`/
  `.steps`), and the `hrvWindowDetail` key component invalidates exactly one day at local midnight.
- needs: one morning where the app is opened and the launch cadence tick runs a full pass — plus, for
  claim (b) ONLY, a separate session with the Sleep or HRV Test Centre trace deliberately switched on
  and left on across a local-midnight rollover.
- blocked-because: **Claim (a)** is only hours old — installed 2026-08-26 09:46, after that morning's
  sync had already happened, so the canonical launch-pass measurement is the NEXT morning. (The
  post-install sync the owner started at ~09:50 the same day may already carry a partial answer: a first
  pass logging `cold process (no previous signature)` and, if a second pass follows, the `sig changed:`
  line that actually matters. Worth grepping opportunistically, but it is not the morning case.)
  **Claim (b) is entirely unobserved and is the larger debt.** No Test Centre trace has ever been active
  on this device (`testcentre.active.workouts = False` is the only such key in the plist, and it is off),
  so the code path Commit 1b now depends on — a cache HIT replaying three trace arrays — has never once
  run. The package tests pin the key's invalidation contract, not the replay. Nobody has seen a traced
  night reused. The owner was advised NOT to turn traces on, because they add log noise and burn the
  2,000-line tail; that advice is right for claim (a) and is exactly what leaves claim (b) unchecked, so
  (b) needs a deliberate, separate session rather than riding along on a normal morning.
  Also: no Kotlin twin was written for either commit and Android keeps the pre-#1575 gate, so the two
  platforms are knowingly out of step here — recorded in `a2eac10d`, not a thing this check can settle.
- check:
  ```
  xcrun devicectl device copy from --device 819D37A3-B45A-56CF-9FEC-40D460EC74F8 \
    --domain-type appDataContainer --domain-identifier com.bly.noop \
    --source "Library/Preferences/com.bly.noop.plist" --destination /tmp/prefs.plist
  python3 - <<'PY'
  import plistlib
  L = plistlib.load(open("/tmp/prefs.plist","rb"))["strapLog.tail"]
  for l in L:
      if any(k in l for k in ("re-score:","dayCache","analyzeRecent cost","analyze: floored")):
          print(l[:200])
  PY
  ```
  ⚠️ The plist key is `strapLog.tail` with a LITERAL DOT — `plutil -extract strapLog.tail` treats it as
  a key path and fails. Use `plistlib`, as above. (The two sibling plans both record the broken command.)
  Retention: 2,000 lines live plus 3 generations × 1,000 (`LiveState.tailLimit`,
  `maxLogGenerations`, `generationTailLimit`) — roughly 2h20m of a connected morning, so pull within a
  few hours of the sync or the launch pass rolls off.
- passes-if:
  **Claim (a) — all four must hold:**
  1. `grep -c 'analyzeRecent cost'` **equals** `grep -c 're-score: done'`. Fewer means a pass exited on a
     path that skips the tally.
  2. The reuse line reads `reused=N/M ... days=21` where **M ≤ 21 and M reflects days with data** (8 on
     this store as of 2026-08-26), not a flat 21. A warm pass should now read something like `7/8`, not
     the misleading `7/21` that already cost one investigation.
  3. The FIRST `DROPPED` line of a process reads `cold process (no previous signature)` — expected and
     uninformative. **The SECOND pass is the one that decides Commit 2.**
  4. `prep` and `score` are both non-zero on a cold pass and both ~0 on a fully-warm one.

  **What the second pass means — decided NOW, before seeing it:**
  - `DROPPED — sig changed:` naming `sleepNeedHours`, `sleepConsistency` and/or `habitualMidsleepSec`
    → Commit 2's premise **holds**; quantize those three as planned.
  - `DROPPED — sig changed:` naming something else → Commit 2 as written is **wrong**; fix whatever it
    names instead and rewrite that commit. Do not ship the quantization because the plan predicted it.
  - **No `DROPPED` line at all, yet `reused=0`** → the drop was never a signature change; read
    `eligible=` and `ownerFamilyNil=` on the reuse line, and Commit 2's premise is **refuted**.
  - No second cold pass at all (the second pass reads `reused=7/8`) → the 2026-08-26 double-cold-pass
    was not reproducible; re-measure before building anything.

  **Commit 4 gate, from the same log:** `prep ≫ score` → build the sliding window; `score ≫ prep` →
  **do not build it**, whatever the row counts suggest. Upstream's prior is 60–84% reads, but that is
  their hardware and their store, and this device's unexplained ~9x-per-night cost gap means the prior
  may not transfer.

  **Claim (b) — a separate traced session:** with the Sleep or HRV trace on, a pass reporting
  `reused=N/M` with N>0 still emits the full per-day trace block for the reused nights (identical in
  content and ordering to a freshly-scored night), and across local midnight exactly ONE day
  re-scores rather than the whole window. A reused night emitting FEWER trace lines than a fresh one is
  the failure this claim exists to catch, and it would mean the gate should not have been flipped.
- result (2026-08-27, log pulled 09:28, 352 lines covering 08:16:04 → 09:27:18):
  **Claim (a): checks 1–3 PASS; check 4 is HALF-observed, so (a) is not settled.**
  1. `analyzeRecent cost` = 2, `re-score: done` = 2. ✅
  2. `reused=0/9 size=9 days=21 eligible=true ownerFamilyNil=0` — M=9, the real count of days with
     data (12 slots log `SKIPPED hrSamples=0`), not a flat 21. ✅ The lines are decisive: `eligible=`
     and `ownerFamilyNil=` positively rule out per-day eligibility, which is exactly the ambiguity the
     2026-08-26 investigation had to argue rather than read.
  3. First `DROPPED` reads `cold process (no previous signature)`. ✅
  4. Cold pass has both `prep` and `score` non-zero. ✅ **"Both ~0 on a fully-warm pass" remains
     UNOBSERVED** — both of this morning's passes were cold (`reused=0/9`), because the very defect
     Commit 2 targets fired between them. It will be observable only after Commit 2 lands.
  **The decisive line: `analyzeRecent dayCache DROPPED — sig changed: sleepNeedHours,sleepConsistency`.**
  Commit 2's premise HOLDS on the pre-committed condition. `habitualMidsleepSec` did not move (it is an
  `Int` of seconds — already quantized), which corroborates the remedy.
  **Commit 4 is REFUTED by its own gate** — prep/score = 0.94 and 1.18, neither term dominant. Do not
  build the sliding window; upstream's 60–84%-reads prior does not transfer to this device.
  **New, unplanned finding — the dominant cost is not the cache at all.** Two cold passes, same 9
  nights, same code: 2403.7 s (08:16–08:56) vs 255.5 s (09:14–09:18) — **9.4× apart**. Store contention
  is ruled out from this same log (`prep` and `score` inflated by nearly equal factors, 11.7× and
  14.6×, and `score` brackets only `AnalyticsEngine.analyzeDay`, which never touches the store).
  Two candidates remain and this log cannot separate them: app being backgrounded (no `HR notify` line
  in pass 1's 40 minutes; `.foreground` fires 08:17:32 then not until 08:56:05) vs progressive thermal
  throttling over 40 minutes of sustained compute. **Neither is asserted.** See the plan's 2026-08-27
  section for the discriminator (log `thermalState` + foreground/background at pass start, per-N-days,
  and pass end). That discriminator gates Commit 5 only.
  **Floor worth knowing:** total − (prep+score) ≈ 50–75 s and roughly constant — the pass-2 fold plus
  banking. A perfect day cache leaves a ~1-minute pass, not a zero-cost one.
- claim (c) — Commit 3, the persisted day-scan cache (`Strand/Data/DayScanCacheStore.swift`;
  `f89aad7e` + `0b1abf23`, built and installed to device `819D37A3` 2026-08-27 10:22, so the first
  morning that can test it is 2026-08-28): the
  on-disk projection is COMPLETE for everything pass 2 reads, and the two invalidation holes closed
  with it actually hold on a real device. Three sub-claims, none observed on hardware:
  (c1) A relaunch reuses nights rather than re-scoring them — the whole point, and the only one a
       normal morning tests.
  (c2) **The #899 banked-sleep heal drops both caches.** The heal deletes banked sleep rows whose only
       route into a later pass is `bandSleepStateSamples`, a pass-1 read NOT in the per-day key. Before
       persistence this healed by accident on relaunch. There is a unit test for the store, but **no
       test and no observation of the heal path itself** — it needs a night where `Dedup(#899): removed
       N` is non-zero, which cannot be forced.
  (c3) **A Test Centre trace toggle drops the cache** rather than replaying stale trace lines from a
       persisted scan. Shares claim (b)'s blocker exactly — no trace has ever been active on this
       device — so (b) and (c3) should be checked in the SAME deliberate traced session.
  **Read the FIRST pass after install correctly:** `LOADED` followed by `sig changed:` naming the three
  sleep fields is CORRECT and costs one cold pass, once — Commit 2 changed how those components are
  encoded, so a cache written by any earlier build has a different signature. It is not a Commit 2
  failure. From the second launch onward, a healthy first pass reads `LOADED 9 day(s) from disk` with no
  `DROPPED` line at all.
  The projection omits 8 of `DayResult`'s 15 fields on the evidence that pass 2 reads none of them
  (`testOmittedFieldsComeBackAtDayResultDefaults` pins the list). If any of those eight ever becomes
  load-bearing in the fold, this cache silently feeds it a default. That is the standing risk.
- check-after: 2026-09-03
  (bumped from 2026-08-27, which is now answered for claim (a) checks 1–3. The entry stays OPEN for
  claim (b) — still entirely unobserved, still needing a deliberate traced session — and for check 4's
  warm half, which cannot be seen until Commit 2 lands. Do not settle this entry on the easy half.
  After Commit 2 (`de041d22`, built and installed to device `819D37A3` 2026-08-27 09:54) the
  falsifiable prediction is: a morning's **second** pass
  reads `reused=9/9` and lands near 75 s.
  **Three ways that check can be misread, settled here in advance:**
  1. **Pass 1 will still be cold, and that is not a failure.** `dayScanCacheConfigSig` starts `""`, so
     the first pass of every process drops the cache by construction. That is Commit 3's job, not
     Commit 2's. Only the SECOND pass tests the quantization.
  2. **No second pass at all = no signal, not a refutation.** Today's second pass existed only because
     a `postOffload` was floored and a later `idle-tick` fired. If the cadence produces one pass, the
     log is quiet on this question — re-check another morning rather than concluding anything.
  3. **A `sig changed:` still naming `sleepConsistency` / `habitualMidsleepSec` may be the `nil` →
     value transition, not quantization failing.** Both are `nil` under `habitualMinDays` of history,
     and this store is right at that edge (9 nights with data, 12 empty slots), so a night crossing the
     threshold legitimately drops the cache once. Correct behaviour, covered by tests. Distinguish it
     by whether the store just gained a night, before blaming the quanta.
  If the quanta genuinely prove too fine, the fix is a coarser quantum or a hysteresis band — the
  known boundary limitation is pinned by `testMidsleepStillInvalidatesAcrossAStepBoundary`.
  **Commit 3 (persisted day-scan cache) ships alongside it and is separately observable in the same
  log** — do not conflate them. Commit 2 shows in the SECOND pass (no `sig changed:` drop); Commit 3
  shows in the FIRST (`dayCache LOADED N day(s) from disk`, then `reused=8/9` instead of a
  `cold process` drop). Expected: pass 1 ~300 s instead of 2403 s. Materially worse than that means
  the background penalty scales with something other than per-night work — a different finding, not a
  failure of this commit. **Commit 3 carries its own unobserved claim (c) below.**)

## Settled

- **rr-historical-authority** (2026-08-25): duplicate R-R ingest fix (#1451) confirmed against a
  genuine qualifying night (2026-08-24→25, phone connected throughout bar one 61s BLE gap, on-device
  build 227 postdates the fix). Stored ÷ claimed `Σ rr_count` = 1.0022 (was 1.988 pre-fix), 1 of
  30,144 seconds with a duplicated `ord` (0.0033%, at the tail — not the 85–93%-per-half-hour bug
  pattern), no over-deletion (51 of 3,856 zero-claim seconds still hold live rows). Passes-if met.
