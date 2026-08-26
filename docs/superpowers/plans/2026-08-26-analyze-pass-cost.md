# Fix: the morning re-score pass is cold, and cold costs 13 minutes

## Context

The owner's complaint, verbatim: *"In the morning, when I open the noop app, it grabs last night's data
and computes the sleep score; this compute warms up my phone, drains the battery and takes about 10
minutes."*

Three prior sessions have already worked this area — `2026-08-23-sync-rescore-storm.md` (18 commits)
and `2026-08-25-rescore-floor.md` (5 commits), all merged to `main`. **Both attacked how OFTEN the pass
runs. Neither touched what ONE pass costs**, and both said so explicitly:

> *"Not attempted: which sub-step of the 48 s dominates. That needs a profiler."* (2026-08-23)
> *"Out of scope, deliberately: per-pass cost (still unprofiled — the previous plan's position stands)."* (2026-08-25)

The frequency work succeeded: duty cycle went 46% → 18%, and the 900 s floor is confirmed firing on
device. **The complaint survived it, because the complaint is per-pass cost.** That is this plan.

### Measured evidence — 2026-08-26, this device, on the post-floor build

Pulled this session: `xcrun devicectl … com.bly.noop.plist` → `strapLog.tail`, 2000 lines,
06:47:14 → 09:06:48. The build is confirmed post-fix (it emits `analyze: floored (trigger=postOffload,
0s since last pass, retry in 899s)`, a string introduced by the rescore-floor branch).

| # | start | trigger | dayCache | duration | end |
|---|---|---|---|---|---|
| 1 | 08:09:12 | `idle-tick` (the launch cadence tick) | **`reused=0/21 size=8`** | **775.4 s (12 m 55 s)** | 08:21:56 |
| — | 08:21:56 | `postOffload` | — | **floored**, retry in 899 s | — |
| 2 | 08:36:49 | `forced` (the 899 s floor retry) | **`reused=0/21 size=8`** | **266.3 s (4 m 26 s)** | 08:41:26 |
| 3 | 09:05:46 | `forced` | `reused=7/21 size=8` | ≤ 62 s (log ends mid-pass) | — |

**1041.7 s = 17.4 minutes of re-score in a 32-minute window.** Pass 1 alone is the owner's "about 10
minutes" — it is 12 m 55 s.

Four facts that determine the fix:

1. **`size=8`, not 21.** The store holds **8 nights** with data; the other 13 day-slots log
   `SKIPPED hrSamples=0`. The `reused=N/21` denominator counts loop iterations, not cacheable days
   (upstream fixed this in #1556; we don't have it). So `7/21` is really **7 of 8 — a warm pass**, and
   `0/21` is **fully cold**.
2. **The launch pass is structurally cold, always.** `dayScanCache` is in-memory only and
   `dayScanCacheConfigSig` starts `""` (`IntelligenceEngine.swift:87`), which never equals a real
   signature — so the first pass of every process drops the whole cache and misses every day. *The
   morning IS the launch case*: opening the app starts the cadence loop, whose first tick fired 08:09.
   Neither the 900 s floor nor the `BGProcessingTask` can help this; both control *when* a pass runs,
   and this is about what it costs when it does.
3. **A second FULL cold pass follows the launch pass.** Pass 2 reports `reused=0/21` when 7 of its 8
   days were sitting in the cache pass 1 had just filled. A per-day key change from the 08:25/08:35
   offloads cannot explain it — those rows landed only on 2026-08-26, so they would have invalidated
   one day, not eight. Pass 3 then reuses 7/8, so whatever moved, moved **once, between the first and
   second pass of the process, and then settled.** Pass 2's 266 s is pure waste: identical inputs,
   byte-identical output (see 4).

   **Two mechanisms can produce `reused=0`, and the log cannot currently tell them apart:**
   (a) a pass-global signature change (`:799-802`, `dayScanCache.removeAll()`), or (b) per-day
   *eligibility* failing — `dayCacheEligible` false (any Sleep/HRV/Steps Test Centre trace active) or
   `DeviceFamily.forRegistryDevice` returning nil (registry unreadable, active row missing
   model/brand), either of which skips reuse for every day while still writing the cache back at
   `size=8`. **(b) is ruled out here on evidence, not assumption:** pass 3 reused 7/8 in the same
   process with the same registry, and the device's own prefs (pulled this session) show the only
   Test Centre key present is `testcentre.active.workouts = False` — no Sleep/HRV/Steps trace exists,
   let alone active. So (a) is what happened. Commit 1 makes this distinction readable rather than
   argued.
4. **The output is stable across all three passes.** Every `sleep day=` line is identical
   (475/479/490/500/555/404/466/nil) and every `hrv day=` line is identical. This **rules out**
   upstream's headline mechanism for #1538 — there, cold passes landed on *different* sleep totals,
   which fed back into the signature and oscillated all night. Ours converges after one extra pass,
   because every night here matches a stable `source=imported:apple` session rather than drifting.
   **Do not carry upstream's "self-perpetuating" framing into this fork; it does not reproduce here.**

### Which signature field moved — NOT established

The whole-cache drop is certain (fact 3). **Which of the 13 fields in `dayCacheConfigSig`
(`:783-795`) changed is not**, and this plan does not pretend otherwise. The strong candidates are the
three that `:790-792` folds from `computeHabitualSleep`:

```swift
String(sleepNeedHours.bitPattern),
sleepConsistency.map { String($0.bitPattern) } ?? "nil",
habitualMidsleepSec.map { "\($0)" } ?? "nil",
```

All three derive from `computeHabitualSleep(windowEnd: now)` (`:714-727`), which reads the **computed
`-noop` sleep sessions the previous pass banked** (`persistComputedScores`). Pass 1 banks/updates
2026-08-26's session; pass 2 reads a changed `nightlyHours`; pass 2 re-banks the same value; pass 3
sees it unchanged. That fits the observed 0 → 0 → 7 exactly. The comment directly above the signature
asserts the opposite of this and is wrong:

> *"All are pass-global 28-night / profile / toggle values (stable across an offload storm …)"*

That is the same false claim upstream's #1402 already had to correct once for `baselines1`. **But
"fits the observation" is not "proved."** Commit 1 exists to close that gap before Commit 2 acts on it.

### Per-night cost — measured, and ~9× worse than upstream's

Pass 2: 266 s / 8 nights = **33 s per night**, cold. Upstream's instrumented cold pass is 75–85 s for
21 nights ≈ **3.8 s per night**, on comparable hardware (iPhone 17,2 vs this iPhone 18,2) and
comparable per-night volume. Ours reads ~140 k rows per night-window (`hr=35630 rr=30755 grav=35601
steps=35601` from the 08-19 `NO-NIGHT` line, plus skin/spo2/events), 8 nights ≈ **1.1 M rows per pass**.

**That 9× gap is unexplained and this plan does not explain it.** It could be read volume, the R-R
over-count path (2026-08-20 shows `rr=53121 coverage=1.85`), main-actor resume contention, or SQLite
page-cache state. Upstream built the `prep`/`score` split (#1559) for exactly this decision and their
maintainer stated the rule: *"`prep` ≫ `score` → build the sliding window … `score` ≫ `prep` →
narrowing windows is a dead end."* We do not have that line. Commit 1 ports it.

### Where this fork sits against upstream

Fork `MARKETING_VERSION` **10.1.1**; upstream `ryanbr/noop` is at **10.6.0**. Three upstream changes in
this area are **not** in this tree (verified — none of `a659b9cf`, `8ea1b9c5`, `3e83c993` resolve here):

| upstream | what | our tree | take it? |
|---|---|---|---|
| #1556 (`a659b9cf`) | trigger attribution + honest `reused=N/M` denominator | denominator **missing**; attribution **already ours** (`0f45525e`) | **denominator half only** — Commit 1 |
| #1557 (`8ea1b9c5`) | background survivability: owed-work, 20 s budget, escalation | we built our own | **no** — collides with `SyncAnalyzeBackgroundScheduler` |
| #1559 (`3e83c993`) | `analyzeRecent cost prep=Nms score=Nms` | **missing** | **yes, verbatim** — Commit 1 |
| #1575 | `dayCacheEligible = true` + `hrvWindowDetail` in the per-day key | **missing** (we have the old gate at `:777`) | **yes** — Commit 1b |
| #1402 (`2853884e`) | "fold the confidence tier, not the baseline value" | commit present, **production change absent** | **nothing to port** — see below |

**Do not port #1556's attribution half.** Upstream infers the trigger from two booleans
(`!force ? "idle" : (skipIfUnchanged ? "post-offload" : "forced")`). We have a real `AnalyzeTrigger`
enum carried through the call, which is strictly better. Ours stays.

**#1402 has no fix to draw from — verified, and this corrects the 2026-08-23 plan.** That plan
recorded that `2853884e` "added only two test files; the production change its message describes never
landed," and read as a fork-local gap. It is not. `2853884e` **is upstream's own merge commit for
#1402**, it is tests-only there too (`ScoreConfidenceCacheSigTests.swift` 43+,
`ScoreConfidenceCacheSigTest.kt` 46+, zero production lines), and **upstream's `IntelligenceEngine.swift`
at HEAD still folds `String(describing: baselines1.hrv)` and `String(describing: baselines1.restingHR)`
raw** — fetched and diffed this session. The PR body describes a change its own diff does not contain.
So this is not a port we skipped; it is a fix that exists nowhere, and writing it is original work.

**The open half of #1538 (the sleep-derived signature fields) is likewise unfixed upstream.** Upstream's
signature block at HEAD is byte-identical to ours apart from one extra field, `effortMethodGlobal`
(added by #1545 for an Effort-method toggle this fork does not have — note it if that toggle ever
lands here). Commit 2 is our own work, not a port.

Reading upstream is fine and is all that happened here. Per `CLAUDE.md`, **nothing from this tree goes
back** — no PR, no issue comment, no posting these measurements. Issue numbers above are references.

## The owner's proposed fix — questioned

The owner proposed: *"maybe not processing as hard, put it in the background, maybe engage iPhone's
efficiency processor and process it while the phone is in the background. Then send an alert when the
sleep data has been computed. I'm ok with taking 15-20 minutes."* Taking those one at a time:

1. **"Put it in the background" — already shipped, and it is not the failing path.** Commit 5 of the
   2026-08-23 plan built `SyncAnalyzeBackgroundScheduler` (a real `BGProcessingTask`) and it is on
   `main`. More to the point: backgrounding **relocates** energy, it does not reduce it — the battery
   cost is the integral, and the integral is unchanged. Upstream's #1538 measurements show
   backgrounding makes it *worse* in wall-clock: 10 s of work sliced across 25–70 min of wakeups,
   because iOS grants the suspended process tiny execution slices. And the reported symptom is *"when I
   open the app"* — that is the **foreground** path by definition.
2. **"Engage the efficiency processor" — not directly selectable, and mostly already done.** There is
   no API to pin work to E-cores; QoS class is the only lever, and the dominant loop is already
   `Task.detached(priority: .utility)` (`:817`). One real residual worth a line, not a plan: confirm
   the `WhoopStore` actor's reads inherit `.utility` rather than running at the caller's priority.
3. **"Send an alert when computed" — already shipped.** `Strand/System/AnalyzeCompleteNotifier.swift`,
   with an opt-in toggle in `AutomationsView`.
4. **"I'm OK with 15-20 minutes" — this is the one to refuse.** On pass 3, **7 of 8 nights cost
   nothing at all** — that is measured, and it is the whole argument: the expensive passes are
   re-doing work the device had already done. (Pass 3's total is *not* known — the log ends mid-pass,
   so the ~62 s of elapsed output is a lower bound on elapsed time, not a pass cost. Don't cite it as
   one.) Budgeting 15–20 minutes accepts the defect instead of fixing it, and it does not even buy the
   stated goal: stretching the same work over a longer window lowers peak temperature somewhat but
   leaves total battery drain untouched, because drain is the integral. **Both stated goals — don't
   heat, don't drain — are served by making the pass cheap, not by spreading it out.**

**The one instinct that is exactly right is "not processing as hard."** That is this plan. The
1041 s measured this morning contains ~266 s of provably duplicated work (Commit 2) and a 775 s pass
that had 7 of its 8 nights already computed in a previous process (Commit 3). Neither is a scheduling
problem, which is why three scheduling fixes did not touch it.

**One thing the owner did not ask for and should have:** there is **zero thermal awareness** anywhere
in this path (`grep thermalState` over `Strand/`, `StrandiOS/`, `Packages/` returns nothing but
`isLowPowerModeEnabled` in unrelated motion/diagnostic code). Given "don't heat up the phone" is a
stated goal, Commit 5 adds it — honestly framed as symptom mitigation, not a fix.

## Branch

**On `main` now; this is a code change.** Per `CLAUDE.md` §git branching, ask the owner before editing
and recommend a name: **`fix/analyze-pass-cost`**. One concern per commit, `git merge --ff-only` when
verified, delete the branch, no push.

---

## Commit 1 — `diag(analyze): split the pass cost, and name the field that dropped the cache`

**Why first.** Commits 2 and 4 both act on a mechanism that is currently *inferred*. This plan's own
Context section says which inference is unproven; shipping a fix on top of an unproven mechanism is
exactly what the two prior plans correctly refused to do about per-pass cost. One morning's log after
this commit settles both questions. No behaviour change.

**File.** `Strand/Data/IntelligenceEngine.swift`.

Three diagnostic lines, all `diagnosticSink?` calls (plain `String`, unlocalized — `i18n_audit`
unaffected):

- **The cost split — port upstream #1559 verbatim.** Its Swift side is **25 added lines, 0 deleted**,
  entirely inside the detached scan loop, and the surrounding code matches ours. Two `Double`
  accumulators (`dayPrepSeconds`, `dayScoreSeconds`); `tPrep0` before the `hrSamples` read, folded in
  at the `analyzeDay` call site; `tScore0` bracketing `analyzeDay`. **Keep its subtlety:** the
  `hr.count >= 200` early-`continue` adds its elapsed prep *before* continuing, so sparse days —
  **13 of 21 on this device** — don't silently vanish from the tally. Emits
  `analyzeRecent cost prep=<n>ms score=<n>ms` beside the reuse line. They deliberately do **not** sum
  to the pass total; read them as a ratio. Both are locals in the `@Sendable` closure, returned via the
  existing `skippedDayLines` channel, so nothing new crosses the actor boundary.
- **The signature diff, and the eligibility state alongside it.** When
  `dayCacheConfigSig != dayScanCacheConfigSig` (`:799`), log **which component changed** before
  `removeAll()`. Build the signature as a named `[(String, String)]` and emit
  `analyzeRecent dayCache DROPPED — sig changed: <name>[, <name>…]`. Names only, never values —
  `sleepNeedHours`, `habitualMidsleepSec`, `baselines1.hrv`, etc.
  **Emit `eligible=<bool> ownerFamilyNil=<n>` on the same line** (or on the `reused=` line when no drop
  occurred). Without it a future `reused=0` stays ambiguous between mechanism (a) and mechanism (b) in
  fact 3 above — and **Commit 2 is gated on this line**, so it has to be decisive, not merely better.
  Commit 1b removes half of mechanism (b) by making `dayCacheEligible` unconditionally true; the
  residual is `DeviceFamily.forRegistryDevice` returning nil per day, which `ownerFamilyNil` counts.
  (Upstream hit a related registry-absence bug in #1567 — a defaulted `ownerSource` a caller silently
  omitted, which silently changed the skin-temp scale. Their remedy was the same: make the absence say
  so in the log.) This is the most load-bearing diagnostic in the plan.
- **The denominator** — port upstream #1556's half we lack (`var dayCacheCacheable = 0`, incremented
  where a day is freshly scored *and* stored under a key; the line becomes
  `reused=<reused>/<reused + cacheable> size=<n> days=<maxDays>`). `reused=N/M` must count **cacheable**
  days, not loop iterations, so a store with 8 real nights in a 21-day window can reach `8/8` instead
  of topping out at `8/21`. Today's `7/21` reads like a broken cache and is in fact a healthy one;
  that misreading has already cost one investigation. **Do not port the attribution half** — see the
  upstream table.

**Smallest correct change:** three log lines and one restructure of the signature array from
`[String]` to `[(name, value)]` (`.map(\.1).joined()` preserves the string byte-for-byte, so no cache
is invalidated by this commit itself — assert that in the commit message).

**Kotlin twin: not required.** Diagnostic strings on the iOS log sink. `docs/CROSS_PLATFORM.md:98-101`
binds decoders, analytics formulas, migrations and stored values; a log line is none of those.
Precedent: `2026-08-25-rescore-floor.md` Commit 1, same reasoning.

**Verification.** Build (below). Then one morning's log:
`grep -c 'analyzeRecent cost'` must equal `grep -c 're-score: done'`.

---

## Commit 1b — `perf(analyze): stop an active Test Centre trace disabling the reuse cache` (port of #1575)

**Not load-bearing for the measured symptom — take it anyway.** This device's Test Centre state was
pulled this session: the only key present is `testcentre.active.workouts = False`. No Sleep/HRV/Steps
trace exists, so this changes nothing about the 2026-08-26 numbers. It is a **latent** defect that
makes the diagnostic cost what it measures — upstream's own report: `reused=0/0 size=0 days=21` and
`prep=211663ms score=38583ms`, **13 minutes of CPU in a 70-minute session, just for having a trace on.**
Since Commits 1 → 4 will involve turning traces on to investigate, fixing this *before* that work is
the difference between measuring the pass and measuring the instrument.

**Mechanism (Swift side is 15+/4-, and our surrounding code matches upstream's pre-fix state):**

- `IntelligenceEngine.swift:777`: `let dayCacheEligible = !(sleepTraceActive || hrvTraceActive ||
  stepsTraceActive)` → `let dayCacheEligible = true`. **Swift is safe by construction — verified in
  THIS tree, not carried over from upstream's claim about its own code.** `DayScan` carries
  `sleepTrace`/`hrvTrace`/`stepsTrace` (`:168`, `:173`, `:177`); a cache hit does
  `out.append(cached.scan)`; and the main-actor fold replays **all three** from the scan — `:1407`
  (`.sleep`), `:1410` (`.hrv`), `:1413` (`.steps`) — for every entry in `out`, hits included. **That
  replay is the load-bearing half of the port**: if it covered only some of the three, flipping the
  gate would silently drop trace lines. Confirmed it covers all three. The gate was the only cost.
  (Upstream's Kotlin side needed 110 lines because it emits traces inline; ours needs none of that.)
- `Packages/StrandAnalytics/…/AnalyzeRecentDayCache.swift`: add `hrvWindowDetail: Bool` to `cacheKey`,
  appended to the key as `:d`/`:s`. **Required by the above**: the per-window HRV *detail* is emitted
  only for `dayStart == nowLocalMidnight`, so once traces are replayed, the night cached as "today"
  would keep replaying detail it is no longer entitled to after midnight — breaking the cache's
  promise that a reused night is indistinguishable from a fresh one.
- **Keep upstream's `hrvTraceActive &&` gate on that flag.** With the HRV trace off the flag describes
  nothing, but it would still flip at midnight and invalidate yesterday — charging every user an extra
  day's re-score to protect lines they never see. This detail is easy to drop when porting and costs
  a day per rollover if you do.
- **The parameter is deliberately not defaulted** upstream. Honour that: #1567 was caused by exactly a
  defaulted parameter a caller silently omitted. Every call site states its answer.

**Kotlin twin: not required.** Our Kotlin has the pre-#1575 inline-emit shape, and upstream's Kotlin
port is 110+ lines of recorder plumbing that cannot be compiled or tested here. The Swift fix stands
alone; the two engines already emit diagnostics at different points, which is why upstream needed very
different work on each side. **Say plainly in the commit message that Android keeps the old gate.**

**Test.** Extend `AnalyzeRecentDayCacheTests.swift` (upstream's PR carries 31+/12- of exactly this):
the flag changes the key; everything else about the key is unchanged.

---

## Commit 2 — `perf(analyze): stop the pass signature churning on the pass's own banked output`

**GATED on Commit 1's `sig changed:` line naming at least one of the three sleep-derived fields.** If
it names something else, fix that instead and rewrite this commit — do not ship the change below
because the plan predicted it.

**Mechanism.** `:790-792` folds the raw `bitPattern` of `sleepNeedHours` / `sleepConsistency` /
`habitualMidsleepSec`, each derived from sleep sessions a *previous pass banked*. Any drift, however
small, drops all 8 cached days. Apply #1402's move — **fold a tier, not a value**:

- `sleepNeedHours` → round to the nearest **0.25 h**. The value feeds Rest's need term; a 15-minute
  quantum is far below what changes a displayed score, and it is stable against the minute-level drift
  a re-banked session produces.
- `sleepConsistency` → round to **2 decimal places** (it is a 0…1 regularity index).
- `habitualMidsleepSec` → round to the nearest **5 minutes** (300 s). It selects an overnight band;
  5-minute resolution is well inside the band's own width.

**These are signature-only quanta. They must NOT change the values passed to `analyzeDay`** (`:1091-
1093`, `:1587`) — the full-precision values keep flowing to scoring, so no score changes. State that
explicitly in the commit message and pin it with a test.

**Why quantize rather than drop the fields from the signature.** They are genuine scoring inputs; a
real change (the user's habitual bedtime actually shifting, a new night extending the 28-night window)
*must* still invalidate. Dropping them would stale every cached night against a real profile change,
which is a correctness regression. Quantizing keeps the invalidation and removes only the noise.

**Expected effect:** the second full cold pass per launch disappears — 266 s of the measured 1041 s.

**Also here, or as its own commit — the #1402 fix that exists nowhere.** `:785-786` still folds
`String(describing: baselines1.hrv)` and `String(describing: baselines1.restingHR)` raw. #1402's PR
body describes folding only the HRV baseline's **confidence tier** (`ScoreConfidence.charge`) and
dropping `restingHR` from the signature entirely — a good fix, and the reasoning in that PR body is
worth reading before writing it. **But its diff is tests-only, in this tree and upstream alike, and
upstream's signature at HEAD is byte-identical to ours here** (verified this session). There is
nothing to port; writing it is original work, and it should be its own commit with its own test rather
than riding along with the quantization.
**Honest status: latent here, not load-bearing.** Verified this session — `baselines1` folds `hist`,
which is `store.dailyMetrics(deviceId: deviceId, …)` where `deviceId` is the **imported** `my-whoop`
id (`:662`, and the comment there says so). The 2026-08-23 plan measured `my-whoop` at **0 rows**, so
`baselines1` is constant on this owner's channel and cannot be what dropped the cache. It becomes
live the moment a WHOOP CSV export is imported. **Confirm `my-whoop` dailyMetric is still 0 before
relying on that**; if it is non-zero, this is load-bearing and belongs in front of the quantization.
Ship it either way — it is a real defect with a proven upstream fix — but do not claim it fixed the
measured symptom.

**Kotlin twin: not required.** The signature is built in memory and compared only to itself; the
strings are explicitly documented as not requiring cross-platform identity (`:782-783`). Quantizing
changes **which** days recompute, never **what** they compute to. Not a decoder, formula, migration,
or stored value. **Kotlin cannot be compiled on this machine (no JDK, no Android SDK) and no CI
covers it — say so in the commit message.**

**Test (`Packages/StrandAnalytics`, runs in CI without a strap).** Extend
`AnalyzeRecentDayCacheTests.swift` or add a sibling: a 3-minute drift in `habitualMidsleepSec` and a
sub-quantum drift in `sleepNeedHours` produce the **same** signature component; a 20-minute midsleep
shift and a 0.5 h need change produce a **different** one. Mirrors #1402's guard-test shape.

---

## Commit 3 — `perf(analyze): persist the day-scan cache across launches`

**The commit that targets the owner's actual sentence.** "When I open the app in the morning" is a
cold-launch pass by construction (fact 2). Commits 1, 2, 4 and 5 do nothing for it.

**Mechanism.** Persist `dayScanCache` + `dayScanCacheConfigSig` so a relaunch starts warm. Expected
effect on this morning: pass 1's 8 nights drop to the 1–2 that genuinely changed overnight.

**Why this is safe for today's card — verified, not assumed.** The 2026-08-25 plan's §6 flagged this
exposure for the *fingerprint* gate, so it is worth settling here. `sleepReadWindowEnd`
(`:306-309`) returns `nextMidnight` for any **past** day — a fixed boundary independent of `now`; only
today's window ends at `now`. So a past day's read window is stable across passes *and* across
launches, and its key (`AnalyzeRecentDayCache.cacheKey(owner:hrCount:hrMaxTs:skinAnchorRaw:)`) is a
genuine content fingerprint over that fixed window. **Today always misses** — live HR moves `hrCount`
and `hrMaxTs` every second — so today's card is recomputed on every pass exactly as it is now. That is
the same property, arrived at from the opposite direction, that makes the whole-store fingerprint gate
untrustworthy in the foreground.

**The real risk, and the design requirement it creates.** A change that alters a day's score **without
moving its HR fingerprint** is currently healed by accident, because a relaunch empties the cache.
Persisting removes that accidental heal. The known cases:

- a manual sleep edit / hand-logged block (`sleepEditedDaily`)
- a dismissed sleep span (`DismissedSleepSpans`)
- a device-registry change that re-points a day's owner
- the #899 banked-sleep heal and the #313 Effort rescore

**Requirement: every one of those paths must explicitly invalidate the persisted cache** (drop it
wholesale — they are rare and user-driven, so a full drop costs nothing). They already funnel through
`analyzeRecent`'s `.dataChange` trigger (`AnalyzePolicy.swift`), which gives a single clean seam:
**`.dataChange` drops the persisted cache before running.** That is one line, it is provably
conservative, and it means the persisted cache can only ever be stale in a way the user's own next
action clears. Enumerate the call sites in the commit message.

**What a `DayScan` actually holds — checked this session, because it decides the design.**
`IntelligenceEngine.swift:154-199`: scalars, optional diagnostic strings, and one
`AnalyticsEngine.DayResult`. The trace arrays (`sleepTrace`/`stepsTrace`/`hrvTrace`) are empty unless
a Test Centre mode is active — confirmed off on this device. `DayResult`
(`Packages/StrandAnalytics/…/AnalyticsEngine.swift:60-133`) carries two collections that matter:
`sessionMotionByStart: [Int: [Double]]` and `sessionSleepStateByStart: [Int: [Int]]`. **Both are on a
30 s grid** (`:103`, same grid as `stagesJSON`) — so ~960 entries per 8 h night, **not** per-sample.
Order of ~tens of KB per night, a few hundred KB for 8 nights. **That is affordable to write once per
pass; the "stop and re-plan" tripwire does not fire.**

**Storage — two shapes. Decide before writing; they differ a lot in blast radius.**

**(A) Rebuild the cache from what is already banked — recommended.** Every scored night's output is
*already* persisted by `persistComputedScores` (DailyMetric + sessions), and the motion/sleep-state
bands are re-derivable from the store (`bandSleepStateSamples`, `:2572`). So the only thing that must
newly persist is the **per-day cache key** — one short string per day (`owner|hrCount|hrMaxTs|anchor`)
plus the pass-global signature. That is a handful of KB in `UserDefaults` or a tiny file, with no new
`Codable` conformances at all. On a cold start, a day whose freshly-read fingerprint matches the
persisted one loads its banked result instead of re-scoring.

**(B) Serialize `DayScan` wholesale to a file in `Application Support`.** Conceptually simpler, but it
requires `Codable` on `DayResult`, `DailyMetric`, `SleepSession`, `CachedSleepSession`,
`ExerciseSession`, `ChargeDriver`, `SkinTempRelative`, `ScoreConfidence` and
`PrimarySessionRestingHR.Coverage` — a broad new public surface on a cross-platform package, and a
persisted encoding of analytics types is arguably a **stored value** under
`docs/CROSS_PLATFORM.md:98-101`, which would bind a Kotlin twin.

**Recommend (A).** It is far smaller, adds no public conformances, keeps a derived cache out of both
the schema and the cross-platform contract, and degrades safely — a missing or mismatched key just
costs the cold pass we have today. **Open question to settle first:** whether every field the cached
scan supplies can in fact be reconstructed from banked state, or whether some (`rhrLine`, `respLine`,
`hrvDiag`, `primarySessionRHR*`) are diagnostics-only and can simply be omitted on a cache hit. If a
*scored* field turns out to be unreconstructable, fall back to (B) and accept the twin obligation.

**Either way:** exclude the persisted state from `.noopbak` (precedent — `noop.analyzeWatermark` is
not in `BackupSettings.swift`), so restoring a backup cannot import another device's scan cache.

**Kotlin twin: not required under (A)** (no schema, no migration, no stored analytics value — a
device-local scheduling/derivation cache). **Probably required under (B).** Another reason to
prefer (A).

**Test.** Round-trip encode/decode; a persisted entry whose `hrCount` moved is a miss; a `.dataChange`
trigger drops the file. All in `Packages/StrandAnalytics` or `StrandTests` — no strap needed.

---

## Commit 4 — `perf(analyze): slide the night window instead of re-reading 54 h on a 24 h stride`

**GATED on Commit 1 measuring `prep` ≫ `score`.** If `score` dominates, **do not build this** — say so
in the plan's follow-up and stop. Upstream's maintainer set that rule and it is the right one.

**Prior on the ratio, from upstream's own instrumented logs — encouraging, but not ours.** Their
WHOOP 4.0 trace-on case: `prep=211663ms score=38583ms` (**84% reads**). Their WHOOP 5/MG cold passes:
`prep≈46-48 s` vs `score≈28-34 s` (**~60% reads**). Both point the same way. **This is a prior, not a
measurement of this device** — a 5/MG with 8 dense nights and this store's density may split
differently, and the unexplained 9× per-night gap above means our profile is not upstream's. Measure
before building.

**Mechanism.** Each day reads `[dayStart − 30 h, nextMidnight]` — a **54 h** window on a **24 h**
stride, so every row is materialised ~**2.25×** per pass. The loop already walks newest→oldest, so it
can read only the incremental 24 h per step and drop the tail, keeping today's peak memory while
materialising 2.25× fewer rows. Ceiling is ~53% of read time.

**Explicitly rejected** (upstream tried it): reading the whole span once and slicing. On this store
that is ~1.1 M rows resident and OOM on big-import libraries is a known failure of this exact path.

**Also worth pricing while here, but not committing to:** 13 of 21 day-slots on this device are empty
and still cost a `resolveDayOwner` + `hrFingerprint` + `hrSamples` probe each. The 2026-08-23 plan
called this "small" and did not measure it. Commit 1's `prep` number will show whether it still is.

**Kotlin twin: judgment call, and the harder one in this plan.** This changes *how* rows are read, not
what is computed — but it is close enough to the analytics path that the twin should be written unless
the read shape is genuinely iOS-only. Decide when the code exists; **write it if in doubt**, and say
plainly that it was not compiled.

---

## Commit 5 — `feat(analyze): defer an automatic pass while the device is thermally stressed`

**Small, honest, and the direct answer to "don't heat up the phone."** There is currently no thermal
awareness in this path at all.

**Mechanism.** In `AnalyzePolicy.decide`, add a `thermalState` parameter. When
`ProcessInfo.processInfo.thermalState` is `.serious` or `.critical`, return
`.deferUntil(now + forcedFloorSeconds)` for `.postOffload` and `.idleTick`. **`.dataChange` and
`.background` still bypass** — a user action must never be silently swallowed by heat, and the
`BGProcessingTask` is already rationed by iOS. The existing `deferredRescoreDueAt` retry machinery
carries it; nothing new is needed on the scheduling side.

**Frame it honestly in the commit message and in any UI copy: this is symptom mitigation, not a fix.**
It stops NOOP *compounding* a hot phone; it does not make the pass cheaper. If Commits 2–4 land, this
should rarely fire — and if it fires often afterwards, that is a signal the cost work is incomplete.

`AnalyzePolicy` is pure today and must stay pure — pass the thermal state **in** as a parameter, read
at the call site. Do not have the policy read `ProcessInfo` itself.

**Kotlin twin: not required.** Scheduling, and `ThermalState` has no Android equivalent with the same
semantics. Same reasoning as `2026-08-25-rescore-floor.md` Commit 2.

**Test.** `AnalyzePolicyTests.swift` — `.serious` defers `.idleTick`, `.dataChange` runs anyway,
`.nominal` is byte-identical to today's behaviour (every existing case must stay green).

---

## Commit 6 — `docs(analyze-pass-cost): record the 2026-08-26 measurement`

Add this plan file. Add a `docs/PENDING_VALIDATION.md` entry — *"the morning sync no longer heats the
phone"* is, for the third time, a claim only a future morning can confirm; the passes-if table below
is the check. Note in the entry that the two prior entries
(`sync-rescore-storm-fix`, `rescore-floor`) targeted frequency and this one targets cost, so a future
session does not read three overlapping entries as three attempts at the same thing.

---

## Related upstream, read and not acted on

Swept this session. Recorded so a future session does not re-derive the map:

- **#1005** (closed) — the root "battery consumption high, mostly background" issue everything in this
  area cites. **#1146** (open) — raw-row retention, the long-term ceiling; see below.
- **#1395 / #1396** — the per-day reuse cache itself, and its extension to WHOOP 5/MG. **Both already
  in this tree.** **#1346 / #997** — the redundant per-day store re-read (`daySliceFromNight`).
  **Already here.**
- **#1197 / #1196** — "stop the post-offload re-score flickering daily history to empty". This is the
  regression our own code comments cite as the reason the fingerprint gate is whole-store, and the
  reason `2026-08-25-rescore-floor.md` places the floor check *after* `repo.refresh(days: 120)`.
  Nothing to take; it is why some things here are shaped the way they are.
- **#1392** (closed issue) — the per-device fingerprint reading 0 on Oura / Watch / re-added-strap
  installs. The documented blocker on narrowing the fingerprint gate; see
  `2026-08-25-rescore-floor.md` §6.
- **#1567** — device registry absent on some scoring passes, silently changing the skin-temp scale.
  Mostly a Kotlin defaulted-parameter bug; its useful idea (make the absence log itself) is folded
  into Commit 1's `ownerFamilyNil`.
- **#1164** (open) — "Rest score shows a provisional value before the night is offloaded, then jumps".
  Adjacent symptom, different cause. Not this plan.
- **#1598** (open, 10.5.0, iOS, WHOOP MG) — "Values not computing until a week later": past days stuck
  on "No Data", then computed retroactively about a week on. Same family as ours, **no fix exists**,
  and no diagnosis in the thread. Worth watching rather than drawing from — if Commit 1's diagnostics
  ever show days scoring and then reverting here, this is the issue it matches.

## Deliberately NOT in this plan

- **Raw-row retention (upstream #1146, open).** Every pass folds over the full store and cost grows
  linearly with history — this store is ~37 MB/day (~1.1 GB/month). A retention window is the only
  thing that bounds it long-term. It touches **stored-data lifetime** and needs a migration and a
  decision about what re-derivation still requires full-resolution raw. Per `CLAUDE.md` token rule 10,
  that needs its own plan file. **Name it in the follow-up; do not start it here.**
- **Porting upstream #1557.** This fork built its own background path with a different design. See the
  table above.
- **The `analyzeRecent` check-and-set race** and the **stale `consecutiveAutoContinues` snapshot** —
  both already recorded with reasons in the two prior plans. Neither is a cost defect.
- **The whole-store `hrFingerprint()` gate.** `2026-08-25-rescore-floor.md` §6 explains at length why
  it is left alone (#1392). Nothing here changes that. Note that Commit 3's finding — past-day windows
  are `now`-independent — is new evidence that would be relevant if a future session re-attempts it.

## Verification

**No CI covers the app targets** (`app-build.yml` triggers only on `pull_request` to `main`; work here
merges locally, so it never fires). Build it yourself:

```bash
xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test
cd Packages/StrandAnalytics && swift test
python3 Tools/doc_comment_lint.py && python3 Tools/i18n_audit.py --ci origin/main
```

**On device — the real acceptance test.** Commits 1–2 need one morning before Commits 3–4 are even
decidable. Pull the log the same way this plan's baseline was pulled:

```bash
xcrun devicectl device copy from --device 819D37A3-B45A-56CF-9FEC-40D460EC74F8 \
  --domain-type appDataContainer --domain-identifier com.bly.noop \
  --source "Library/Preferences/com.bly.noop.plist" --destination /tmp/prefs.plist
python3 - <<'PY'
import plistlib, re
L = plistlib.load(open("/tmp/prefs.plist","rb"))["strapLog.tail"]
for l in L:
    if any(k in l for k in ("re-score:","dayCache","analyzeRecent cost","analyze: floored")):
        print(l[:200])
PY
```

Note the plist key is `strapLog.tail` with a literal dot — `plutil -extract` treats it as a path and
fails. Use `plistlib`, as above. (The prior plans' `plutil -extract strapLog.tail` command does not
work; corrected here.)

### Passes-if

| metric (one morning, ~35 min from first pass) | baseline 2026-08-26 | target |
|---|---|---|
| total re-score time | **1041.7 s (17.4 min)** | **≤ 180 s** |
| full cold passes (`reused=0/N`) per launch | **2** | **≤ 1** after Commit 2; **0** after Commit 3 |
| worst single pass | **775.4 s** | **≤ 120 s** after Commit 3 |
| passes whose `sig changed:` names a sleep-derived field | n/a (line does not exist) | **0** after Commit 2 |
| `analyzeRecent cost` lines | n/a | **= number of `re-score: done` lines** (Commit 1) |
| output identity | 8 `sleep day=` / `hrv day=` lines, stable across passes | **byte-identical to baseline** |

**The last row is the one that matters most.** Every commit here is a cache or read-shape change and
**none of them may change a single computed number.** Diff the `sleep day=` / `hrv day=` / `rhr day=` /
`resp day=` lines against this morning's log; any difference is a regression, not an improvement, and
stops the branch.

**Why ≤ 180 s and not lower.** Commit 2 removes ~266 s. Commit 3 turns the 775 s launch pass into a
1–2 night pass at the measured ~33 s/night ≈ 70 s, plus today's always-recomputed night. That lands
near 100–150 s without assuming anything from Commit 4, which is gated and may not be built. Claiming
a number that depends on an ungated commit is what made the previous two plans' targets unreachable.

**Not a target: the 9× per-night gap against upstream** (33 s/night vs 3.8 s/night). Commit 1 measures
it; nothing here is committed to closing it. If `prep` ≫ `score`, Commit 4 addresses part of it and
#1146 addresses the rest, in a separate plan. Recording the row so a future session does not read it
as another missed target.
