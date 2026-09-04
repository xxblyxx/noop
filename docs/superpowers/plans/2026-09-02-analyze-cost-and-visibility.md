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
| 4 | `30628581` feat(sleep) — `sleepScoringBanner` while `intelligence.computing`; `c1509b79` localises its string (10 locales) + drops the redundant a11y label | ✅ done — also covers the edit/delete/nap re-scores |
| — | `7e4de371` docs(plans) — this file | ✅ |
| 5 | `BGContinuedProcessingTask` on-battery backstop | ⏸ deferred — new iOS 26 API, needs an Info.plist identifier + a device build to test; can't validate this session |
| 6 | `requiresExternalPower` extra overnight request | ⏸ deferred — untested scheduling-policy change; a wrong `true` constraint would *reduce* background scoring. Verify on device before writing |
| 7 | checkpoint `dayScanCache` per day | ⏸ deferred — hottest file in the repo + Kotlin twin (`AnalyzeRecentDayCache`); needs a real interrupted pass to validate resume |

All landed commits build clean on macOS **and** iOS (`NOOPiOS` scheme); `doc_comment_lint` and
`i18n_audit --ci` pass; package tests green (`StrandAnalytics` 1519, `WhoopStore` 423,
`StrandImport` 232/1 skipped). Off-device SQL profiling of one day's 54 h window: **<120 ms** — so the
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

---

# Phase 2 — scoring must not require the app to stay open

## Context

Phase 1 shipped and was verified on a real overnight (2026-09-03): zero new `cpu_resource_fatal`
kills, the `BGProcessingTask` fired twice and completed cleanly, and a foreground pass correctly
scored a fresh night in ~49 s. But the owner then tested the actual desired UX — open NOOP, poke
around, lock the phone — and it does **not** work: nothing protects a foreground-started pass from
being backgrounded mid-flight, so it either keeps running unchecked into the CPU-metered
"Non-Frontmost" state (the same kill Phase 1 fixed for the BLE-wake path) or stalls if the process
gets suspended first.

**Non-negotiable goal, either outcome acceptable:**
1. User opens NOOP, optionally starts something, then locks the phone or switches away — scoring
   finishes correctly regardless.
2. Scoring runs fully automatically — strap reconnects, offloads, scores — with no app-open at all.

Today satisfies neither: scoring only reliably completes if the app stays foregrounded, unlocked,
until the "Scoring last night from your strap…" banner clears.

## What a device-code audit + fresh research turned up

**A real cache-invalidation bug, found while tracing why `prep` cost 71 s once and 6.5 s another
time — the same day, same app, same code.** `AnalyzeRecentConfigSignature` (assembled in
`IntelligenceEngine.swift:815-856`) folds 17 pass-global inputs into one string; a mismatch against
the previous pass's signature wipes the **entire persisted 21-day `dayScanCache`**
(`noop-dayscan-cache.json`, `Strand/Data/DayScanCacheStore.swift`), forcing every day to re-`prep`
from scratch. Two of those 17 inputs — `baselines1.hrv` and `baselines1.restingHR`
(`IntelligenceEngine.swift:823-824`) — are raw, full-precision floats, unlike `sleepNeedHours`
(quantized to 0.25 h), `sleepConsistency` (0.01), and `habitualMidsleepSec` (300 s) right next to
them. `baselines1` is a trailing fold over the *entire* `dailyMetric` history
(`store.dailyMetrics(... "0000-01-01" ... "9999-12-31")` → `Baselines.foldHistory`); **scoring any
single fresh night moves that fold by some tiny amount, which changes the signature, which wipes the
whole cache on the very next pass.** The code already voices this exact suspicion
(`IntelligenceEngine.swift:884-887`, "a second full cold pass following every launch pass"), and the
diagnostic line to confirm it already exists (`dayCache DROPPED — sig changed: baselines1.hrv`) —
just never checked. This is present **identically** in the Android twin
(`android/app/src/main/java/com/noop/analytics/IntelligenceEngine.kt:547`, same unquantized
`baselines1.hrv.toString()` treatment). Fixing this benefits **both** outcomes: nearly every real
pass becomes "N-1 cached days (near-free) + 1 genuinely new night," not a full 21-day cold pass.

**Partial-credit checkpointing for the `BGProcessingTask` path already exists** and is more mature
than Phase 1 assumed — `SyncAnalyzeBackgroundScheduler`'s `expirationHandler` cancels the worker,
which persists whatever it scored (newest-night-first) to the on-disk day-scan cache
(`IntelligenceEngine.swift:1570-1595`). Two real gaps: (a) `setTaskCompleted` is reported
**synchronously inside the expiration handler**, before the persist at `:1586` — a race against
suspension; (b) a `cpu_resource_fatal` **SIGKILL is not a cancellation** — nothing unwinds or
persists, so this checkpointing only helps the graceful-expiry case, never the actual crash Phase 1
was built around.

**No `beginBackgroundTask` assertion exists anywhere** in the app — confirmed by exhaustive grep.
Nothing extends the OS grace period after backgrounding today, and `isRunningInBackground`
(`AppModel.swift:758`) is only checked at the *start* of a pass, never mid-flight — so a pass that
was safely foreground when it started keeps running, unprotected, straight into the CPU monitor the
instant the user locks the phone.

**Research: `beginBackgroundTask` doesn't solve this even if added.** It extends *how long before
suspension*, not the CPU-time ceiling — a "Non-Frontmost" process is still subject to the 80%/60 s
monitor whether or not it holds that assertion (no source confirms an exemption). **iOS 26's
`BGContinuedProcessingTask`** is the API actually built for "foreground work started by the user
that must survive backgrounding," with a system-provided progress UI, and is very likely exempt from
the ordinary Non-Frontmost throttle (it's explicitly designed for open-ended work like video
exports, which the 48 s budget could never accommodate). But it's new and has real, currently
unresolved rough edges:
- A live Apple daemon bug (`developer.apple.com/forums/thread/807370`, iOS 26.1+): `submit()` can
  report success while the launch handler silently never fires (`duet` fails to recognize the app as
  foregrounded). Apple's own DTS-recommended fix: **never gate starting the actual work on the
  task's callback** — start work immediately regardless, submit the continued-processing request in
  parallel purely to extend runtime + get the progress UI, with a short fallback timer.
- `submit(_:)` is deprecated; use `submitTaskRequest(_:completionHandler:)`, which actually
  surfaces submission failures.
- A separate reported bug with **wildcard** identifiers not matching correctly. NOOP only ever runs
  one scoring pass at a time, so the plan uses a single **fixed** identifier and sidesteps this.
- Requires an explicit user-initiated trigger per Apple's guidance (no hard runtime enforcement
  found, but treated as a real constraint) — satisfied here because submission is triggered by the
  same foreground pass-start decision the app already makes only when the user has the app open.

## Approach

1. **Fix the `baselines1` signature churn (load-bearing, both outcomes).** Add
   `AnalyzeRecentConfigSignature.hrvBaseline1(_:)` / `.restingHRBaseline1(_:)` quantizers
   (`Packages/StrandAnalytics/Sources/StrandAnalytics/AnalyzeRecentDayCache.swift`, next to the
   existing three) — proposed quanta: **1.0 ms** for HRV, **1.0 bpm** for resting HR (tunable; the
   file's own doc already states the tradeoff: "a value drifting across a quantum boundary still
   invalidates — that degrades to exactly today's behaviour, never to a wrong score"). Wire them into
   the signature at `IntelligenceEngine.swift:823-824`, replacing the raw floats. Extend
   `AnalyzeRecentConfigSignatureTests.swift` with the same "unchanged within quantum ⇒ signature
   unchanged" + "still invalidates on genuine drift" shape already used for the other three.
   **Kotlin twin same commit** (`android/.../analytics/AnalyzeRecentConfigSignature.kt` +
   `IntelligenceEngine.kt:547`), written but not compiled locally, per `CLAUDE.md`. Signature-only —
   no score, tier, or displayed number changes, so this needs no `PENDING_VALIDATION.md` entry of its
   own for correctness, but DOES need one for "does the churn actually stop" (see Verification).

2. **Fix the checkpoint-vs-suspend race.** In `SyncAnalyzeBackgroundScheduler.swift`'s
   `expirationHandler` (`:50-54`, `:110-114`), don't call `setTaskCompleted` until the cancelled
   worker's persist (`IntelligenceEngine.swift:1586`) has actually run — await it with a short,
   bounded grace (a few seconds; iOS gives some slack after `expirationHandler` fires before it
   force-kills). Small, contained change to an already-correct mechanism.

3. **Instrument the `score` phase the way `d4225454` did for `prep`.** One fresh night still costs
   ~26 s of `score` (measured 2026-09-03) — under budget alone, but worth knowing where it goes
   before deciding whether it needs its own fix, the same "instrument first" discipline Phase 1
   used for `prep`. Add a coarse split (e.g. stager vs. recovery/effort scoring) to the existing
   `analyzeRecent cost prep=… score=…` log line. No behavior change.

4. **Wire `BGContinuedProcessingTask` for the open-then-lock flow (outcome 1).**
   - `project.yml`: add `$(PRODUCT_BUNDLE_IDENTIFIER).analyzeContinued` to
     `BGTaskSchedulerPermittedIdentifiers` (no new `UIBackgroundModes` value — `processing` is
     already declared and granted). Comment the fixed-identifier decision (no wildcard) and the
     precedent that a *new* background-mode capability needed a fresh install
     (`git show 3f434482`) — this change only appends to an already-provisioned array, so try an
     ordinary upgrade install first (see Verification's data-safety note before escalating).
   - New `@available(iOS 26.0, *)`-gated controller (new file under `StrandiOS/System/`, sibling to
     `SyncAnalyzeBackgroundScheduler.swift`) that registers the task at launch
     (`StrandiOSApp.swift`, alongside the existing `.analyze`/`.debugexport`/`.healthwriteback`
     registration) and is invoked from the *existing* foreground pass-start decisions —
     `AppModel.swift:546` (idle-tick) and `:881` (postOffload) — submitting the request via
     `submitTaskRequest(_:completionHandler:)` in parallel with (never gating) the
     `analyzeRecent` call already made there. Title/subtitle driven off `intelligence.computing`
     and the day count being scored; progress from whatever coarse per-day signal the loop already
     has. On iOS < 17.0...26.0 (deployment target is 17.0), this is simply skipped — today's
     foreground-only behavior is the fallback, not a stub, since it's the exact behavior that
     already ships.
   - Deliberately **not** using `beginBackgroundTask` as a supplement — research above found no
     evidence it changes CPU-monitor exposure, so it would add complexity without closing the actual
     gap.

5. **`docs/PENDING_VALIDATION.md`**: one new entry for this phase's claim-set — the baselines1 fix
   (does `dayCache DROPPED — sig changed: baselines1.*` stop appearing after a scored night?) and
   the `BGContinuedProcessingTask` path (does scoring actually complete after the user opens NOOP
   and locks the phone, and does the identifier get registered on an upgrade install or need a
   fresh one?). `check-after` should be very short (this week), matching the existing 2026-09-04
   entry's cadence.

## Files

- `Packages/StrandAnalytics/Sources/StrandAnalytics/AnalyzeRecentDayCache.swift` — new quantizers,
  next to `sleepNeedHours`/`sleepConsistency`/`habitualMidsleepSec` (`:104-128`)
- `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/AnalyzeRecentConfigSignatureTests.swift`
- `Strand/Data/IntelligenceEngine.swift` — `:823-824` signature inputs, `:884-887` the existing
  suspicion comment to resolve, `:1586` the persist the race-fix must wait on
- `android/app/src/main/java/com/noop/analytics/AnalyzeRecentConfigSignature.kt`,
  `IntelligenceEngine.kt:547` — Kotlin twin, written but not compiled locally
- `StrandiOS/System/SyncAnalyzeBackgroundScheduler.swift` — `:50-54`/`:110-114` the race fix
- `StrandiOS/System/` — new `BGContinuedProcessingTask` controller file
- `StrandiOS/App/StrandiOSApp.swift` — new task registration alongside the existing three
- `Strand/App/AppModel.swift` — `:546`, `:881` the two submission call sites
- `project.yml` — new `BGTaskSchedulerPermittedIdentifiers` entry
- `docs/PENDING_VALIDATION.md`

## Verification

- `cd Packages/StrandAnalytics && swift test` — green, including the new signature tests.
- Build iOS by hand (CI doesn't cover app targets): `xcodegen generate && xcodebuild -project
  Strand.xcodeproj -scheme NOOPiOS -destination 'id=<device>' -derivedDataPath build-device
  -allowProvisioningUpdates build`.
- **⚠️ Data-safety step before any reinstall attempt:** NOOP's SQLite store has no cloud backup —
  a full uninstall erases months of already-decoded strap history the strap itself no longer holds.
  Try an ordinary upgrade install first. Only if the new `BGContinuedProcessingTask` identifier
  isn't accepted (verify via a registration-success log or the task simply never appearing in device
  diagnostics) escalate to a full reinstall, and **only after** backing up
  `Library/Application Support/OpenWhoop/whoop.sqlite{,-wal,-shm}` and the prefs plist via the
  existing `devicectl device copy from` recipe (`noop-read-device-prefs` / `noop-device-crashlogs`
  memories) — this session's tooling already does this.
- **Cache-churn check:** pull the plist after a pass that scored a fresh night, then another pass
  right after. Before the fix: `dayCache DROPPED — sig changed: baselines1.*` on the second pass.
  After: the second pass should show a high `reused=` count instead.
- **Outcome 1 end-to-end:** open NOOP, let a pass start (banner appears), lock the phone before it
  finishes, wait, then pull crash logs + the plist — expect **no new `cpu_resource_fatal`**,
  `lastPassEndedAt` advancing, and (if `BGContinuedProcessingTask` registered successfully) system
  background-task diagnostics showing the identifier ran.
- **Outcome 2 end-to-end (unchanged from Phase 1):** overnight, strap worn, phone unplugged on
  waking, no app-open — `noop.analyzeWatermark` advances and `re-score: done` appears, with zero new
  `NOOP*.cpu_resource*` reports. Baseline to beat is still the original **15** from 08-31/09-01.

## Deliberately not doing

- **`beginBackgroundTask`** as a standalone fix — doesn't address the CPU-monitor exposure that
  actually causes the kill (see research above); `BGContinuedProcessingTask` is a strict upgrade for
  the same problem.
- **Wildcard `BGContinuedProcessingTask` identifiers** — a real, separate reported bug, and NOOP has
  no concurrent-job use case that would need one.
- **A full data-loss-risking reinstall as a first move** — try the upgrade path first; see
  Verification.

---

# Phase 3 — make each background fire converge instead of starting over (2026-09-04)

## Context

Phase 2's cache fix worked (confirmed on device: three back-to-back passes, `reused=15/16`, `prep`
1.7 s instead of 71 s). But sleep is **still not scored in the background.** On the morning of
2026-09-04, strap synced, app never opened:

- `bg.fireCount` 20 → **31** — iOS granted 11 background windows overnight.
- `bg.lastOutcome` / `lastOutcomeAt` frozen at **2026-09-03 21:29:30**; `expireCount` still 2.
- `analyze.lastPassEndedAt` frozen at **2026-09-03 21:29:29** — no pass has *completed* since.
- Direct DB read: newest computed `sleepSession` is 09-02→09-03. **Last night is unscored.**
- No `cpu_resource_fatal` after 00:20:06 and no jetsam during those 11 fires.

iOS is not withholding time. It granted 11 windows and every one produced nothing durable.

### Why: every fire attempts a full 21-day pass, and the pass is all-or-nothing

1. **Nothing bounds a background pass.** `AnalyzePolicy.decide` returns `.run` unconditionally for
   `.background` (`Strand/Data/AnalyzePolicy.swift:63`), so the 900 s floor that throttles
   `.postOffload`/`.idleTick` is deliberately bypassed. The only remaining gate is the whole-store
   fingerprint (`IntelligenceEngine.swift:569`), which always moves because offloads keep landing.
   `analyzeIfStale()` (`:2528`) calls `analyzeRecent` with the default `maxDays: 21` — full width,
   every fire.
2. **Progress is banked only at the very end.** The watermark (`:2498`) and `completedPassCount`
   (`:2503`) are gated on `!Task.isCancelled` and written only after pass 2 finishes; the day-scan
   cache is persisted once, after the loop (`:1595` — its comment says "Once per pass, never per
   day"). A process that dies mid-pass *without cancellation* — which is what an ordinary iOS
   termination gives you — persists nothing at all.

Net: 11 fires each did real work and discarded it.

### Two corrections, recorded so they are not repeated

- **"11 fires, zero outcomes ⇒ `recordOutcome` was never reached" is NOT established.**
  `BackgroundAnalyzeTelemetry` never calls `synchronize()` — every write is a bare
  `UserDefaults.set`. `recordFire()` runs at t=0 with minutes of process life for iOS's periodic
  flush; `recordOutcome()` runs at t=N immediately before whatever ends the process. "fireCount
  persisted, outcome didn't" fits *both* "never reached" and "never flushed". The telemetry cannot
  tell them apart — which is why Commit 3 exists.
- **A timeout + cancellation budget does NOT work.** Pass 2 (`:1618`–`:2516`, ~700 lines including
  `await repo.refresh()` at `:2488`) has **no `Task.isCancelled` checks at all**. Cancelling
  truncates the scan loop and then runs the whole expensive tail anyway. Do not implement it.

## Approach

Narrowing `maxDays` is the lever that works, because `oldestDay` derives from it (`:411`, `:2053`) —
a narrow window shrinks **both** the scan loop and pass 2's reconcile span, so nothing needs to be
cancellable.

1. **Bound the background pass to a narrow window.** `analyzeIfStale()` (`:2528-2532`) passes a small
   `maxDays` (start at **3** — today, last night, one margin day) instead of the default 21. Put the
   constant in `Strand/Data/BackgroundAnalyzeSchedulePolicy.swift` beside the existing re-arm
   intervals so it is named, documented and unit-testable rather than a literal.
   **Safety verified:** `ComputedScoreReconcilePolicy` plus `oldestDay = nowLocalMidnight −
   (maxDays−1)·86400` mean the stale-day eviction and `persistComputedScores`' delete-then-reinsert
   span exactly the days scanned — a narrow pass is self-consistent, not a truncated one.
   **Known limitation, to state in the commit and the validation entry:** a *completed* narrow pass
   writes the whole-store watermark (`:2498`), claiming freshness beyond what it scored. A backlog
   older than the window will not be caught by background passes; the foreground and idle-tick paths
   keep the full 21-day window and remain the catch-up route.

2. **Checkpoint the day-scan cache incrementally, off the MainActor.** Persist from *inside* the
   detached scan loop after each day — throttled to at most once every ~5 s, and only when a day was
   actually scanned since the last checkpoint — so a fire cut off without cancellation still banks
   what it scanned. Keep the end-of-pass save as the final write. Confirm `DayScanCacheStore`
   (`Strand/Data/DayScanCacheStore.swift`) carries no MainActor isolation so it is callable from the
   detached task; its writes are already `.atomic`.

3. **Telemetry that survives an unannounced termination.** Add `lastStage` / `lastStageAt` to
   `BackgroundAnalyzeTelemetry`, written at each milestone inside the background task (fired → store
   opened → fingerprint read → scan started → scan finished → pass 2 finished → outcome), each
   forced to disk. This makes the next occurrence *diagnosable* rather than inferred, and settles the
   unreached-vs-unflushed ambiguity directly.

4. **Move the blocking I/O off the MainActor (safe subset).** All three run on every background pass
   and block the main thread with no `await`:
   - `IntelligenceEngine.swift:877` — `DayScanCacheStore.load()`, synchronous read + JSON decode
   - `IntelligenceEngine.swift:1595` — `DayScanCacheStore.save()`, synchronous JSON encode + write
   - `IntelligenceEngine.swift:706-707` — `registry.all()` / `registry.activeDeviceId()`, synchronous
     GRDB reads (`registryWriter` is `nonisolated`, `DeviceRegistryStore.swift:20-27`)

   **Deliberately out of scope:** `hrFingerprint()`'s unindexed whole-store `COUNT(*)` over
   `hrSample` (`:567`, `Packages/WhoopStore/.../Reads.swift:91-100`). First thing every pass does and
   a strong suspect, but it changes a query the freshness gate depends on — it gets its own
   measurement first. File it in `docs/BACKLOG.md`.

5. **Docs.** A `docs/PENDING_VALIDATION.md` entry for the claim-set (only a real overnight can
   confirm it), and the `hrFingerprint` note in `docs/BACKLOG.md`.

**Not doing — the submit/re-arm churn.** `submit()` cancels before every submit
(`SyncAnalyzeBackgroundScheduler.swift:96`) and the undebounced `live.$lastSyncedAt` sink
(`AppModel.swift:426-431`) fires every ~8-10 min, so the pending request is always the unbounded
"ASAP" variety rather than a deferred floor. But 11 fires in 12 h is far slower than that cadence,
so iOS's own throttling — not our churn — is the binding constraint. Real, minor, not the cause.

## Files

- `Strand/Data/IntelligenceEngine.swift` — `:2528` the window, `:1591-1604` the persist to make
  incremental, `:877` and `:706-707` the blocking reads
- `Strand/Data/BackgroundAnalyzeSchedulePolicy.swift` — the new window constant
- `Strand/Data/DayScanCacheStore.swift` — confirm off-actor callability
- `StrandiOS/System/BackgroundAnalyzeTelemetry.swift` — stage breadcrumbs + forced flush
- `docs/PENDING_VALIDATION.md`, `docs/BACKLOG.md`

**Kotlin twin:** none owed, to confirm at implementation. `BGProcessingTask` scheduling is iOS-only
and the Android day cache is in-memory (`IntelligenceEngine.kt:83`, a `HashMap`) with no persistence,
so the checkpointing has no counterpart. If the window constant lands in shared analytics rather than
the iOS-only policy file, mirror it.

## Branch

`fix/background-analyze-converges` off `main`. `main` currently carries the **unpushed** local commit
`f3eee8c8` (the `repo.refresh` timing instrumentation) — branch from current `main` so it is
included. No push without an explicit ask.

## Verification

- **First action:** stop the hourly monitoring cron (`CronDelete c455d16f`) — its device tunnel is a
  confound for exactly the idle-state behaviour being measured.
- `cd Packages/StrandAnalytics && swift test`; `WhoopStore` too if its reads are touched.
- App targets are not covered by CI — build both by hand: macOS `Strand`, and the `NOOPiOS` scheme.
- `python3 Tools/doc_comment_lint.py` and `python3 Tools/i18n_audit.py --ci origin/main`.
- Deploy to device, then **one overnight with the app never opened.** Morning acceptance:
  1. `bg.lastStage` has advanced past "fired" — the most informative new signal.
  2. `bg.lastOutcome` / `lastOutcomeAt` are current, not frozen at the prior evening.
  3. `analyze.lastPassEndedAt` has advanced past the night.
  4. Direct DB read shows a `sleepSession` row for the night, `source=computed`, with the app never
     opened.
  5. Zero new `NOOP*.cpu_resource*` reports (baseline: 21 files, newest 2026-09-04 00:20:06).
- If (1) advances but (2)–(4) do not, the stage marker names the exact step to attack next — which is
  the whole reason it ships alongside rather than after.

## REVISION after design review — this supersedes the Approach above

A design review found two of the four proposed changes defective. Revised scope:

**DROPPED — the narrow `maxDays` window (was item 1).** Two reasons. (a) The cache prune at
`IntelligenceEngine.swift:1545-1546` means a narrowed pass writes the *smaller* entry set back to
disk, so a 3-day background pass would shrink the on-disk cache and leave the next foreground 21-day
pass cold for 18 days — actively worse than doing nothing. (b) It buys little anyway: narrowing
removes the nearly-free cache hits, not the one expensive fresh day, which is precisely last night.
Record it in `docs/BACKLOG.md` *with the prune landmine written down* so it is not re-attempted
naively.

**PREREQUISITE — contract the truncated-pass reconciles.** Two genuine bugs, worth fixing on their
own merits, and one of them must land before checkpointing means anything:
- `:2456` `deleteWorkouts(deviceId:sport:"detected",from:windowStart,to:now)` spans the whole window
  while `workoutRows` is built only from `scoredNights` — a truncated pass deletes detected workouts
  across days it never re-scored and re-inserts only the newest. Contract it to `reconcileFromDay`'s
  span exactly as `persistComputedScores` already is at `:2126-2135`.
- The `#899` heal (`:2400-2410`) sweeps the full `oldestDay...newestDay` on a truncated pass, and if
  it drops anything, `:2432-2439` runs `dayScanCache.removeAll()` + `DayScanCacheStore.clear()`.
  **That deletes the very checkpoint the next change exists to accumulate.** Gate the sweep, the
  cache clear and the `pendingForcedRescore` re-arm on `!passWasCancelled`.

**Revised commit order**

1. **Contract the truncated-pass reconciles** (the two bugs above). Prerequisite for #3.
2. **Durable stage telemetry** — `lastStage`/`lastStageAt` in `BackgroundAnalyzeTelemetry`, forced to
   disk at each milestone. Settles unreached-vs-unflushed and names the failing step next time.
3. **Incremental checkpointing** of the day-scan cache from inside the detached scan loop. Confirmed
   mechanically possible (plain `enum`, no actor isolation, `.atomic` writes; `load()` has no
   whole-window assumption and any loop prefix is consistent with the fixed `configSig`). But the
   checkpoint is **O(window), not O(1)** — it re-projects all ~21 entries and encodes the whole
   ~407 KB envelope — so throttle on elapsed time **and** gate on "a day was actually scanned fresh
   this iteration"; a cache-hit day is already on disk byte-identical. Instrument the encode cost
   onto the existing `skippedDayLines` tally before fixing the interval.
4. **Fix the retry interval.** A truncated pass returns `scored: false`, so the scheduler records
   `.noop` and re-arms at `reArmAfterNoopSeconds` = 3600 s — which *exactly matches* the observed
   hourly process replacement. Surface a distinct partial/truncated outcome from `analyzeIfStale`
   (`:2528-2532`) so the scheduler records it separately and re-arms at the short 900 s interval.
   `.background` is unfloored in `AnalyzePolicy.decide`, so nothing blocks a tighter re-arm.
5. **Move the blocking I/O off the MainActor** — `:877` load, `:1595` save, `:706-707` registry
   reads. Unchanged from item 4 of the original approach.
6. **Docs** — `docs/PENDING_VALIDATION.md` entry; `docs/BACKLOG.md` for the `hrFingerprint`
   `COUNT(*)` and for the dropped narrow-window idea plus its prune landmine.

**Also suppress the `#899-A` re-arm for `.background`.** The re-invoke at `:642` is an unstructured
`Task {}` that inherits no cancellation, and the carried trigger falls back to `.dataChange`
(`:629`), which `AnalyzePolicy` never floors — so it can spawn a full unbudgeted second pass in the
background. The next BGTask fire is the successor; don't self-re-arm there.

**One claim from the review NOT accepted.** It anchors its arithmetic on "~70 s for one uncached
day", quoting comments that predate `c863218a`. Measured post-fix on 2026-09-03: a fresh day is
`prep=1745ms score=12548ms` ≈ 14 s, and a second pass 8.3 s, with `otherReads` dominating prep. The
"one day cannot fit the budget" premise is stale. Its wall-clock-vs-CPU-time caveat is fair and the
`prep`/`score` tallies should not be compared to the 48 s CPU budget as if the units matched.
