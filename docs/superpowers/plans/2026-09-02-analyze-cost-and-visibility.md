# Make the analyze pass cheap enough to finish, and show when scoring is pending

## Context

On 2026-09-02 the iOS Sleep screen showed **"Woke 1:48 AM"** for a night the owner slept straight
through. It was not a mis-detection: 1:48 was the edge of *scored* data, rendered as a finished
result with nothing on screen to say more work was pending.

Everything below was measured on the owner's iPhone (iOS 26.6.1, NOOP 10.1.1 build 227, WHOOP 5.0)
on 2026-09-02.

### The data was fine; only scoring was behind

| Key | Value |
|---|---|
| `noop.analyzeWatermark` | **01:49:11** — unchanged across pulls at 08:24 and 08:27 |
| `noop.analyze.lastPassEndedAt` | **01:52:43** — no pass had completed in 6.5 h |
| `noop.analyze.bg.lastFireAt` | 01:56:05 (`fireCount` 7, `expireCount` 1) |
| `noop.analyze.bg.lastSubmitAt` / `lastSubmitOK` | 08:23:29 / `true` — queued, never fired |
| `lastSyncedAt` | 08:23:29 → 08:27:09 — offload *was* current |

The displayed wake (01:48) is the watermark (01:49:11). The 08:21:46 offload round logged
`reached the end of available history (trim=0xFFFFFFFF)` — the strap had handed over everything.

### Root cause: iOS kills the pass for CPU

From `--domain-type systemCrashLogs`, `NOOP Staging.cpu_resource_fatal-2026-09-01-172845.ips`:

```
Event:            cpu usage
Action taken:     Process killed
CPU:              48 seconds cpu time over 48 seconds (100% cpu average),
                  exceeding limit of 80% cpu over 60 seconds
CPU limit:        48s      Limit duration:  60s
Footprint:        91.48 MB
Primary state:    Non-Frontmost App, Effective Thread QoS Background, e-core
```

**15 fatal CPU kills** across 2026-08-31 and 2026-09-01 — the 09-01 01:17–01:39 cluster is the
night that produced the earlier truncated-wake report in `docs/PENDING_VALIDATION.md:247`. Not
memory: 91 MB footprint, and in `JetsamEvent-2026-09-02-061823.ips` NOOP appears only as a
bystander with no kill reason. Not suspension either: `strapLog.generations` rolled seven times in
13 minutes (08:14–08:27), and only a fresh launch rolls a generation.

| | CPU budget | Result |
|---|---|---|
| Background | **80% over 60 s ≈ 48 s CPU** | process killed |
| Foreground | 80% over 180 s ≈ 144 s | `Action taken: none` — warning only |

### `prep` is one day's store reads, and it alone blows the budget

Three foreground passes, run back to back:

```
1  reused=0/15    prep=66673ms  score=259177ms   done in 369476 ms
2  reused=0/15    prep=61873ms  score= 57400ms   done in 154507 ms
3  reused=14/15   prep=71603ms  score= 17906ms   done in 127525 ms
```

`score` collapsed 259 s → 18 s as the cache warmed. **`prep` did not move.** On pass 3,
`reused=14/15` plus `skipHits=6` covers all 21 day slots, so exactly **one** day reached `tPrep0`
(`IntelligenceEngine.swift:1055`; cache hits `continue` above it at `:1045` and contribute nothing).

So `prep` ≈ **71 s for a single day's store reads** — `store.hrSamples(… limit: 200_000)` plus rr,
resp, gravity, steps, dayHr, daySteps over a ~54 h window (`IntelligenceEngine.swift:1056`+). One
day already exceeds the entire 48 s background budget, which is why no background pass has ever
reached the scoring phase.

Two hypotheses now dead, recorded so they are not re-tried: the `dayCache DROPPED — sig changed:
habitualMidsleepSec` churn was **one-time** (the cache held on pass 3; the signature is already
quantized to 300 s, `AnalyzeRecentConfigSignatureTests.swift:35`), and `SleepStager` is **correct
and self-healing** — `MetricsCache.upsertSleepSessions` re-upserts `endTs` on a matching onset, so
a truncated wake heals on the next complete pass. Nothing in the scorer needs fixing.

### The owner's routine constrains the fix

The owner unplugs the phone on waking, often while still in bed. **The morning pass therefore runs
on battery**, which rules out leaning on `requiresExternalPower` as the primary fix.

### Why nothing on screen said so

- `SleepView.swift` never references `intelligence.computing`, `live.analyzing`, or `syncProgress`.
  It renders `sleepSession.endTs` (`SleepModel.swift:98` → `SleepView.swift:1008`) with no
  pending/stale concept anywhere.
- `SyncProgressBar` (`Strand/Screens/SyncProgressBar.swift:14`) renders only on Today
  (`LiquidTodayView.swift:297`, `TodayView.swift:1301`), and its `.analyze` phase is claimed only by
  `refreshAfterCompletedBackfill` (`AppModel.swift:827`) when the 900 s floor allows. The idle-tick
  pass that actually ran never touches it.
- `runBackgroundAnalyze` (`AppModel.swift:704`) shows nothing by definition.
- The only surface reading `computing` is `IntelligenceView.swift:39`.

## Goal

1. **Cost** — make the pass cheap enough to finish in a background wake, on battery.
2. **Visibility** — when scoring is pending or running, the Sleep screen says so instead of
   rendering the edge of scored data as a finished wake time.

Target end state, on battery: strap reconnects → BLE wake offloads and stores → a warm cache leaves
one day to score → done in seconds, inside budget, without the owner opening the app.

## Prior art (researched 2026-09-02; sources at the end)

- **`requiresExternalPower = true`** is the community's escape hatch — the CPU monitor is reported
  suppressed for a `BGProcessingTask` on external power.
  `StrandiOS/System/SyncAnalyzeBackgroundScheduler.swift:80` currently hardcodes `false`. ⚠️ This is
  community-reported, **not** in Apple's docs, and it cannot cover the unplugged morning. Useful
  overnight, not the fix.
- **`BGContinuedProcessingTask`** (new in iOS 26; this device runs 26.6.1) — for user-initiated long
  work that must survive backgrounding, and **the system supplies the progress UI** with a cancel.
  Needs an explicit user action, a genuinely advancing `progress`, an `expirationHandler`, and
  `setTaskCompleted(success:)`. Forum thread 801126 ("broken on the iOS 26 release") was a
  beta→release identifier mismatch, resolved.
- **Duty-cycling** (interleaved `Thread.sleep`, reported to take a loop from >100% to ~30% CPU) is a
  mitigation, not a design.
- **Apple DTS:** *"The limits the system has defined should NOT be treated as the acceptable limit
  you can/should grow toward, but as a hard limit that your app shouldn't be getting anywhere
  near."* So the goal is not "fit 369 s into 48 s" — it is to do no heavy work on a BLE wake at all.

**Also:** the crash report shows `Low Power Mode: Enabled`. Per the owner this was iOS 26's
**Adaptive Power**, disabled 2026-09-02 — so post-fix numbers are not directly comparable to the
08-31/09-01 baseline.

## Branch

`fix/analyze-cost-and-visibility` off `main` (per `CLAUDE.md` §git branching). Merge back with
`git merge --ff-only`, delete the branch, **no push**.

## Status — 2026-09-02 (session 01RctuTSfspe25K3cC5JBg8V)

Branch `fix/analyze-cost-and-visibility`, **not merged** — the remaining commits each need the
device loop this plan calls for.

| # | commit | state |
|---|---|---|
| 1 | `f95febff` docs(pending-validation) — record the pull, falsify claim (e) | ✅ done |
| 2 | `d4225454` perf(analyze) — **three-way `prep` split instrumentation**, NOT the fix itself | ✅ instrumentation only; real fix waits on the next device pull to read `prep-split hrRead=… otherReads=… match=…` |
| 3 | `8eda1a36` fix(analyze) — no heavy pass on a background CoreBluetooth wake | ✅ done — the structural fix; `AppModel.isRunningInBackground` gates `refreshAfterCompletedBackfill` + the launch cadence loop |
| 4 | `30628581` feat(sleep) — `sleepScoringBanner` while `intelligence.computing` | ✅ done — also covers the edit/delete/nap re-scores |
| 5 | `BGContinuedProcessingTask` on-battery backstop | ⏸ deferred — new iOS 26 API, needs an Info.plist identifier + a device build to test; can't validate this session |
| 6 | `requiresExternalPower` extra overnight request | ⏸ deferred — untested scheduling-policy change; a wrong `true` constraint would *reduce* background scoring. Verify on device before writing |
| 7 | checkpoint `dayScanCache` per day | ⏸ deferred — hottest file in the repo + Kotlin twin (`AnalyzeRecentDayCache`); needs a real interrupted pass to validate resume |

All four landed commits build clean on macOS **and** iOS (`NOOPiOS` scheme); `doc_comment_lint`
and `i18n_audit --ci` pass. Off-device SQL profiling of one day's 54 h window: **<120 ms** — so the
71 s `prep` is GRDB row materialisation or the pure-Swift matching, not SQLite. Confirmed dead
ends: the `(deviceId, ts)` autoindex exists on every hot table; `skinTempFamily` resolves `.whoop5`
for this owner so the window-wide skin-anchor read is already skipped.

**Next session, in order:**
1. Pull the plist after a morning sync on the build carrying commit 2; read the `prep-split` line.
2. If `hrRead` dominates → narrow the `from = dayStart - 30h` / `to = nextMidnight` window
   (`IntelligenceEngine.swift:973-975`). Start with the *cheap* cut the advisor flagged: drop `to`
   to `dayStart + 18h` for past days (matches what `sleepReadWindowEnd` already caps today at) —
   54 h → 48 h, no stager-visible change for any night ending before 6 PM, no validation entry.
   A full 24 h window IS a physiological-signal change: `docs/CONTRIBUTING.md` §"Derive a
   physiological signal", Kotlin twin same commit, new `docs/PENDING_VALIDATION.md` entry.
3. If `match` dominates → look at `bandSleepStateSamples` fallback / `daySliceFromNight` / the
   `providedSleep` read, not the window.
4. Then commits 7, 5, 6 with a device in the loop.

**Verification bar (unchanged):** zero new `NOOP*.cpu_resource*` reports after an overnight with the
strap worn and the phone unplugged on waking. Baseline **15** (2026-08-31/09-01). The "under 48 s"
figure below is the *plain background* budget; a `BGProcessingTask` window differs — do not treat it
as the acceptance bar.

## Commits

One concern each, in this order.

1. **`docs/PENDING_VALIDATION.md`** — docs-only, lands first, independent of the rest. Record
   against the open `sync-rescore-storm-fix` entry: BG re-arm confirmed working
   (`lastSubmitOK = true`, `fireCount = 7`, `expireCount = 1`); no pass completed in 6.5 h; the
   analyze-phase progress bar never appeared (its `.analyze` phase is only reachable from
   `refreshAfterCompletedBackfill`, which never ran); and the headline finding — **15
   `cpu_resource_fatal` kills against an 80% CPU / 60 s background limit, with one day's `prep`
   at ~71 s.**

2. **Cut `prep`.** The load-bearing commit. Profile the per-day reads at
   `IntelligenceEngine.swift:1056`+ against `Packages/WhoopStore` — 35 k rows should not cost 70 s,
   so suspect a missing index, an over-wide window (~54 h), or reading columns the scorer discards.
   Testable off-device with `swift test`, no strap needed. **Target: warm one-day pass under 10 s.**
   Land the measurement in the commit message.

3. **Do no heavy work on a BLE state-restoration wake.** That path gets plain background limits and
   no relief. It should persist what it offloaded, arm the background task, and return
   (`AppModel.refreshAfterCompletedBackfill:732`, idle tick at `:534`). This is the discipline
   change that stops the 15-kill pattern at its source.

4. **Sleep screen shows pending/running scoring.** Bind to `intelligence.computing`
   (`IntelligenceEngine.swift:27`) the way `IntelligenceView.swift:39` already does, and show
   "scored through HH:MM" when the watermark is behind available data, so a data-edge wake reads as
   pending rather than final (`SleepView.swift:1008`, `SleepModel.swift:98`). Also cover the
   currently-silent Sleep-screen re-scores (`SleepView.swift:230` edit, `:240` delete, `:263` nap).
   Design tokens only — `StrandPalette` / `StrandFont` / `NoopMetrics`.

5. **`BGContinuedProcessingTask` as the on-battery backstop.** Covers "I unplugged and opened NOOP
   in bed": a user-started pass keeps running with the OS's own progress UI after the phone goes
   down. Register a fresh identifier; test on a clean install.

6. **`requiresExternalPower = true` on an additional overnight request**, keeping the existing
   unplugged one — `SyncAnalyzeBackgroundScheduler.submit:78-85`. A bonus: it warms the cache
   overnight on the charger so the morning has only one day left. Verify on device rather than
   trusting the community claim.

7. **Checkpoint `dayScanCache` per day** so an interrupted pass accumulates instead of restarting —
   today a killed pass contributes nothing (the 08:22 pass did real work and threw it all away).

Commits 2–7 are Swift-only: no schema change, no migration, and per `docs/CROSS_PLATFORM.md` no
Kotlin twin is owed unless one of them changes a formula or a stored value. If that happens, the
twin ships in the same commit and the message must say "Kotlin twin written but not compiled
locally" (`CLAUDE.md` §"The two traps").

## Files

- `Strand/Data/IntelligenceEngine.swift` — `:1045`/`:1055` the prep boundary and cache `continue`s,
  `:1056`+ the per-day reads, `:27` `@Published computing`, `:516` `analyzeRecent`, `:2466` the
  `re-score: done` line
- `Packages/WhoopStore/Sources/WhoopStore/` — the read paths behind `hrSamples` et al., and any
  index added for commit 2
- `Strand/App/AppModel.swift` — `:534` idle tick, `:704` `runBackgroundAnalyze`, `:732`
  `refreshAfterCompletedBackfill`
- `Strand/Screens/SleepView.swift`, `Strand/Screens/SleepModel.swift`
- `StrandiOS/System/SyncAnalyzeBackgroundScheduler.swift` — `:78-85` the request, plus the new
  `BGContinuedProcessingTask` registration
- `docs/PENDING_VALIDATION.md`

## Verification

- `cd Packages/WhoopStore && swift test` and `cd Packages/StrandAnalytics && swift test` — green;
  add a read-cost regression test for commit 2.
- App targets are **not** covered by CI (`CLAUDE.md` §"The two traps") — build by hand:
  `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
- **Commit 2's number:** compare `analyzeRecent cost prep=` on the same device and history.
  Baseline `prep=71603ms` for one day (2026-09-02). Target under 10 s; anything over 48 s has not
  fixed the problem.
- **The real end-to-end test:** strap worn overnight, phone unplugged on waking as usual, and
  **without foregrounding the app** confirm in the morning that `noop.analyzeWatermark` has advanced
  past the night and `re-score: done` is in `strapLog.tail`.
- **The acceptance criterion:** no new CPU kills.
  ```
  xcrun devicectl device info files --device 819D37A3-B45A-56CF-9FEC-40D460EC74F8 \
    --domain-type systemCrashLogs --json-output crashlist.json
  ```
  then filter for `NOOP*.cpu_resource*`. Baseline to beat: **15** over 08-31 and 09-01. Zero new
  ones is the bar.

## Deliberately not doing

- **A `provisional` column on `sleepSession`.** Compelling only while the bad number looked
  self-sustaining. It isn't — the scorer self-heals — so a schema change plus migration plus Kotlin
  twin is not earned for information that `intelligence.computing` plus "the watermark is behind"
  already carries. On the shelf; revisit only if the pending state genuinely needs persistence.
- **Changing what feeds `habitualMidsleepSec`.** The churn was one-time, not a loop.
- **The auto-continue re-kick.** Every offload round ended with `Backfill: auto-continuing
  (#364/#451)`, frontier climbing as the worn strap advanced the trim. Worth *measuring* later
  whether `live.backfilling` ever settles (and so whether `refreshAfterCompletedBackfill` keeps
  hitting its 120 s give-up at `:775-778`) — but do not change it on suspicion.

## Workaround, confirmed working today

More → Insights → **Intelligence** → **Recompute** (toolbar), kept in the foreground until the
"Crunching your raw streams…" card clears (`IntelligenceView.swift:39`). Verified end-to-end on
2026-09-02: the watermark advanced 01:49:11 → 08:37:20 and the night scored as **549 min (9h09m)**,
`source=computed`.

## Sources (researched 2026-09-02)

- [BGProcessingTaskRequest gets killed due to high cpu usage](https://developer.apple.com/forums/thread/690666) — the `requiresExternalPower` finding
- [About cpu_resource_fatal](https://developer.apple.com/forums/thread/758387) — Apple DTS on treating limits as a ceiling to stay far below
- [Finish tasks in the background — WWDC25 §227](https://developer.apple.com/videos/play/wwdc2025/227/) — `BGContinuedProcessingTask`, system progress UI
- [BGContinuedProcessingTask does not work on the official release of iOS 26](https://developer.apple.com/forums/thread/801126) — the identifier-mismatch scare, resolved
- [Solving CPU Usage Crashes with Xcode's Energy Organizer](https://swiftrocks.com/debug-cpu-exceptions-xcode-energy-reports) — reading `cpu_resource` reports
- [Energy Efficiency Guide for iOS Apps: Work Less in the Background](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/WorkLessInTheBackground.html)
- [Core Bluetooth Background Processing for iOS Apps](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)
