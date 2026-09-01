import Foundation

/// Per-day reuse identity for `IntelligenceEngine.analyzeRecent`'s pass-1 loop.
///
/// The drain this closes (#1005): on a heavy user (21 nights of history, ~178 k HR rows/night, a 1.26 GB
/// store) every `newData` re-score re-read *every* night's raw streams and re-ran `analyzeDay`, even though
/// a post-offload only ever adds rows to the 1–2 most-recent days — measured at a median ~4.6 min / pass,
/// all CPU, and it fires back-to-back through an offload storm. Pass 1 already keeps only each night's small
/// result and NOT the raw streams, and — by that loop's own design note — "every field except recovery is
/// baseline-independent, so pass 2 only re-scores the cheap recovery composite". So a night whose scored
/// inputs are unchanged since it was last scored re-produces a byte-identical result: the engine keeps an
/// in-memory `[day: (key, DayScan)]` cache and reuses the scan when this key matches, skipping the reads +
/// `analyzeDay`. A miss is byte-for-byte the current full path; the cache never touches banking (every day
/// still flows into pass 2), so there is no data-loss surface.
///
/// The cache is in-memory and per-device — it never persists and never crosses the `.noopbak` boundary — so
/// it only has to invalidate correctly on one platform; the Kotlin twin (`AnalyzeRecentDayCache`) mirrors
/// the shape but the two key strings are NOT required to match byte-for-byte across platforms.
public enum AnalyzeRecentDayCache {
    /// The per-day reuse key. Reuse a cached day iff this string is unchanged since the scan was cached.
    ///
    /// - `hrCount` / `hrMaxTs`: the night-window HR fingerprint (row count + newest timestamp) — the SAME
    ///   change witness the whole-pass gate at the top of `analyzeRecent` already trusts, applied here at
    ///   day granularity. Any new/removed HR row moves one of the two.
    /// - `skinAnchorRaw`: the WHOOP 4.0 window-wide skin-temp anchor (nil for a 5/MG, or when unresolved).
    ///   It is window-wide, so a re-anchor caused by *another* night's skin data shifts this night's skin
    ///   conversion without moving this night's HR fingerprint — folding it in makes that invalidate reuse.
    ///   Encoded by raw bit-pattern so the equality check is exact and locale-free.
    /// - `owner`: the resolved owning device id the fingerprint was measured against. The fingerprint is
    ///   already device-scoped, so this is belt-and-suspenders for the **multi-strap** case (a user with
    ///   both a 4.0 and a 5/MG): when a day's resolved owner flips between straps, keying on the owner makes
    ///   the reuse invalidate **explicitly**, rather than relying on two different devices never producing an
    ///   identical `count`+`maxTs` for the same window.
    ///
    /// Inputs that feed `analyzeDay` but are pass-global rather than per-day (profile, baselines1, sleep
    /// need / consistency, habitual midsleep, tz, stager toggles) are NOT in this key — the engine drops the
    /// whole cache when its pass config signature changes, which covers them.
    public static func cacheKey(owner: String, hrCount: Int, hrMaxTs: Int, skinAnchorRaw: Double?,
                                // #1575: whether this day is the one entitled to emit the PER-WINDOW HRV
                                // DETAIL (`dayStart == nowLocalMidnight`, and only while the HRV trace is
                                // on). Now that an active trace no longer disables reuse outright, this has
                                // to invalidate: the night cached as "today" with its detailed trace becomes
                                // an ordinary night after midnight, and a fresh scan would emit only the
                                // one-line summary for it. Without this the reused night would keep
                                // replaying detail it is no longer entitled to — and the cache's whole
                                // promise is that a reused night is indistinguishable from a freshly-scored
                                // one. Costs one day's re-score per local-midnight rollover, and ONLY while
                                // a trace mode is on (the caller gates the flag on `hrvTraceActive`, so with
                                // the trace off this is constantly `false` and the default path is
                                // unchanged).
                                //
                                // DELIBERATELY NOT DEFAULTED. Upstream's #1567 was caused by precisely that
                                // — a defaulted parameter a caller silently omitted, which quietly changed
                                // the skin-temp scale and made a night score to nothing. Every call site
                                // states its answer.
                                hrvWindowDetail: Bool) -> String {
        let anchor = skinAnchorRaw.map { String($0.bitPattern) } ?? "nil"
        return "\(owner)|\(hrCount):\(hrMaxTs):\(anchor):\(hrvWindowDetail ? "d" : "s")"
    }
}

/// The PASS-GLOBAL half of `analyzeRecent`'s cache identity: how the three `computeHabitualSleep`-derived
/// inputs are encoded into the pass config signature.
///
/// The defect this closes (measured 2026-08-27, this device). The signature folded these three by raw
/// `bitPattern`, and all three are derived from the computed `-noop` sleep sessions **a previous pass
/// banked**. So the pass fed its own output back into its own cache identity: pass 1 banks the night, pass
/// 2's `computeHabitualSleep` reads a fractionally different `nightlyHours`, the signature moves, and the
/// whole cache is dropped — every night re-read and re-scored. The device log named it outright:
///
///     analyzeRecent dayCache DROPPED — sig changed: sleepNeedHours,sleepConsistency
///
/// …on a pass whose 9 nights were all sitting in the cache the previous pass had just filled, and which
/// then produced byte-identical output for every one of them. 255 s of pure waste, every launch.
///
/// **Quantize rather than drop** — the original fix, and still what `habitualMidsleepSec` uses below.
/// These are genuine scoring inputs: a real change (a habitual bedtime actually shifting, a new night
/// extending the window) MUST still invalidate, or every cached night goes stale against a real profile
/// change — a correctness regression traded for speed. Rounding to a quantum far below display resolution
/// keeps that invalidation and removes only the re-banking noise.
///
/// **`sleepNeedHours` / `sleepConsistency` needed a second fix.** Quantizing them was NOT enough:
/// re-banking a fresh night moves `sleepConsistency` (a trailing-28-night regularity index) by more than
/// any reasonable quantum, so the drop still fired on every pass with new sleep data — measured
/// 2026-09-01, `dayCache DROPPED — sig changed: sleepConsistency … reused=0/14`, on the exact passes the
/// cache exists to help. The caller (`IntelligenceEngine.analyzeRecent`) now folds these two only while a
/// Sleep-trace test mode is active (a constant sentinel otherwise) — see that call site's comment for why
/// that is safe: outside a trace, neither value feeds anything a cache hit replays. This type's quantizing
/// functions are unchanged and still used on the trace-on path.
///
/// **Signature-only.** Nothing here touches what reaches `analyzeDay` — the full-precision values still
/// thread through to scoring unchanged, so no score, tier or displayed number moves. That separation is the
/// whole safety argument for this change and `AnalyzeRecentConfigSignatureTests` pins it.
///
/// Quantizing is a noise filter, not a guarantee: a value drifting across a quantum boundary still
/// invalidates. That degrades to exactly today's behaviour (one extra cold pass), never to a wrong score.
///
/// Compared only against itself, in memory, on one platform — so, like `cacheKey`, the Kotlin twin must
/// match the invalidation RULES and need not produce byte-identical strings.
public enum AnalyzeRecentConfigSignature {
    /// Personalised sleep need, to the nearest **0.25 h**. The value feeds Rest's need term; a 15-minute
    /// quantum is far below what moves a displayed score, and it is stable against the minute-level drift a
    /// re-banked session produces.
    public static let sleepNeedQuantumHours = 0.25
    /// Sleep regularity (a 0…1 index), to **2 decimal places**.
    public static let sleepConsistencyQuantum = 0.01
    /// Habitual midsleep, to the nearest **5 minutes**. It selects an overnight band; 300 s is well inside
    /// that band's own width.
    public static let habitualMidsleepQuantumSec = 300

    public static func sleepNeedHours(_ hours: Double) -> String {
        quantized(hours, quantum: sleepNeedQuantumHours) ?? String(hours.bitPattern)
    }

    public static func sleepConsistency(_ index: Double?) -> String {
        guard let index else { return "nil" }
        return quantized(index, quantum: sleepConsistencyQuantum) ?? String(index.bitPattern)
    }

    public static func habitualMidsleepSec(_ seconds: Int?) -> String {
        guard let seconds else { return "nil" }
        // Integer arithmetic, so no float rounding to reason about. `.rounded()` on the quotient would be
        // half-away-from-zero; this is the same, written for Ints and symmetric about zero (a midsleep can
        // sit before local midnight and be negative).
        let q = habitualMidsleepQuantumSec
        let steps = seconds >= 0 ? (seconds + q / 2) / q : -((-seconds + q / 2) / q)
        return "\(steps)"
    }

    /// The quantum STEP INDEX as a string — never the re-multiplied Double, so there is no float formatting
    /// or `-0.0`/`0.0` ambiguity in the signature.
    ///
    /// Returns nil, and the callers above fall back to the exact `bitPattern`, when the value cannot be
    /// stepped safely. Both guards are load-bearing rather than defensive noise: `Int64(_:)` **traps** on a
    /// NaN, an infinity, or anything outside `Int64`'s range, and this runs on every analyze pass, so a
    /// degenerate upstream value would crash the app rather than mis-cache. Falling back to the raw bit
    /// pattern is exactly the pre-quantization behaviour — correct, just unfiltered.
    private static func quantized(_ value: Double, quantum: Double) -> String? {
        guard value.isFinite, quantum > 0 else { return nil }
        let steps = (value / quantum).rounded()
        guard steps.magnitude < 9.0e15 else { return nil }
        return String(Int64(steps))
    }
}
