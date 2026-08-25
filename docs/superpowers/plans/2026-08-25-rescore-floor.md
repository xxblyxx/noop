# Fix: the re-score cadence still has no floor

## Context

`fix/sync-rescore-storm` (18 commits) removed the *overlap* inflation and coalesced the post-offload
burst. A device log pulled **2026-08-25**, on a confirmed post-fix build (it contains
`Backfill: strap deferred (a rescore is in flight)`, a string introduced by `5478d84f` and absent on
`main`), shows the direction was right and the acceptance table was still missed.

Window **08:16:09 → 09:00:32 (44.4 min)**, 591 lines, `Library/Preferences/com.bly.noop.plist` →
`strapLog.tail`. Five `re-score: done` lines, only four `re-score: trigger=` lines — that line is
emitted only `if force` (`IntelligenceEngine.swift:526-535`), which identifies the unpaired one as the
launch-time cadence-loop `analyzeRecent(force: false)` at `AppModel.swift:474`.

| # | trigger | wall duration | dayCache |
|---|---|---|---|
| 1 | launch cadence tick, `force: false` | 1021.3 s | reused=0/21 |
| 2 | post-offload 08:16:42, dropped by `guard !computing`, ran as the #899-A `pendingForcedRescore` re-arm | 74.1 s | reused=0/21 |
| 3 | post-offload 08:33:46, same re-arm path | 16.1 s | reused=6/21 |
| 4 | post-offload after the 08:45:22/31/32 auto-continue burst | 61.2 s | reused=6/21 |
| 5 | post-offload after the 08:53:19/25/28 burst | 45.0 s | reused=6/21 |

Total 1217.7 s wall = 20.3 min. **`re-score: done` reports wall clock**
(`Date().timeIntervalSince(reScoreStart)`, `IntelligenceEngine.swift:2142`), not CPU, and pass 1 spans
a ~742 s process suspension (`[08:20:47] Reconnecting in 3s (attempt 1)` produced no attempt until
`[08:33:09] Connecting` — a 3 s `asyncAfter` taking 12.4 min only happens in a suspended process).
Suspension-adjusted: pass 1 ≈ 279 s, total ≈ **476 s ≈ 7.9 min / 44.4 min (18% duty)**, versus the
2026-08-23 baseline's 46%.

Four mechanisms behind the residual:

1. **No minimum interval between forced passes.** Specified in the previous plan's Commit 1, never
   implemented — deferred openly in `59771a02`'s commit message, but not recorded in that plan's
   corrections section. No time gate exists in `analyzeRecent`'s entry or in
   `refreshAfterCompletedBackfill`.
2. **The `#899-A` re-arm turns every dropped trigger into a full extra pass.** Passes 1→2→3 are one
   causal chain: 90 s of re-scoring the same 7 nights, twice, in the 3 minutes after a pass that had
   just scored them. The re-arm is correct as designed (it exists so a freshly-synced night is not
   left unscored); nothing sits above it deciding whether the re-pass is worth doing. It also
   **discards `skipIfUnchanged` and the caller's identity** (`IntelligenceEngine.swift:560`).
3. **The 30-min cadence loop (`AppModel.swift:463-485`) has no `live.backfilling` check.** The branch
   added that guard to `refreshAfterCompletedBackfill` only. `BLEManager.swift:3981` defers
   `.periodic`/`.strap` on `state.analyzing` — that stops a new offload during a pass, not a pass
   during an offload. Pass 1 overlapped offloads at both ends (08:16:11–12 at its start, the 08:33:11
   `.connect` at its finish). Both were 1–3 s. Treated here as a mechanism gap, not a demonstrated
   cost.
4. **The whole-store `hrFingerprint()` gate cannot skip while the strap streams live HR**
   (`IntelligenceEngine.swift:506-513`). Not addressed by this plan — see §6 for why, and for the
   #1392 cost the previous plan's proposal missed.

**Composition, in one sentence:** the floor covers what the fingerprint gate *can't* (live HR always
moves the whole-store fingerprint), and the fingerprint gate covers what the floor *shouldn't* (a
suspended-process background wake with genuinely no new data).

**Out of scope, deliberately:** per-pass cost (still unprofiled — the previous plan's position stands),
the progress bar (validation observational and pending), the `BGProcessingTask` (zero
`background analyze:` lines in this window is the EXPECTED outcome, not a defect).

### Corrections to the history the 2026-08-23 plan records

Established while writing this plan, verified against the commits:

1. **The forced-pass floor was not silently dropped — it was explicitly deferred, in a commit
   message.** `59771a02` says verbatim: *"Deliberately deferred from this commit …: the
   skipIfUnchanged whole-store hrFingerprint() gate, and a minimum-interval floor between forced
   passes. Both need more care than the 5h usage window allowed today — the fingerprint gate in
   particular has a documented past regression (#1392, per-device fingerprint …)"*. The record is
   incomplete only in the plan *file*. The defect itself is real.
2. **`066d5624` did not revert a narrowed fingerprint gate.** Its diff touches `AppModel.swift`,
   `BLEManager.swift`, `LiveState.swift`, `WhoopBleClient.kt` and the plan file — **not
   `IntelligenceEngine.swift`**. What it reverted was the Kotlin `POST_BACKFILL_ANALYZE_DELAY_MS`
   constant. The narrowing was never written at all, and the blocker `59771a02` recorded for it was
   **#1392**, not #1196.
3. **A fifth defect the 2026-08-25 investigation did not name:** the `#899-A` re-arm drops
   `skipIfUnchanged`. `IntelligenceEngine.swift:560` re-invokes
   `analyzeRecent(maxDays: maxDays, force: true)` — no `skipIfUnchanged`, no trigger. Inert today
   (defect 4 means the gate can never fire while HR streams), but part of why passes 2 and 3 were
   full passes, and cheap to fix.

## Branch

`fix/sync-rescore-storm`; commits below are one concern each.

---

## Commit 1 — `fix(log): attribute every re-score pass, not just forced ones`

**Why first:** every measurement below depends on being able to pair a `done` line with a start and a
trigger. Today a `force: false` pass emits only a `done` line, which is why the 2026-08-25 window had
5 `done` lines and 4 `trigger=` lines and required inference to attribute the biggest pass.

**File.** `Strand/Data/IntelligenceEngine.swift:526-537`.

**Mechanism.** Move the attribution line out of `if force`. Emit unconditionally, immediately before
`let reScoreStart = Date()` (`:537-539`), in the existing shape plus the trigger name introduced in
Commit 2: `re-score: trigger=<name> force=<bool> newData=<yes|no (nothing changed since last run)>`.
The `newData` computation at `:532` already runs for the forced case and is a UserDefaults string
compare over an already-read `wmKey` — no new store read.

**Smallest correct change:** one `if force {` removal plus the string. No behavioural change; the line
is a `diagnosticSink?` call, unlocalized (`live.append(log:)` takes plain `String`), so `i18n_audit`
is unaffected.

**Kotlin twin: not required.** A diagnostic string on the iOS log sink. `docs/CROSS_PLATFORM.md:98-101`
binds decoders, analytics formulas, migrations and stored values; a log line is none of those.
Precedent: the previous plan's correction #7, last bullet (8 review fixes, no twin). Kotlin cannot be
compiled on this machine and none was run.

**Verification without a strap.** Build (`xcodegen generate` + the NOOPiOS build below). Behaviourally
verified by the next log pull: `grep -c 're-score: trigger='` must equal `grep -c 're-score: done'`.

---

## Commit 2 — `feat(analyze): floor the automatic re-score cadence, defer instead of dropping`

The load-bearing commit. One concern: **an automatic re-score runs at most once per floor interval,
and a rejected trigger is deferred, never dropped.**

### New file — `Strand/Data/AnalyzePolicy.swift`

Pure, no store/BLE/UI deps, deliberately shaped like `Strand/BLE/BackfillPolicy.swift:20-60`:

```swift
enum AnalyzeTrigger { case postOffload, idleTick, background, dataChange }
enum AnalyzeDecision: Equatable { case run; case deferUntil(TimeInterval) }
enum AnalyzePolicy {
    static let forcedFloorSeconds: TimeInterval = 900
    static func decide(trigger: AnalyzeTrigger, now: TimeInterval,
                       lastPassEndedAt: TimeInterval?, tzOffsetSec: Int) -> AnalyzeDecision
}
```

Rules, each with a stated reason in the doc comment:

- `.dataChange` and `.background` → always `.run`. `.dataChange` is every user- or data-driven caller
  (manual sync, import, sleep/workout edit, recalibrate, the #547 heal, the #313 Effort rescore,
  `adoptActiveDevice`) — the same set `BackfillPolicy` already treats as "never delayed".
  `.background` bypasses per the composition sentence above: nothing streams HR while the process is
  suspended, so `analyzeIfStale`'s fingerprint gate is genuinely trustworthy for that caller and the
  wake is already rationed by iOS.
- `lastPassEndedAt == nil` → `.run` (fresh install / first pass after the key is added).
- `now < lastPassEndedAt` (backwards clock, timezone travel) → `.run`. Self-healing; never wedge on a
  bad clock.
- local-day rollover: if `AnalyticsEngine.dayString(Int(now), offsetSec: tzOffsetSec) !=
  AnalyticsEngine.dayString(Int(last), offsetSec: tzOffsetSec)` → `.run`. Uses the *same* public helper
  the scoring loop uses for day keys (`IntelligenceEngine.swift:381-382`), so the rollover boundary is
  byte-identical to the one scoring uses. The first pass after local midnight must be allowed: it is
  the one that finalizes last night and opens today's slot.
- otherwise `elapsed >= forcedFloorSeconds` → `.run`, else `.deferUntil(last + forcedFloorSeconds)`.
  `>=` matches `BackfillPolicy.shouldRun`'s existing convention.

**Why 900 s.** It is the previous plan's spec, it equals `BackfillPolicy.periodicFloorSeconds`
(`BackfillPolicy.swift:21`), and it is the cadence of the thing it throttles: at most one analyze per
periodic-offload window. At the measured ~48 s steady-state pass that caps the duty cycle at ~5%.

### `Strand/Data/IntelligenceEngine.swift`

- **`:27-46`** (property block): add
  `@Published private(set) var deferredRescoreDueAt: Date?` — set whenever a floored decision rejects
  an automatic call, cleared when a pass actually starts. Published so `AppModel` can observe it, in
  the same shape as the existing `$computing → live.analyzing` mirror at `AppModel.swift:230-235`.
- **`:479`**: add `trigger: AnalyzeTrigger = .dataChange` to the signature. **The default bypasses the
  floor**, so all 14 existing UI / heal / import / settings callers
  (`SettingsView.swift:1492,1667,1995`, `IntelligenceView.swift:95,98`, `WorkoutsView.swift:243,1264`,
  `SleepView.swift:230,240,263,301`, `TestCentreView.swift:400`, `AppModel.swift:596`,
  `IntelligenceEngine.swift:413,466`) are untouched by this commit. Only the three sites named below
  opt in.
- **new private helper**, next to the entry guards: `floorDecision(for:) -> AnalyzeDecision` — reads
  `UserDefaults.standard.object(forKey: Self.lastPassEndedAtKey) as? Double` and calls
  `AnalyzePolicy.decide`. **Synchronous, no `await`**, so it does not widen the pre-existing
  check-and-set race the previous plan's correction #3 records.
- **`:483-484`**, as the **first** statement of `analyzeRecent`, before `guard !computing`:
  on `.deferUntil(t)` → set `deferredRescoreDueAt = Date(timeIntervalSince1970: t)`, log
  `analyze: floored (trigger=…, <n>s since last pass, retry in <m>s)`, `return`. Placing it before the
  `computing` guard means a floored trigger never even sets `pendingForcedRescore` — the chain in
  defect 2 cannot start from this direction. Placing it before `repo.storeHandle()` and
  `store.hrFingerprint()` means a rejected pass costs zero store reads.
- **on the `.run` path**, right where `computing = true` is set (`:539`): clear
  `deferredRescoreDueAt = nil`.
- **`:2141-2146`** (completion): add
  `if !Task.isCancelled { UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastPassEndedAtKey) }`
  alongside the `completedPassCount` increment. **Gate it on `!Task.isCancelled` ONLY — never on
  `!wmKey.isEmpty`.** A transient `hrFingerprint()` throw empties `wmKey`; if the floor timestamp
  shared that guard, one fingerprint hiccup would leave the floor un-advanced and the storm would
  return. This branch already fixed exactly this class of bug — see `completedPassCount`'s doc
  (`:29-38`, review finding #6) and cite it in the comment.
  **A cancelled pass deliberately does NOT advance the floor**, matching the watermark and
  `completedPassCount` precedent at `:2141,2146`. Cost: a cancelled pass can be followed immediately by
  a full one. That is the right trade — a cancelled pass may have `break`-ed out of the day loop early
  (`:760`) and left nights unscored.
- **`:2166-2168`**: add `private static let lastPassEndedAtKey = "noop.analyze.lastPassEndedAt"` beside
  `analyzeWatermarkKey`, with the same doc shape.

**Where the floor state lives, and why `UserDefaults`.** The cost being controlled — CPU, heat,
battery — is per-device wall-clock, not per-process. An in-memory property resets on every relaunch,
and iOS relaunches this app routinely (the measured window contains a 12-minute suspension); a
morning with three relaunches would get three free full passes, which is the storm this exists to stop.
It also composes with `noop.analyzeWatermark`, already `UserDefaults`, so both halves of the gate
persist or reset together.
**Not added to the `.noopbak` whitelist** — precedent: `noop.analyzeWatermark` is not in
`Packages/WhoopStore/Sources/WhoopStore/BackupSettings.swift` either (verified by grep). Restoring a
backup must not import another device's scheduling state.

### `Strand/App/AppModel.swift`

- **`:60-70`** (property block, beside `pendingPostOffloadRefresh`): add
  `private var analyzeFloorRetry: Task<Void, Never>?` with a doc comment.
- **`:736`**: `analyzeRecent(skipIfUnchanged: true, trigger: .postOffload)`.
- **`:735-736`**, immediately before `syncProgress.beginAnalyze()`: consult
  `intelligence.floorDecision(for: .postOffload)` (exposed `internal`); on `.deferUntil` skip
  `beginAnalyze()` + `analyzeRecent` and fall through to the rest of the function.
  **Deliberately NOT an early `return` and NOT before `repo.refresh(days: 120)` at `:731`** — the
  dashboard-cache refresh is what surfaces newly-offloaded raw to Trends/streak reads, and skipping it
  is the shape of failure #1196 was about. Only the analyze pass and its bar phase are skipped.
  Skipping `beginAnalyze()` also avoids flipping the bar out of `.offload` phase for a pass that will
  not run — the same reasoning as the previous plan's correction #7, finding 5.
- **`:474`**: `analyzeRecent(force: false, trigger: .idleTick)`; then, at the loop's sleep (`:484`),
  sleep `min(1800, max(1, dueAt − now))` when `intelligence.deferredRescoreDueAt` is set, so a floored
  tick retries at floor expiry instead of waiting a full 30 min.
- **`:632`**: `analyzeIfStale()` → `analyzeRecent(force: false, trigger: .background)` inside the
  engine (`IntelligenceEngine.swift:2161`). No caller change.
- **The retry.** In `init()` beside the existing `$computing` sink (`:233-235`), add a sink on
  `intelligence.$deferredRescoreDueAt`: on a non-nil value, replace `analyzeFloorRetry` (cancel the old
  one — single outstanding, coalesced) with
  `Task { try? await Task.sleep(until due); await self?.refreshAfterCompletedBackfill() }`.
  Retrying through `refreshAfterCompletedBackfill` and not `analyzeRecent` directly is deliberate: that
  function already owns the reentrancy guard (`:646-656`), the bounded `live.backfilling` wait
  (`:668-688`), the manual `live.analyzing` claim (`:702-703`) and the bar teardown. A raw retry into
  the engine would re-open the overlap window the whole branch exists to close.

**What happens to a rejected trigger — precisely, and how it composes with `#899-A`.**
`#899-A` answers *"a forced call was dropped because a pass held the lock"*; the floor answers *"a
forced call arrived too soon after a pass that already scored this window"*. They now sit in a fixed
order, floor first:

1. Floor rejects → the call never reaches `guard !computing`, so `pendingForcedRescore` is **not** set.
   `deferredRescoreDueAt` is set instead and exactly one coalesced retry is scheduled.
2. Floor allows and a pass is in flight → unchanged `#899-A` behaviour: re-arm.
3. The re-arm itself is floor-checked at its firing instant (Commit 3), which is what actually
   collapses the measured 1→2→3 chain: when pass 1 ends, `lastPassEndedAt` is 0 s old, so the re-arm
   defers to end+900 s instead of running immediately.

**Nothing is ever dropped.** Worst-case latency for a freshly-synced night is one floor interval
(≤15 min) plus the bounded backfill wait, versus "next 30-min tick" today.
**Termination:** each rejection schedules exactly one coalesced retry, and each retry either runs (and
advances `lastPassEndedAt`) or re-defers to a strictly later `lastPassEndedAt + floor` — so the chain
is strictly monotonic in time and cannot recurse unbounded, the same property `#899-A`'s doc claims for
its single re-arm.

**Why this is the smallest correct change.** One new pure file, one new parameter defaulted to bypass,
one new UserDefaults key, one publisher, one retry Task. No existing caller's behaviour changes unless
it opts in. The alternative — a floor buried as a `Date()` compare inside `analyzeRecent` — is smaller
in diff but untestable and would not cover the re-arm site.

**Kotlin twin: not required.** Pure scheduling. `docs/CROSS_PLATFORM.md:98-101` binds decoders,
analytics formulas, migrations and stored values; a device-local scheduling watermark that is not in
the `.noopbak` whitelist is none of those, and the numbers cannot diverge because the *computation* is
untouched — only how often it runs. There is also no mechanical twin available: Android's
`analyzeGate` is a `Mutex` (`android/app/src/main/java/com/noop/analytics/IntelligenceEngine.kt:60`),
so a colliding caller **blocks and then runs** rather than being dropped and re-armed, and its
post-backfill path is leading-edge-with-lockout (`WhoopBleClient.kt:2287`). `066d5624` already reverted
one attempt to mechanically mirror a Swift scheduling constant into that model and recorded why.
**Kotlin cannot be compiled on this machine (no JDK, no Android SDK) and no CI covers it — say so in
the commit message.**

**Verification without a strap:** `StrandTests/AnalyzePolicyTests.swift` (§Test plan) + the iOS and
macOS builds.

---

## Commit 3 — `fix(analyze): carry the dropped call's trigger and gate into the #899-A re-arm`

**File.** `Strand/Data/IntelligenceEngine.swift:41-46` (flag), `:544-563` (the `defer`), `:484` (the
drop site).

**Mechanism.**

- Beside `pendingForcedRescore`, add `pendingForcedRescoreTrigger: AnalyzeTrigger?` and
  `pendingForcedRescoreSkipIfUnchanged: Bool`. At the drop site (`:484`), record the dropped call's
  trigger and `skipIfUnchanged`. Merge rule when several calls are dropped against one pass (the
  boolean latch already collapses them): **the most privileged wins** — if any dropped call was
  `.dataChange`, the re-pass is `.dataChange` with `skipIfUnchanged: false`; otherwise `.postOffload`
  with `skipIfUnchanged: true`. A heal or import must never be downgraded into something the floor can
  defer.
- In the `defer` (`:558-561`), re-invoke with the carried trigger and gate:
  `analyzeRecent(maxDays: maxDays, force: true, skipIfUnchanged: <carried>, trigger: <carried>)`.
  Because the re-invoke runs after the body's completion write, `lastPassEndedAt` is already fresh, so
  a `.postOffload` re-pass is floored by Commit 2's entry check and converts into a
  `deferredRescoreDueAt` — one deferred pass instead of two immediate ones.

**Why it is the smallest correct change.** Three stored fields and one call-site edit. It does not
touch the re-arm's shape, its single-latch bound, or its `!Task.isCancelled` guard from review
finding #5.

**Honest limit.** The `skipIfUnchanged` carry is **inert while the strap streams HR**, because defect 4
means the whole-store fingerprint always differs. Its value is (a) correctness of the re-arm's
contract, (b) it starts working the moment the strap disconnects, (c) it is the piece that becomes
load-bearing if defect 4 is ever fixed. The chain-collapsing work here is done by the *trigger* carry,
not the gate carry. Do not claim otherwise in the commit message.

**Kotlin twin: not required.** Android has no re-arm at all — it has no shared `computing` lock; the
forced post-backfill rescore runs on its own `ioScope` coroutine and is never dropped. This is already
documented in `StrandTests/IntelligenceForcedRescoreRearmTests.swift:21-23`.

**Verification without a strap:** the extended re-arm model test (§Test plan).

---

## Commit 4 — `fix(analyze): let the idle re-score tick wait out an in-flight offload`

**File.** `Strand/App/AppModel.swift:463-474`.

**Mechanism.** Inside the `while !Task.isCancelled` loop, before
`await self.intelligence.analyzeRecent(force: false, trigger: .idleTick)`:

```
var backfillWaited = 0
while self.live.backfilling && !Task.isCancelled && backfillWaited < 120 { sleep 1s; backfillWaited += 1 }
if self.live.backfilling || self.live.analyzing { /* log; skip this tick */ continue-to-sleep }
```

This is the **bounded-poll shape already used twice in this same file** — the `hasActiveImport` wait
30 lines above (`:437-442`) and `refreshAfterCompletedBackfill`'s `live.backfilling` wait
(`:668-688`) — and the both-flags guard mirrors `runBackgroundAnalyze` (`:614-617`).

**Do not oversell this.** A *point-in-time* `guard !live.backfilling` at the top of the tick would not
have fired on either measured instance: pass 1 started 08:16:09 and the offloads started 08:16:11–12,
two seconds *after* the check; the 08:33:11 `.connect` landed at the pass's finish. Those triggers were
`.connect`/`.autoContinue`, which `requestSync` never defers by design (`BLEManager.swift:3975-3983`) —
the existing reverse guard was working correctly and the residual overlap is structural. The bounded
*wait* is what makes the tick actually useful: on a morning where the strap is mid-offload at launch,
the tick starts after quiescence instead of on top of it. It closes a mechanism gap; it did not
demonstrably cost anything in the measured window.

**Why not extend `BLEManager`'s deferral to `.connect` instead.** Because `.connect`/`.foreground` are
deliberately never deferred (both `BackfillPolicy.shouldRun` and the `requestSync` guard say so), and
a user watching a fresh connection must see a sync start. The tick is the side that can afford to wait.

**Kotlin twin: not required.** Scheduling; and Android's analyze loop (`AppViewModel.kt:1121`,
`ANALYZE_INTERVAL_MS`) already serializes through `analyzeGate`.

**Verification without a strap:** build only — this is a two-flag scheduling guard with no pure logic
worth a model test beyond what Commit 2's tests already cover. State that plainly in the commit
message rather than inventing a test that pins nothing.

---

## Commit 5 — `docs(rescore-floor): record the 2026-08-25 measurement and the corrected history`

- Add this plan file.
- Amend `docs/superpowers/plans/2026-08-23-sync-rescore-storm.md`'s corrections section with: the floor
  and the fingerprint narrowing were deferred in `59771a02`'s commit message, not silently dropped, and
  `066d5624` reverted only the Kotlin constant (it never touched `IntelligenceEngine.swift`).
- Add a `docs/PENDING_VALIDATION.md` entry for this plan's passes-if table — "the morning sync no
  longer heats the phone" remains a claim only a future morning can confirm.

**Kotlin twin: not required** (documentation).

---

## 6. Defect 4 (the whole-store fingerprint) — deliberately left alone

`IntelligenceEngine.swift:495-513` explains the current whole-store scope: #1392 (a per-device
fingerprint read 0 on an Oura / Apple Watch / re-added-WHOOP install, so the gate never fired and a
night stayed unscored until relaunch) and #1196 (a narrower gate once made Trends/streak reads flicker
between full and empty, which read like data loss). **Leaving it alone**, for three reasons:

1. The previous plan's proposal — reuse `hrFingerprint(deviceId:from:to:)` (`Reads.swift:68`) — would
   **reintroduce #1392**, because that API is per-device and the engine's `deviceId` is a `let` pinned
   to `"my-whoop"` that is never re-pointed. A correct narrowing needs a *new* cross-device windowed
   fingerprint in `Packages/WhoopStore`, whose Kotlin twin (`WhoopRepository.hrFingerprint()`, named as
   the twin at `Reads.swift:88`) is plausibly binding — a package change plus an uncompilable Kotlin
   change, in one commit, for a gate we can no longer measure the value of.
2. **The floor makes it mostly redundant.** The gate's only job is to let the idle tick skip; the floor
   now bounds the tick's cost regardless of whether its gate can skip.
3. **What it costs to leave it:** the 30-min cadence tick still runs a full pass whenever ≥15 min have
   passed since the last one — roughly one otherwise-avoidable ~48 s pass per 30 min while connected.
   That is inside the passes-if budget below.

**If a future session re-attempts it, this must be verified on-device first:** whether Today's
current-day card reads its numbers from the analyze pass or from a separate live-telemetry path.
A skipped pass scores **no** days, including today's still-live one. Check by forcing a skip (put the
strap on the charger so no HR streams, confirm the gate fires, then watch Today's Effort/steps across
a tick). **Fallback if today's card stales:** narrow to *"skip only when nothing in the 21-day window
changed AND it isn't the first pass since local midnight"* — the rollover half of which
`AnalyzePolicy` (Commit 2) already implements and tests.

**Also left alone, both deliberately:** the check-and-set race in `analyzeRecent` (two `await`s precede
`computing = true`) and the stale-`consecutiveAutoContinues` snapshot in
`BLEManager.maybeAutoContinueBackfill`. Neither is a re-score *frequency* defect; the previous plan's
corrections #3 and #7-last-bullet already record them with reasons. Note only that Commit 2's floor
check is **synchronous**, so it adds no new suspension point and does not widen the first race.

**Recorded, not planned — one thing to grep next time:** pass 2 reported `dayCache reused=0/21`
despite running as the re-arm immediately after pass 1, which had just populated `dayScanCache`;
passes 3–5 reported 6/21, a low ceiling for a 21-day window. Something may be dropping the cache
wholesale between passes. The check is one grep of the `analyzeRecent dayCache reused=` lines
(`IntelligenceEngine.swift:1267`) against the cache-key and fail-safe conditions at `:52-64`. Not a
commit here — it is per-pass cost, which is out of scope.

---

## Test plan

`StrandTests/` runs only via `xcodebuild … test` on macOS (target defined at `project.yml:158-163`,
scheme at `:496-508`; the target's `sources` is the whole `StrandTests` folder, so new files need no
`project.yml` edit — `xcodegen generate` still must be re-run). The local precedent for a
mechanically-verifiable test with an injectable clock is `StrandTests/SyncProgressTests.swift`
(`SyncProgress.now: () -> Date`); the precedent for pinning a scheduling state machine the real type
cannot host is `StrandTests/IntelligenceForcedRescoreRearmTests.swift`'s `RearmModel`.

### New — `StrandTests/AnalyzePolicyTests.swift` (Commit 2)

Pure, no clock injection needed (`now` is a parameter):

1. `lastPassEndedAt == nil` → `.run`.
2. `elapsed == 899` → `.deferUntil(last + 900)`; `elapsed == 900` → `.run` (pins the `>=` boundary,
   matching `BackfillPolicy.shouldRun`'s convention).
3. `.dataChange` and `.background` → `.run` at `elapsed == 0` (bypass).
4. Local-midnight rollover: `last` at 23:58 local, `now` at 00:01 local (elapsed 180 s) → `.run`;
   the same 180 s wholly inside one local day → `.deferUntil`. Run it at a non-zero `tzOffsetSec`
   (e.g. −25200, this owner's zone) so a UTC-only implementation fails.
5. Backwards clock: `now < last` → `.run`.

### New cases in `StrandTests/IntelligenceForcedRescoreRearmTests.swift` (Commits 2 + 3)

Extend the existing `RearmModel` with `lastPassEndedAt`, a `now`, and the floor decision, then add
these cases — keeping every existing case green (the floor must not change behaviour when the floor is
already satisfied):

- **`testFlooredPostOffloadTriggerStillEventuallyRunsExactlyOnePass`** — the most load-bearing test in
  this plan. A floored `.postOffload` trigger must result in **exactly one** pass eventually running,
  never zero. This is the assertion that proves the floor did not reintroduce the failure `#899-A`
  exists to prevent.
- **`testMeasuredChainCollapsesToOneDeferredPass`** — replay the 2026-08-25 timeline as the fixture:
  pass 1 enters at t=0 and ends at t=1021; a `.postOffload` trigger lands at t=33; the re-arm fires in
  pass 1's `defer`. Assert the model runs **one** deferred pass at t≈1921, not the measured two
  immediate ones (t=1021 and t=2050). Fails on today's code, passes on Commits 2+3.
- **`testDataChangeTriggerIsNeverFloored`** — a heal/import re-arm dropped against an in-flight pass
  re-runs immediately, at `elapsed == 0`.
- **`testMergedRearmKeepsTheMostPrivilegedTrigger`** — `.postOffload` then `.dataChange` dropped
  against one pass → the single re-pass is `.dataChange`, `skipIfUnchanged: false`.
- **`testRetryChainTerminates`** — N consecutive floored triggers produce N-bounded, strictly
  increasing retry instants and never a second outstanding retry.

### Builds (no CI covers these targets — `app-build.yml` triggers only on `pull_request` to `main`)

```bash
xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test
python3 Tools/doc_comment_lint.py && python3 Tools/i18n_audit.py --ci origin/main
```

No package code changes, so no `swift build`/`swift test` in `Packages/` is required.

---

## Risks — what could regress

**A night left unscored because the floor rejected the only trigger that would have scored it.**
The single most important risk; it is the exact failure `#899-A` exists to prevent. Mitigations, in
order: (1) the floor **defers, never drops** — every rejection schedules one coalesced retry through
`refreshAfterCompletedBackfill`, so worst-case latency is one floor interval (≤15 min) plus the bounded
backfill wait; (2) the cadence tick shortens its sleep to floor expiry, so it is a second bound;
(3) the `BGProcessingTask` (`analyzeIfStale`) bypasses the floor entirely and is a third.
**Accepted residual gap:** the retry `Task` does not survive process death. If iOS kills the app
between rejection and retry, the deferral is lost and the data waits for the relaunch tick (which runs
~6 s after launch, and is itself floored only if a pass completed <15 min ago). Worst observed compound
case ≈35 min stale. Bounded, no data loss, and strictly better than the current "score it now, twice,
hot" behaviour. Pinned by `testFlooredPostOffloadTriggerStillEventuallyRunsExactlyOnePass`.

**The #1196 Trends/streak flicker.** This plan does **not** narrow the fingerprint gate and does not
change what any pass computes — only how often passes run. The specific #1196 mechanism (a churned
window flickering between full and empty across an offload storm) is reduced, not increased, by
running fewer passes. The one place it could have reappeared is designed around explicitly: the
post-offload floor check sits **after** `repo.refresh(days: 120)` (`AppModel.swift:731`), not before,
so a floored pass still refreshes the dashboard cache from the newly-offloaded raw. Skipping that
refresh is what would look like data loss.

**Interaction with the existing `skipIfUnchanged` post-offload gate.** The floor sits strictly above
it. A floored pass never reads the fingerprint and never advances `noop.analyzeWatermark`, so no data
is ever marked scored that was not scored. The two gates cannot deadlock each other: `skipIfUnchanged`
returning early does **not** advance `lastPassEndedAt` (that write lives at the completion site,
`:2141-2146`, which a skip never reaches), so a genuine change arriving right after a skip is not
floored by the skip.

**A fingerprint hiccup wedging the floor.** Guarded against by construction: the `lastPassEndedAt`
write is gated on `!Task.isCancelled` only, never on `!wmKey.isEmpty` (see review finding #6 for the
identical bug this branch already fixed once).

**Bar cosmetics.** A floored post-offload never enters the analyze phase, so the bar ends around 70%
and disappears rather than sweeping to 100%. Acceptable (early returns already do this) and preferable
to the alternative reviewed in the previous plan's correction #7 finding 5 — flipping the bar's phase
for a pass that will not run.

**Timezone / clock changes.** `.run` on a backwards clock and on any local-day rollover, both tested.
A traveller crossing a date line gets one extra pass, which is the safe direction.

---

## Passes-if

Re-pull the log after a morning sync and compare. Metrics are **suspension-adjusted** where noted —
`re-score: done` reports wall clock, so any pass spanning a process suspension must have the
suspension subtracted before comparison (detect it by a `Reconnecting in Ns` line whose follow-up
`Connecting` is more than a few seconds later).

| metric (~44 min window) | baseline 2026-08-23 | measured 2026-08-25 (post-fix-1) | target after this plan |
|---|---|---|---|
| re-score passes | 10 (per 47 min) | 5 | **≤ 3** |
| total re-score time, adjusted | 21.5 min | ~7.9 min (20.3 raw) | **≤ 3 min** |
| passes overlapping a backfill | 1 (573 s) | 1 (small, 1–3 s) | **0** |
| `done` lines with no matching `trigger=` line | n/a | 1 | **0** (Commit 1) |
| `analyze: floored` lines | n/a | 0 (string does not exist) | **≥ 1** (proves the mechanism fired) |
| worst single pass, adjusted | 573 s | ~279 s (1021 s raw) | **unchanged, ~250-280 s expected** |

**Why ≤ 3 and not the previous plan's ≤ 2.** A 900 s floor plus one launch-time pass permits at most
`1 + floor(44.4/15) = 3` passes in a 44-minute window. Claiming ≤ 2 would require a ~22 min floor,
which buys little and costs freshness. The previous plan's ≤ 2 was never derivable from its own design.

**Why the worst-pass row is explicitly not a target.** Pass 1 was the launch-time cadence tick with
`dayCache reused=0/21` — a cold-cache 21-day pass. The floor does not touch it (the previous session's
`lastPassEndedAt` is stale by then, so it runs, correctly). Commit 4 stops it *overlapping* an offload
but does not shorten it. Per-pass cost is out of scope for this plan and still needs a profiler.
Recording the row so the next session does not read it as another missed target.

**Measurement command:**

```bash
xcrun devicectl device copy from --device 819D37A3-B45A-56CF-9FEC-40D460EC74F8 \
  --domain-type appDataContainer --domain-identifier com.bly.noop \
  --source "Library/Preferences/com.bly.noop.plist" --destination /tmp/prefs.plist

plutil -extract strapLog.tail json -o - /tmp/prefs.plist | python3 -c '
import json, re, sys
lines = json.load(sys.stdin)
ms   = [int(m.group(1)) for l in lines for m in [re.search(r"re-score: done .* in (\d+) ms", l)] if m]
trig = [l for l in lines if "re-score: trigger=" in l]
flr  = [l for l in lines if "analyze: floored" in l]
defr = [l for l in lines if "deferred (a rescore is in flight)" in l]
print(f"passes={len(ms)} trigger_lines={len(trig)} floored={len(flr)} offload_deferred={len(defr)}")
print(f"total={sum(ms)/60000:.1f} min  worst={max(ms or [0])/1000:.1f} s  (WALL — subtract suspensions)")
for l in flr + trig: print(" ", l)
'
```

Overlap is read by hand: for each `re-score: trigger=` line, check whether any `Backfilling`/
`Connecting`/`ackHistoricalChunk` activity falls between it and its `re-score: done`.
