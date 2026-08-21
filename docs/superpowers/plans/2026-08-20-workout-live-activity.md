# Workout mode for the NOOP Live Activity

## Context

**The gap is not the in-app screen — it's the glanceable one.**

`Strand/Screens/LiveWorkoutView.swift` (523 lines) is a complete in-exercise screen and it ships on
iOS: elapsed TIME, live HR hero tinted by zone, live EFFORT with an intensity word, a Z1–Z5 rail with
the band caption, an AVG/PEAK/EFFORT card, plus GPS distance/pace and BLE sensor cards that self-gate.
The screenshot in `tmp/IMG_7756.PNG` is that screen, string-for-string. It is reachable from Live
(`LiveView.swift:133`), Workouts (`WorkoutsView.swift:267`) and the Today indicator via
`NavRouter.openActiveWorkout()`.

What does *not* exist is a workout view you can see **without unlocking the phone**. NOOP has a Live
Activity, but it is a *strap-connection* activity, not a workout one:

- `NOOPActivityAttributes.ContentState` carries only `bpm`, `recovery`, `bonded`, `effort`
  (`StrandiOSShared/LiveActivityAttributes.swift:8-31`). No elapsed time, no sport, no zone, no
  avg/peak.
- `attributes.title` is hardcoded `"Live HR"`.
- It is driven by `model.live.$heartRate` / `$connected` (`StrandiOS/App/StrandiOSApp.swift:126-152`)
  and starts/ends on the **BLE link**, never on `activeWorkout`. It looks identical whether or not a
  workout is recording.
- `effort` is `day?.strain` from `repo.cachedWidgetAnchor()` — **the whole day's strain**, not the
  workout's `liveStrain`.

So mid-ride the Dynamic Island shows a heart, a bpm, and a day-strain number. The outcome this plan
delivers: while a workout is recording, the Lock Screen and Dynamic Island show *that workout's*
time, heart rate, zone, effort and calories — and revert to today's ambient Live-HR presentation the
moment it ends.

Reference for what a glanceable workout surface can carry: the sibling project's
`/Users/brian/dev/OpenCircuit/ios/WorkoutWidget/WorkoutLiveActivity.swift` (TIME / CALORIES / HEART,
self-ticking clock, honest `--` and dimming when HR goes stale).

### Decisions already made by the owner

| Question | Answer |
|---|---|
| Metrics | Time + HR + Effort + Zone, **plus** Distance/Pace when GPS is live |
| Coexistence | **Extend the existing activity** with optional workout fields — no second `ActivityAttributes` type, no end/start swap |
| Calories | **In scope**, labelled an estimate |

---

## Phase 0 — three mockups, then stop

**This is a hard gate.** Build the mockups, publish, hand over the link, and **stop**. Do not start
Phase 1 until the owner has picked one.

Mockups cannot be built in plan mode (only the plan file is writable), so this is execution step 1.

One Artifact, three variants side by side, dark ground, each showing every Live Activity surface:

- Lock Screen / banner (full-width rounded rect)
- Dynamic Island **compact** (leading + trailing)
- Dynamic Island **minimal**
- Dynamic Island **expanded** (leading / trailing / bottom)
- the GPS-live state of the banner, and the no-GPS state, so the collapse is visible

The three differ on **information hierarchy**, not cosmetics:

- **A · Faithful translation.** Mirrors the in-app screen's stack. Banner: sport header, big TIME,
  then HR / EFFORT, with a slim Z1–Z5 rail beneath. Expanded DI: sport+zone leading, HR trailing,
  TIME + Effort bottom.
- **B · Zone-forward.** The zone is the organizing element — keyline and HR both tinted
  `StrandPalette.hrZoneColor(zone)`, zone name spelled out, the rail is the dominant graphic, TIME
  demoted. DI compact-trailing becomes a `Z3` chip. For training *to* a zone.
- **C · Glance grid.** Four equal cells — TIME · HR · EFFORT · CAL — with the zone reduced to a thin
  tinted keyline, and a second row (DIST · PACE) that appears only when GPS is live. Densest.

Constraints on the mockups:

- Annotate every colour and type choice with the `StrandPalette` / `StrandFont` / `NoopMetrics` token
  it maps to, so implementation is mechanical. Token inventory is in "Design tokens" below.
- **Nothing on a mockup that NOOP cannot supply.** Show Effort's real pre-scoring state (see the
  10-minute gate below) and HR's real absent state.
- Load the `artifact-design` skill before writing the file.

---

## Phase 1 — widen the shared ContentState

`StrandiOSShared/LiveActivityAttributes.swift`

Add workout fields to `ContentState`, **all optional with `nil` defaults**, matching the precedent set
by `effort` ("OPTIONAL with a nil default so an activity started by an older build still decodes"):

```swift
public var workoutStart: Date?      // nil ⇒ no workout ⇒ render today's Live-HR layout
public var sport: String?           // ActiveWorkout.sport
public var sportSymbol: String?     // WorkoutTypeIconography.systemSymbolName(for:)
public var zone: Int?               // HRZoneSet.zoneNumber(forBPM:), 0 = below Z1
public var workoutEffortText: String?   // pre-formatted, honours EffortScale; nil until it scores
public var workoutKcal: Int?
public var distanceText: String?    // pre-formatted, honours UnitSystem; nil unless GPS is live
public var paceText: String?
public var avgHr: Int?
public var peakHr: Int?
```

**Why `workoutStart` goes in `ContentState`, not `attributes`:** the activity is frequently *already
running* (started by strap connection) when the workout begins. `attributes` is immutable after
`Activity.request`, so an immutable start date would force an end/start swap — exactly what the
"same activity" decision rules out. `Text(timerInterval:)` takes any `Date`, so it still self-ticks
with **zero** pushes to advance the clock.

**Why the unit-dependent fields are pre-formatted strings:** the widget target `NOOPiOSWidgets`
compiles only `StrandiOSWidgets` + `StrandiOSShared` and depends only on `StrandDesign`
(`project.yml`, `NOOPiOSWidgets:`). `UnitFormatter`, `EffortScale` and `UnitPrefs` live in
`Strand/Data/Units.swift`, which is **app-target only**. Formatting app-side reuses
`UnitFormatter.effortDisplay(_:scale:)`, `UnitFormatter.distanceFromMeters(_:system:)` and
`UnitFormatter.paceFromSecPerKm(_:system:)` rather than duplicating unit prefs into the extension.
Raw values (`bpm`, `zone`, `workoutKcal`, `avgHr`, `peakHr`) stay typed.

`workoutStart == nil` is the single switch between the two layouts.

**Implementation note:** the field list above was drafted before Phase 0's mockups were chosen. What
actually shipped drops `sportSymbol` (`WorkoutTypeIconography.systemSymbolName(for:)` lives in
`StrandDesign`, which the widget target already depends on, so the widget derives the icon from
`sport` directly — no separate field needed) and drops `avgHr`/`peakHr` (Option D's chosen layout,
the Glance Grid + Zone-Forward synthesis, never shows them — Cal takes that slot instead). Adding
fields the shipped design doesn't render would be dead payload weight with no consumer.

---

## Phase 2 — feed it from the workout

### 2a. ⚠️ Keep realtime HR armed for the life of the WORKOUT, not the life of the SCREEN

**Without this the whole feature is decorative.** Verified: every `startRealtimeHR()` caller is
screen-scoped — `LiveWorkoutView:93` (sheet), `LiveView:669` (Live tab),
`LiveSessionRunner:119`, `MenuBarContent:295`. `startWorkout()` (`AppModel.swift:644`) takes **no**
reference. So the exact scenario this feature exists for — start a workout, dismiss the sheet, lock
the phone — drops `realtimeWanters` to 0 and calls `ble.stopRealtime()`.

`LiveWorkoutView.swift:85-91` documents what follows on the hardware on hand: *"On a WHOOP 5/MG live
HR only flows while the puffin realtime stream is armed… left `model.bpm == nil` —
captureWorkoutSample bailed on every sample and endWorkout silently discarded the empty session."*
That is #681, and dismissing the sheet reintroduces it. The Lock Screen would show a ticking clock
with `—` HR, `—` Effort and 0 kcal, and the session would save empty.

Fix — move the reference to workout scope, where `activeWorkout` becomes non-nil / nil:

- `startWorkout()` (`:644`) → `startRealtimeHR()`
- `rehydrateActiveWorkout()` (`:725`) → `startRealtimeHR()` on the branch that actually assigns
  `activeWorkout`, so a relaunch mid-workout stays balanced
- `endWorkout()` (`:739`) → `stopRealtimeHR()` immediately after `activeWorkout = nil`, which is
  **before** the `samples.count >= 2 || route != nil` discard guard returns — so both the saved and
  the discarded path release exactly once

`realtimeWanters` is ref-counted (`AppModel.swift:1094-1114`) and clamped at 0, so this composes with
`LiveWorkoutView`'s existing pair: opening the sheet over an armed workout takes the count 1→2, and
closing it 2→1 without disarming.

The process is not suspended while this runs — `project.yml:255-256` declares the `bluetooth-central`
background mode (and `location` for GPS routes), so capture continues with the screen off.

Android's `requestRealtimeHr`/`releaseRealtimeHr` (`ui/AppViewModel.kt:2268`) has the same
screen-scoped shape at `ui/LiveWorkoutScreen.kt:79-80`. That is behaviour parity, not a formula or a
stored value, so `docs/CROSS_PLATFORM.md` does not oblige it in this commit — but note it as a known
divergence rather than leaving it silent.

### 2b. Live calories on `ActiveWorkout` — `Strand/App/AppModel.swift`

`captureWorkoutSample()` (`:827`) already recomputes `avgHr`, `peakHr` and `liveStrain` per sample.
Add kcal alongside, using the **same call the save path already makes** at `:790`:

```swift
Calories.estimateBoutCalories(w.samples, profile: up, hrmax: Double(profile.hrMax),
                              restingHR: repo.today?.restingHr ?? StrainScorer.defaultRestingHR).0
```

`Calories.estimateBoutCalories` (`Packages/StrandAnalytics/.../WorkoutDetector.swift:498`) weights
each sample by its real elapsed gap capped at 150 s, so it is already correct on a partial window.
No new formula, no `docs/PENDING_VALIDATION.md` entry.

**Use the measured resting HR on the live path, matching `endWorkout()` (`:781`).** Do *not* mirror
the effort divergence here. Live effort deliberately uses the default 60 while the saved effort
re-scores against `repo.today?.restingHr` — that is #983 and intentional. Calories have no such
reason, and copying it would make the visible kcal jump the instant the workout saves.

**Expose `liveKcal` as a derived value, do NOT add it to `ActiveWorkoutPersistence.Snapshot`.**
kcal is a pure function of `samples` + profile, so it recomputes for free on rehydrate. Adding it to
the snapshot would make it a *stored value*, which under `docs/CROSS_PLATFORM.md` drags in the Kotlin
codec twin (`android/…/ui/ActiveWorkoutStore.kt` + `ActiveWorkoutPersistenceTest.kt`) for no benefit.
Keeping it derived keeps this commit free of any Kotlin obligation.

### 2c. Drive the activity from workout state — `StrandiOS/App/StrandiOSApp.swift:126-152`

Both `liveActivity.update(...)` sites gain the workout payload, built from `model.activeWorkout` and
`model.profile.hrZoneSet` (and `model.gpsRecorder` for the GPS pair). Keep the existing
`cachedWidgetAnchor()` memo — it is there because these closures fire on every HR tick.

Also add a third drive site: `.onChangeCompat(of: model.activeWorkout != nil)`, so the banner flips
into and out of workout mode at start/end rather than waiting for the next HR tick.

### 2d. Three lifecycle fixes in `StrandiOS/Widgets/LiveActivityController.swift`

These are the difference between "works on a bench" and "works on a ride". All three trace to the
same documented WHOOP 5 trait — `BLEManager.swift:3833-3838`: 0x2A37 on a 5/MG *"can lull for >120 s
when the wearer is at rest / off-wrist… a FAMILY trait of the 5/MG HR profile"*, which is why
`bounceFuse` is 600 s for `.whoop5` vs 120 s for `.whoop4`.

1. **Let the activity start with no HR yet.** `guard bpm != nil else { return }` (`:54`) means that
   starting a workout during a lull produces **no activity at all**. During a workout the ticking
   clock alone justifies the surface. Relax to `bpm != nil || workoutStart != nil`.
2. **Do not end on disconnect while a workout is recording** (`:50-53` currently returns early on
   `!connected`). A strap dropout mid-workout would otherwise wipe the Lock Screen. Keep the activity
   up, render HR as `—`, let TIME and Effort continue. End only when the workout ends *and* the link
   is down.
3. **Extend `staleAfter` (`:24`, currently 120 s) while a workout is active.** At 120 s the OS greys
   out a perfectly healthy workout activity during a normal lull. Match the strap's own tolerance
   (600 s), not the resting-glance default.

The existing 2 s update throttle, the `isStarting` re-entrancy gate, the `Activity.activities`
re-adoption and the `UnitPrefs.liveActivityEnabled()` opt-out all stay untouched.

---

## Phase 3 — render it

`StrandiOSWidgets/NOOPLiveActivity.swift`

Branch on `context.state.workoutStart`:

- **nil** → today's presentation, byte-identical to what ships now. Do not regress it.
- **non-nil** → the chosen mockup's layout.

Mechanics that matter:

- Elapsed uses `Text(timerInterval: start...Date.distantFuture, countsDown: false)` so the OS advances
  it with no pushes. Give it `.multilineTextAlignment(.center)` — it reserves a wider frame for
  `H:MM:SS` and left-aligns inside it, which visibly drifts the digits off their label (OpenCircuit
  hit exactly this; see its `ElapsedText` comment).
- Zone tint comes from `StrandPalette.hrZoneColor(zone)`; `zone == 0` means below Z1 — fall back to
  `StrandPalette.effortColor`, as `LiveWorkoutView.swift:160` already does.
- Keep the `#759` fix in `bannerStat` / `statColumn`: centre-aligned label-over-value with
  `.fixedSize()`, so a value narrower than its label does not drift.
- Distance/pace render only when `distanceText != nil`. The layout must collapse cleanly — this is
  the common case, since GPS arms only for `WorkoutCatalog.Sport.isDistanceSport`.

### Honesty rules — non-negotiable, and they must be visible in the mockups

- **Effort is `nil` for roughly the first 10 minutes.** `StrainScorer.strain` returns `nil` until
  `count >= 600` **or** (`count >= 20` **and** ts-span `>= 600 s`) — `StrainScorer.swift:302-311`.
  `AppModel` coalesces that to `0` via `?? 0`. Send `workoutEffortText = nil` while the scorer has
  not scored and render `—`. **Do not show `0` for ten minutes.**
- **HR renders `—` when absent or stale**, never a frozen held value. This is the same discipline
  `LiveActivityController.swift:47-49` already applies ("keying off `bonded` left a frozen,
  fabricated 'live' HR on the Lock Screen indefinitely").
- **Calories are labelled an estimate.** They are a Keytel/Harris–Benedict model over HR, not a
  sensor reading.
- Live effort deliberately differs from the saved number: the live path uses the default resting HR
  of 60 while `endWorkout()` (`:781`) re-scores against the measured `repo.today?.restingHr`. Do not
  "fix" this — it is #983, and it is intentional.

---

## Cross-platform

**No analytics or stored-value twin is required.** Per `docs/CROSS_PLATFORM.md` the twin obligation
covers decoders, analytics formulas, migrations and stored values. This commit adds none: calories
reuses a formula that already has its twin at `android/…/analytics/WorkoutDetector.kt:524`, and
`liveKcal` is deliberately kept out of the persistence snapshot (Phase 2b) so no stored value
changes. Live Activities are iOS-only; Android has no ActivityKit.

Word the commit message that precisely — "no analytics/stored-value twin", not "no twin" — because
two **behaviour** divergences are being created knowingly and should be named:

- realtime-HR arming moves to workout scope on Apple (Phase 2a) while Android keeps it screen-scoped
  at `ui/LiveWorkoutScreen.kt:79-80`
- the in-app `LiveWorkoutView` will show no kcal while the Lock Screen does

**Out of scope, note but do not do:** adding a fourth stat to the in-app AVG/PEAK/EFFORT grid, the
matching row in `android/…/ui/LiveWorkoutScreen.kt`, and the Android arming change are each sensible
follow-up commits, separate under the one-concern rule.

---

## Design tokens (mockups and implementation use these only)

`StrandPalette` — `hrZoneColor(_ zone: Int)`, `zone1`…`zone5`, `effortColor` / `effortDeep` /
`effortBright` / `effortGradient`, `strainColor(_:)`, `metricRose`, `metricAmber`, `statusCritical`,
`textPrimary` / `textSecondary` / `textTertiary`, `surfaceBase` / `surfaceRaised`, `hairline`, `accent`.

`StrandFont` — `rounded(_:weight:)`, `number(_:weight:)`, `overline` + `overlineTracking` (0.45),
`captionNumber`, `caption`, `footnote`, `subhead`, `headline`.

`NoopMetrics` — `spaceHalf` 2, `space1` 4, `space2` 8, `space3` 12, `space4` 16, `space6` 24;
`cardRadius`, `pillRadius`, `cardInnerPadding` 16.

Widget-side helpers already available: `WorkoutTypeIconography.systemSymbolName(for:)` and
`StrainGauge.stateLabel(forFraction:)` (both in `StrandDesign`, which the widget target depends on).

---

## Files

| File | Change |
|---|---|
| `StrandiOSShared/LiveActivityAttributes.swift` | widen `ContentState` (Phase 1) |
| `Strand/App/AppModel.swift` | **realtime-HR ref moves to workout scope (2a — the blocker)**; `liveKcal` from `Calories.estimateBoutCalories` (2b) |
| `StrandiOS/App/StrandiOSApp.swift` | pass workout payload at both `update` sites + a third on workout start/end (2c) |
| `StrandiOS/Widgets/LiveActivityController.swift` | start without HR, workout-aware end, longer stale window (2d) |
| `StrandiOSWidgets/NOOPLiveActivity.swift` | the two-mode layout (Phase 3) |
| `StrandTests/…` | new tests, below |

---

## Verification

**Compile the app yourself — CI never does.** `app-build.yml` triggers only on `pull_request` to
`main`, and work here merges locally, so that trigger never fires. Nothing else compiles the iOS
targets. Done three times during implementation (once per commit) — `xcodebuild … build`, including
the `NOOPiOSWidgets` extension target this feature ships in, succeeded each time with no warnings in
any touched file.

```bash
xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
cd Packages/StrandAnalytics && swift test        # Calories/StrainScorer regressions
```

Run tests through the `qa-runner` subagent so verbose output stays out of context.

**Correction found during implementation — this section originally over-promised.** `StrandTests` is
a **macOS** unit-test target (`project.yml`, `StrandTests: platform: macOS`), and it cherry-picks
exactly one `StrandiOSShared` file into its sources (`WidgetSnapshot.swift`) — `LiveActivityAttributes.swift`
isn't among them, and `NOOPActivityAttributes` is `#if os(iOS)` + `import ActivityKit`, which has **no
macOS availability at all**. There is no iOS unit-test target anywhere in `project.yml`. So tests 1, 2,
3 and 5 below — everything that touches `ContentState`, `LiveActivityController`, or
`workoutActivityPayload()` (all iOS-app/widget-target-only) — **cannot be written** without adding a
new test target, which is a boundary change needing its own plan (token rule 10), not a fix to slip
into this one. They're covered by the on-device pass below instead; nothing here was silently skipped.

**What actually ran, in `Packages/StrandAnalytics` (pure, cross-platform, real `swift test`):**

- `WorkoutLiveActivityKcalParityTests.swift` (new) — pins the claim `AppModel.liveKcal` actually
  depends on: `Calories.estimateBoutCalories` returns a real value at the exact `samples.count >= 2`
  gate boundary; scoring the identical partial window twice (the "live tick" vs. "save time" call)
  agrees exactly, since it's the same pure function on the same input, not two formulas that happen to
  usually agree; and the measured resting HR is NOT interchangeable with the package's flat default —
  swapping one for the other must change the result, or `liveKcal`'s #983-matching fix is inert.
- The realtime-HR ref-count balance (2a) was verified by reading, not by test, because
  `realtimeWanters` is `private` with no accessor and no existing test in this codebase constructs
  `AppModel()` directly (a real, deliberate absence — BLE/notifications/etc. side effects on
  construction) worth respecting rather than being first to break: `grep -n "activeWorkout = nil"`
  across `Strand/` + `StrandiOS/` finds exactly one site, inside `endWorkout()` itself, so the
  `stopRealtimeHR()` added there is the only release path and nothing can leak the reference by
  clearing `activeWorkout` some other way. `grep` for `.endWorkout()` call sites finds exactly two —
  `LiveWorkoutView.swift:109` and `LiveView.swift:155` (the latter is what `LiveView`'s second "End
  workout" button's confirm alert resolves to) — both route through the one function. Also checked:
  `rehydrateActiveWorkout()`'s new `startRealtimeHR()` call fires from `AppModel.init()` at a point
  where `ble` is already constructed (`init()` builds `self.ble` before calling `rehydrateActiveWorkout()`),
  and `BLEManager.startRealtime()` → `send(...)` explicitly guards `state.connected` and no-ops safely
  when nothing is connected yet — the same safe-when-disconnected path every `LiveView`/`LiveWorkoutView`
  open already exercises, so arming one instant earlier during `init` introduces no new risk.

**New unit tests, corrected list** (supersedes the original 6-item list this section shipped with):

1. ~~`workoutStart == nil` byte-identical rendering~~ — not unit-testable (see above); covered by
   code structure (the widget's `if let start = context.state.workoutStart { … } else { … }` branch
   preserves the pre-existing ambient view verbatim in its own `else`) and the on-device pass.
2. ~~`ContentState` back-compat decode~~ — not unit-testable; the back-compat CONTRACT (every new field
   optional with a `nil` default) is structural, verified by reading `LiveActivityAttributes.swift`.
3. ~~Effort text `nil` vs. non-nil across the `StrainScorer` gate~~ — not unit-testable at the
   `workoutActivityPayload()` layer; the underlying `StrainScorer.strain` nil-gate is already covered
   by the package's existing `StrainScorerTests`, and `workoutActivityPayload()`'s own logic is a
   one-line `.map` pass-through with no branching to get wrong.
4. **`liveKcal`/saved-kcal parity — DONE.** `WorkoutLiveActivityKcalParityTests.swift`, three tests,
   `Packages/StrandAnalytics`, all passing (see qa-runner result below).
5. ~~Distance/pace `nil` when not recording~~ — not unit-testable at the `workoutActivityPayload()`
   layer; the gate it uses (`isRecording && pointCount > 0`) is copied verbatim from
   `DistancePaceRowIfPresent`'s existing, already-shipped guard.
6. **Realtime-HR ref-count balance (2a) — verified by reading**, not by test (see above): the single
   `activeWorkout = nil` site and the two `endWorkout()` call sites are both confirmed via `grep`.

**On-device, on a real strap** — BLE cannot be CI-tested, so state exactly what was exercised:

- WHOOP 5.0 is the hardware on hand. **The WHOOP app must be force-quit and disconnected first** —
  one BLE central owns the strap at a time.
- **The 2a regression test, and the most important one:** start a workout, **dismiss the sheet**,
  lock the phone, wait several minutes. HR must keep updating on the Lock Screen and the saved
  workout must contain samples. Before 2a this is exactly the case that silently captured nothing.
- Start a workout from Live. Lock the phone. Confirm the banner shows workout mode with a ticking
  clock, and that the clock keeps ticking with the app backgrounded and no HR arriving.
- Start a workout while HR is lulling (strap at rest) — the activity must appear anyway (fix 2d.1).
- Confirm Effort reads `—` for the first ~10 minutes, then becomes a number.
- Confirm the Dynamic Island compact/minimal/expanded all render (long-press to expand).
- Walk out of range for >2 minutes: the activity must stay up with HR `—`, not disappear.
- End the workout: the banner must revert to the Live HR presentation without an end/start flicker.
- Repeat once with a distance sport to see the GPS row appear, and once without to see it collapse.

---

## Process

- On `main` and clean. **Branch first** per `CLAUDE.md`: `feat/live-workout-activity`. Do not edit
  until that is settled.
- One concern per commit. Suggested split: (1) the realtime-HR arming fix in 2a — it stands on its
  own as a bug fix and is worth landing separately; (2) the workout Live Activity — `ContentState`
  widening, live kcal, drive sites, rendering; (3) the three controller lifecycle fixes in 2d.
- **Do not merge to `main` until the on-device strap pass above has actually run.** The three commits
  compile clean and the analytics-side claim (kcal parity) is test-pinned, but the feature's actual
  correctness — the 2a regression case above all — is unverified until it's been run on the WHOOP 5.0
  on hand. State that plainly rather than merging on "it compiled."
- When verified on-device: `git merge --ff-only` into `main`, delete the branch. **No push** — the
  local commit is the deliverable.
- Copy this plan to `docs/superpowers/plans/` if it is worth keeping; `~/.claude/plans/` is scratch.
- `/wrapup` afterwards: `REPO_MAP.md` needs no change (no new top-level structure).
