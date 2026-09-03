# Backlog — future investigation

Non-urgent follow-ups that aren't a shipped claim awaiting data (see
[`PENDING_VALIDATION.md`](PENDING_VALIDATION.md) — deliberately narrow, TODOs don't belong there) and
aren't yet scoped into a plan. No hook surfaces this file; it's a holding pen. Pick an item up by
writing a proper `docs/superpowers/plans/` file when someone's ready to act on it.

## sleep-composite-consistency-term-unwired (2026-09-03)

**Observation:** three consecutive nights (2026-09-01, -02, -03) all displayed a Rest/Sleep-
performance score of **94** on the Sleep screen despite visibly different underlying metrics (487 /
549 / 554 min asleep; 94.5% / 94.5% / 95.8% efficiency). Confirmed NOT stale data — verified against
the on-device `dailyMetric` rows directly. Owner's reaction: a night that "felt" like it should score
close to 100 tops out at 94, repeatedly — worth understanding why the ceiling is there.

**Root cause found while investigating (not yet acted on):** `AnalyticsEngine.Rest.composite(daily:
needHours: consistency:)` (`Packages/StrandAnalytics/Sources/StrandAnalytics/AnalyticsEngine.swift:1047`)
takes an optional `consistency` parameter that defaults to `nil` → the neutral placeholder `0.5`
(`neutralConsistency`, `:961`), and a `needHours` parameter that defaults to the flat
`defaultNeedHours = 8.0` (`:951`) rather than the already-implemented `personalizedNeedHours(...)`
(`:995`). **Every call site in the codebase uses the bare `Rest.composite(daily:)` form — none passes
a real `consistency` or `needHours` override**, confirmed by grep across `Strand/`, `StrandiOS/`,
`Packages/`: `SleepModel.swift:377`, `SleepView.swift:428`, `CoupledView.swift:107`,
`WeeklyDigestView.swift:57`, `IntelligenceEngine.swift:1924,2073,2672,2690,2708`,
`Repository.swift:2242`. This is apparently deliberate for now —
`RestCompositeDailyDefaultsTests.swift` explicitly locks in "defaults only" behavior today, with a
comment anticipating a future change to wire in the personalized values.

Effect: with duration and restorative-share both clamping to their max of 1.0 once a night is long
and efficient enough (which happens easily — see the worked numbers below), and efficiency near but
under 1.0, the **consistency term is the only one that could push a score materially higher, and it
is pinned at exactly `0.10 × 0.5 = 5` points forever**, regardless of how regular the person's actual
sleep schedule is. That caps the practical ceiling at **~95**, not 100, for any night — explaining why
several good-but-different nights cluster in the low-to-mid 90s instead of spreading out.

Worked example (hand-computed against the real `dailyMetric` rows, weights `wDuration=0.50
wEfficiency=0.20 wRestorative=0.20 wConsistency=0.10`):

| Night | Sleep min | Efficiency | Duration score | Efficiency score | Restorative score | Consistency (neutral) | Composite |
|---|---|---|---|---|---|---|---|
| 09-01 | 487.1 | 94.5% | 1.0 (clamped) | 0.945 | 1.0 (clamped) | 0.5 | 93.9 |
| 09-02 | 548.7 | 94.5% | 1.0 (clamped) | 0.945 | 1.0 (clamped) | 0.5 | 93.9 |
| 09-03 | 554.3 | 95.8% | 1.0 (clamped) | 0.958 | 1.0 (clamped) | 0.5 | 94.15 |

**To investigate later (not scoped, no plan yet):**
- Whether to wire a real trailing bedtime/wake-time regularity signal into `consistency` at the
  display-path call sites, and/or thread `personalizedNeedHours` through instead of the flat 8h.
- `sleep_performance` (this composite) is also read by `RecoveryScorer` as a Charge input
  (`IntelligenceEngine.swift:2672,2690,2708`) — any reweighting here shifts Charge/Recovery too,
  historically, not just the Sleep screen. Needs the physiological-signal-change process
  (`docs/CONTRIBUTING.md` §"Derive a physiological signal") and a Kotlin twin, not a quick tweak.
- Confirm with the owner whether a ~95 practical ceiling is actually undesirable, or just
  under-explained on screen (a copy/tooltip fix would be much cheaper than a scoring change).
