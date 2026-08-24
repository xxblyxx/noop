# Fix: morning sync makes the phone hot and the UI laggy

## Context

Syncing the WHOOP 5.0 in the morning leaves the phone warm and the UI laggy for 5–15+ minutes.
Investigation (2026-08-23) found the cause is **not** the BLE offload — it is the analytics re-score
that follows, fired far too often and allowed to run concurrently with the offload.

### Measured evidence

Source: `Library/Preferences/com.bly.noop.plist` → `strapLog.tail`, pulled from the device.
`re-score: done` is emitted unconditionally (`IntelligenceEngine.swift:2095`, `domain: nil`).

```
pass 18:45:07 -> 18:45:47    48.2s  overlapping backfills=0
pass 18:51:09 -> 18:51:53    48.5s  overlapping backfills=0
pass 19:01:11 -> 19:01:34    50.3s  overlapping backfills=0
pass 19:09:11 -> 19:18:46   573.5s  overlapping backfills=2  rows=[6, 3]   ← 12× inflation
pass 19:18:46 -> 19:19:48    61.9s  overlapping backfills=0
pass 19:20:15 -> 19:20:48    48.0s  overlapping backfills=0
pass 19:31:12 -> 19:31:58    46.2s  overlapping backfills=0
pass 19:41:40 -> 19:42:11    40.9s  overlapping backfills=0
```

**21.5 minutes of re-score CPU in a 47-minute window.** Every pass `trigger=forced newData=yes`.

Four facts that determine the fix:

1. **A ~48 s full pass fires after essentially every offload session, ~every 10 min, all day** — even
   when the session banked **6 rows**. This is not a morning-only problem; the morning is just when
   sessions are most frequent and the backlog largest.
2. **Overlap with an in-flight offload inflates a pass 12×** (48 s → 573 s), caused by two sessions
   totalling 9 rows. Mechanism unattributed (GRDB writer contention, main-actor contention with
   `Backfiller.ingest`, CPU competition and thermal are all candidates); the fix is the same either way.
3. **`skipIfUnchanged` can never skip.** `IntelligenceEngine.swift:508-513` compares a whole-store
   `hrFingerprint()` (`Reads.swift:91-100`, `COUNT(*)`/`MAX(ts)` over all of `hrSample`). Live HR
   advances it every second, so the gate always falls through. Same defect the 30-min backstop
   already documents at `AppModel.swift:447-452`.
4. **The `dayScanCache` is working** — `analyzeRecent dayCache reused=4/21 size=5`. Only the current
   day is re-scored. So ~48 s is the cost of scoring **one** day: a ~54 h window at 1 Hz =
   ~121,000 HR rows + ~53,000 R-R rows + gravity/steps/skinTemp/sleepState at ~121k each
   (~650k rows through GRDB), plus sleep staging, plus the trailing 4000-day `repo.refresh()`
   which is inside the measured span.

**Not attempted:** which sub-step of the 48 s dominates. That needs a profiler. This plan reduces
*how often* and *when* the pass runs and gets the rest off the main actor — which is what the
acceptance criteria ask for — rather than optimising an unprofiled hotspot.

### Store scale (for sizing)

150 MB over 4 days (~37 MB/day, ~1.1 GB/month). ~85,500 rows/day/table at 1 Hz across 6 fanned-out
tables. `dailyMetric`: `apple-health` 35, `my-whoop-noop` 5, `my-whoop` **0**.

## Decisions taken (owner, this session)

- **Scheduling:** defer analyze until the strap goes quiet; accept that scores appear later.
- **Progress bar:** two segments, time-based, one 0–100% sweep.
- **Background:** add a real `BGProcessingTask` (not just rely on `bluetooth-central`).

## Branch

`fix/sync-rescore-storm`; commits below are one concern each.

---

## Commit 1 — `fix(analyze): never re-score during an offload; coalesce the burst`

The highest-value change; it alone should turn ~21.5 min of CPU per 47 min into ~48 s per sync.

**`Strand/App/AppModel.swift:351-359`** — the debounce sink. Raise the trailing-edge window from
`.seconds(2)` to a quiescence window (**30 s**) so a whole auto-continue burst collapses into one
pass. The existing comment at `:340-350` documents the 2 s value; update it with the measured reason
(sessions land ~8–10 min apart on the periodic timer and back-to-back on auto-continue, so 2 s
coalesces only within a burst).

**`Strand/App/AppModel.swift:576-603`** — `refreshAfterCompletedBackfill`. Add one guard at the top:
- **Hard gate:** if `live.backfilling`, re-arm (don't drop the request) and return. Never analyze
  while an offload is in flight. This removes the measured 12× inflation.

Considered and **rejected**: a "skip if the session banked zero rows" delta gate. Checked against the
data — the 573 s outlier was triggered by sessions banking 6 and 3 rows, both nonzero, so this gate
would not have caught it; the `backfilling` hard gate above does. It would also require a new
published field on `LiveState`, the exact object Commit 2 exists to quiet. Not worth it.

**`Strand/Data/IntelligenceEngine.swift:508-513`** — repair the `skipIfUnchanged` gate so live HR
cannot defeat it. Compare a fingerprint over **completed days only** (bound the window to
`ts < startOfTodayLocal`) instead of the whole-store `hrFingerprint()`. Use the existing windowed
`hrFingerprint(deviceId:from:to:)` (`Reads.swift:68-81`). Keep the watermark write at `:2094`.

**Verify before shipping:** `:505-513`'s comment explains the *current* whole-store scope exists
because of #1196 — a narrower gate once made Trends/streak reads flicker between full and empty,
which read like data loss. A pass that is skipped scores **no** days, including today's still-live
one. Confirm what Today shows for the current day across a skipped pass (whether its live numbers
come from this analyze pass or from a separate live-telemetry path) before relying on this change —
if skipping stales today's card, narrow the gate to "skip only when nothing in the 21-day window
changed AND it isn't the first pass since local midnight" instead of shipping it as scoped above.

Also add a **minimum interval between forced passes** (15 min, reusing the shape of
`BackfillPolicy.periodicFloorSeconds` at `Strand/BLE/BackfillPolicy.swift:21`), bypassed by
`.manual` and by a local-midnight rollover.

**Kotlin twin, same commit.** `docs/CROSS_PLATFORM.md:98-101` binds decoders, formulas, migrations and
stored values; this is scheduling, so it is not strictly bound — but the post-offload `newData` gate
is explicitly named as an Android twin (`IntelligenceEngine.swift:509`, "Twin of the Android
`WhoopBleClient` post-offload `newData` gate") and there is precedent for twinning perf work
(`db20b7ac`). Mirror in `android/…/ui/AppViewModel.kt` and `android/…/ble/WhoopBleClient.kt`.
**Kotlin cannot be compiled here — say so in the commit message.**

## Commit 2 — `perf(log): stop the strap log invalidating every LiveState observer`

Independent of sync, and continuous while connected. In the pulled log, **1,177 of 2,000 lines
(59%) were `[workouts] liveActivity: push …`** (`StrandiOS/App/StrandiOSApp.swift:323-325`).

Each line runs `LiveState.append(log:)` (`Strand/BLE/LiveState.swift:575-602`), which mutates
`@Published var log: [String]` (`:358`) → `objectWillChange` on a ~60-`@Published` `ObservableObject`
→ re-render of every screen observing it (`LiveView.swift:185-198`, `HealthView.swift:138-196`,
`IntelligenceView.swift:326`, `SleepView.swift:2483`, `DevicesView.swift:234`). Every 32 lines it
also runs `persistTail` (`:628-631`), writing a **2,000-string array to UserDefaults on the main
actor** (`tailLimit = 2_000`, `:623`).

- Move `persistTail` off the main actor (it is already `nonisolated`; dispatch it rather than calling
  inline), or raise `persistEveryNLines` — the tail only feeds a scheduled export (`:561-567`).
- Split the log out of `LiveState`'s invalidation. A small dedicated `ObservableObject` for the ring
  keeps the log card live without invalidating the other ~60 properties' observers.

> **Zero-code mitigation available now:** the `[workouts]` tag means that line is gated on
> `TestCentre.active(.workouts)` (`StrandiOSApp.swift:323`) — the "Workouts & GPS" toggle in
> Settings → Test Centre (`TestModeRegistry.swift:103-106`). Turning that Test Centre domain off
> removes 59% of log lines immediately. Worth doing before/independently of this commit.

## Commit 3 — `perf(sync): take the post-sync refresh off the main actor`

All inside `refreshAfterCompletedBackfill`'s chain:

- `AppModel.refreshV5Signals()` → `computeCyclePhase()` (`AppModel.swift:1763-1795`): three
  `Baselines.foldHistory` calls over all of `repo.days` plus a per-day loop, **on the main actor**.
  Move the fold into a detached task, publish the result.
- `StrandiOS/Widgets/WidgetPublish.swift:28`: unconditional `exploreSeries(key: "sleep_performance", …)`
  which defaults to `days: 4000` (`Repository.swift:2176`), run *before* the `reloadAllTimelines`
  dedup at `:97-109`. Bound the window.
- `Strand/Data/WatchSessionBridge.swift:75-87`: `buildSnapshot` (another 4000-day `exploreSeries` at
  `:134`, plus un-memoized `Repository.widgetAnchor` scans) runs **before** the 30-minute
  `shouldPush` gate at `:103-107`. Move the build after the gate.
- `Strand/Data/IntelligenceEngine.swift:2089`: `await repo.refresh()` defaults to 4000 days and runs
  seconds after `AppModel.swift:578` already did `refresh(days: 120)`. Bound it.

## Commit 4 — `feat(today): a sync/analyze progress bar at the top of Today`

**Where.** `LiquidTodayView` is the shipping Today on both platforms
(`StrandiOS/App/RootTabView.swift:51,55` — `liquidTodayEnabled = true`); classic
`Strand/Screens/TodayView.swift` is the fallback behind a Settings toggle
(`SettingsView.swift:1691`). **Both files need it** or a default-configuration user sees nothing.

- `LiquidTodayView.swift:262-268` — own `ScrollView`; attach with `.safeAreaInset(edge: .top)`.
- `TodayView.swift:1280-1295` — wrapped in `ScreenScaffold`; add a `topInset` parameter to
  `Strand/Screens/ScreenScaffold.swift:41-48` rather than reaching inside it.
- Note: `.safeAreaInset(edge: .top)` has **no house precedent** (only `LiveWorkoutView.swift:74` uses
  `.bottom`, and `RootView.swift:231` deliberately rejected it once). Flagging as a deviation.

**The 0–100%.** The strap reports no pending-record count — `strap-reported newest = ?` on every
auto-continue line, and `LiveState.swift:403-405` records the project's standing position that a
percent from chunk counts "would lie". But the **record frontier is a wall-clock timestamp** and was
verified to track real time within ~4 s (frontier delta 2,189 s vs wall delta 2,187 s over 37 min):

- **Phase 1 — offload:** `(frontier − frontierAtSessionStart) / (now − frontierAtSessionStart)`,
  clamped 0…1. `frontier` = `collector.latestHRSampleTs()`, already polled in
  `maybeAutoContinueBackfill` (`BLEManager.swift:2333`) and measured at **0.01–0.07 s**
  (`Reads.swift:325-337`). Update per chunk in `ackHistoricalChunk` (`BLEManager.swift:1889-1897`).
  This closes the "B1" gap `LiquidTodayView.swift:2455-2461` names as open.
- **Phase 2 — analyze:** `daysProcessed / maxDays`. The loop (`IntelligenceEngine.swift:730`) is
  inside a `@Sendable Task.detached` that captures nothing MainActor-bound (`:712-713`), and
  `diagnosticSink` is MainActor-bound and not captured (`:212`, `:1238`). So pass in a `Sendable`
  counter (a small `actor`) that the loop increments; the main actor polls it while awaiting `.value`.
- **One sweep:** weight offload 0–70%, analyze 70–100%. Offload dominates wall time (~30 min vs
  ~48 s), but the analyze phase is where the measured lag actually lives — a bar parked at 90% for
  the entire janky part reads backwards. Giving analyze the last 30% keeps it visibly moving during
  the part the user feels. Label names the phase ("Catching up on last night" / "Scoring last
  night"). Document the weighting in the component — it is a presentation choice, not a measurement.

**State.** A new small `@MainActor final class SyncProgress: ObservableObject` — deliberately *not*
on `LiveState`, so the bar does not ride the churn Commit 2 is fixing. Drive visibility through the
existing `DebouncedSyncSignal` (`LiquidTodayView.swift:1893-1899`) so it does not strobe on chunk
boundaries (`backfilling` toggles false→true between every chunk, `:1885`).

**Tokens only** — `NoopMetrics.indicatorTrackHeight` (8, the canonical thin-track token,
`Components.swift:91`), `StrandPalette.accent` fill, `StrandPalette.surfaceInset` track,
`StrandFont.caption` label. Reuse `Packages/StrandDesign/.../TypicalRangeBar.swift:47`, whose `value`
is documented as a clamped 0…1 fraction. No new colors, fonts or spacing.

## Commit 5 — `feat(background): run the analyze pass as a BGProcessingTask and notify on completion`

- `project.yml:255-272` and `StrandiOS/Resources/Info.plist`: add `processing` to `UIBackgroundModes`
  (currently `bluetooth-central`, `location`, `fetch`) and a
  `$(PRODUCT_BUNDLE_IDENTIFIER).analyze` entry to `BGTaskSchedulerPermittedIdentifiers`.
- Register/submit a `BGProcessingTaskRequest` mirroring
  `StrandiOS/Health/HealthWritebackBackgroundScheduler.swift:18,39`, registered from
  `StrandiOSApp.init` (`:65`, `:80`). Set `requiresExternalPower = false`,
  `requiresNetworkConnectivity = false`.
- **Notification** — the stack already exists (`BatteryNotifier`, `IllnessNotifier`,
  `StrainTargetNotifier`, `WindDownNudge`, all in `Strand/System/`, compiled into iOS via
  `project.yml:196`). Follow the house pattern exactly: a new `Strand/System/AnalyzeCompleteNotifier.swift`
  with a `private static func post`, an opt-in toggle in `AutomationsView` requesting authorization at
  toggle-enable time (mirroring `AutomationsView.swift:341,412`), and a `getNotificationSettings`
  check at fire time. Fire **only** when the pass completed while backgrounded.
- **Requires a fresh install** — a `UIBackgroundModes` change does not take effect on an upgrade
  install from Xcode in all cases; reinstall to be sure.
- **Not a guarantee — say so in the UI copy too.** `BGProcessingTask` scheduling is opportunistic;
  iOS may delay or never run it, especially unplugged. This is an *additional* path, not a
  replacement for the one that actually runs today: `bluetooth-central` keeps the process alive for
  the live BLE session itself, which is what lets Commits 1–4 work at all while backgrounded. Frame
  Commit 5 as "notify if a deferred pass completes in the background," not "processing reliably
  finishes in the background."

## Also found, deliberately NOT in scope

- **`2853884e`** (`perf(analyzeRecent): stop the #1005 cache churning…`) added **only two test files**;
  the production change its message describes never landed. `IntelligenceEngine.swift:692-693` still
  folds the raw `baselines1` values. It is *not* this owner's channel (they have no imported strap
  dailies, so `baselines1` is constant) — a separate latent defect, separate commit.
- The always-on R-R sweep (`IntelligenceEngine.swift:1081-1144`) runs six `collapseOverCount` passes
  over ~53k intervals per over-count night — which this strap trips nightly. **Checked: O(n log n),
  tens of ms.** Noted, not fixed.
- 16 empty day-slots probed per pass. Small.
- Silent truncation risk: per-day reads use `limit: 200_000` over a ~54 h window holding ~194,400
  rows at 1 Hz — within 3% of the ceiling. A correctness concern, separate from this work.
- `docs/ARCHITECTURE.md:134,160,174-177` says `DatabaseQueue` + explicit WAL pragma; the code is
  `DatabasePool` with implicit WAL (`WhoopStore.swift:42,51-56,87,95-96`). Doc fix, separate.

## Verification

**No CI covers these targets** (`app-build.yml` triggers only on `pull_request` to `main`, and work
here is merged locally). Build it yourself:

```bash
xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
cd Packages/StrandAnalytics && swift test     # if any package code changes
python3 Tools/doc_comment_lint.py && python3 Tools/i18n_audit.py --ci origin/main
```

**Behavioural check on device — this is the real acceptance test.** After a morning sync, re-pull
the log and compare against the recorded baseline:

```bash
xcrun devicectl device copy from --device 819D37A3-B45A-56CF-9FEC-40D460EC74F8 \
  --domain-type appDataContainer --domain-identifier com.bly.noop \
  --source "Library/Preferences/com.bly.noop.plist" --destination /tmp/prefs.plist
# then count `re-score: done` lines and sum the ms in strapLog.tail
```

| metric | baseline (2026-08-23) | target |
|---|---|---|
| re-score passes per ~47 min | 10 | ≤ 2 |
| total re-score CPU per ~47 min | 21.5 min | < 2 min |
| passes overlapping a backfill | 1 (573 s) | **0** |
| worst single pass | 573 s | ≤ 60 s |

Also confirm by hand: the progress bar reaches 100% and disappears; the UI stays responsive while
scrolling Today during a sync; the notification arrives after a backgrounded pass.

**`docs/PENDING_VALIDATION.md`** — add an entry before calling this done. "The morning sync no longer
heats the phone" is a claim only a future morning can confirm; the baseline table above is the check.
