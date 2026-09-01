import Foundation
import StrandAnalytics
import WhoopStore

/// #1005-WARM: the on-disk form of `IntelligenceEngine`'s per-day reuse cache, so a relaunch starts WARM.
///
/// The defect this closes (measured 2026-08-27, this device). `dayScanCache` is in-memory only and
/// `dayScanCacheConfigSig` starts `""`, which never equals a real signature — so the FIRST pass of every
/// process drops the whole cache and re-reads + re-scores every night. And the morning IS the launch case:
/// opening the app starts the cadence loop whose first tick runs that pass. Measured cost of exactly that
/// pass, backgrounded, on 9 nights: **2403 s**. The same 9 nights, same code, with a warm cache: the pass
/// does a ninth of the work plus a fixed ~50-75 s fold.
///
/// ## Why this projection, and not the whole `DayScan`
///
/// A cached scan has exactly ONE consumer: pass 2. On a hit, pass 1 does `out.append(cached.scan); continue`
/// (`IntelligenceEngine.swift:983-985`) and performs no read, no score and no side effect — so anything pass
/// 2 does not read is dead weight on disk. Pass 2 reads all 13 `DayScan` fields but only **7 of
/// `DayResult`'s 15**: `daily`, `cachedSleep`, `workouts`, `strain`, `nightlySkinTempC`,
/// `sessionMotionByStart`, `sessionSleepStateByStart`. The other eight (`sleepSessions`, `recovery`,
/// `chargeDrivers`, `skinTempRelative`, `restScore`, and the three `ScoreConfidence` tiers) are read only
/// INSIDE pass 1, before the scan is ever cached, and pass 2 recomputes its own (`recomputeRecovery`,
/// `recomputeChargeDrivers`, `ScoreConfidence.charge(...)`) from `baselines2` regardless.
///
/// Restoring them at `DayResult`'s own defaults is therefore not a lossy shortcut — it reproduces what a
/// cache HIT already hands pass 2 today, byte for byte. It also keeps the new `Codable` surface to two types
/// (`ExerciseSession`, `PrimarySessionRestingHR.Coverage`) instead of the nine a wholesale `DayScan`
/// encoding would have needed.
///
/// **Rebuilding from banked state was considered and rejected on evidence.** The original plan preferred
/// persisting only the cache KEY and reloading each night's result from its banked `DailyMetric` + sessions.
/// That cannot be done losslessly: `nightlySkinTempC` is read by the fold (`:1503`, `:1532`) and nothing
/// banks the raw °C mean — only the baseline-relative, 2-dp-rounded `skinTempDevC`, which is nil entirely
/// when the skin-temp baseline is not yet usable. `workouts` loses `zoneTimePct`/`avgHRRPct`/`hrmax`/
/// `caloriesKJ` on the way into `WorkoutRow`, and bouts overlapping a real workout are never banked at all.
///
/// ## Correctness
///
/// A persisted cache removes an accidental safety net: today a stale entry heals on relaunch because the
/// cache dies with the process. Every way a day's score can change WITHOUT its HR fingerprint moving was
/// enumerated before writing this, and the result is narrower than the plan assumed:
///
/// - **Manual sleep edits and dismissed sleep spans need no invalidation.** Both are applied in PASS 2
///   (`sleepEditedDaily` at `:1701-1703`; `dismissedSleepWindows` at `:2186`), fresh on every pass, AFTER
///   the cache. A reused scan is unaffected by them because it never carried them in the first place.
/// - **A device-registry owner change is already covered** — `owner` is in the per-day key.
/// - **The #899 banked-sleep heal is the one real hole, and it is handled at its own site.** It deletes
///   banked sleep rows in pass 2, and the effect surfaces only through `bandSleepStateSamples` — a PASS 1
///   read that is not in the per-day key. Its re-arm (`pendingForcedRescore`) would otherwise re-run a pass
///   that happily reuses the very days the heal invalidated. `IntelligenceEngine` drops both caches at the
///   delete site when the heal actually removes something.
/// - **Trace toggles are folded into the pass signature**, so turning a Test Centre trace off cannot leave
///   persisted scans replaying trace lines into a log that no longer wants them.
///
/// Not in `BackupSettings.whitelist` — that list is opt-in, so a restored `.noopbak` can never import
/// another device's scan cache. Same precedent as `noop.analyzeWatermark` (`IntelligenceEngine.swift:2372`).
///
/// **No Kotlin twin — including for `skipEntries` (#1005-COST).** This is a device-local derived cache: it
/// holds no user data that is not already banked, feeds no formula, has no schema and no migration, and
/// changes WHICH days recompute, never WHAT they compute to; a negative (too-few-HR-samples) entry is the
/// same argument again, one step earlier in the pipeline — it only ever skips a re-READ, never changes what
/// the read would have found. Android keeps the in-memory-only cache (no negative half at all — an
/// in-process `hrSamples` re-read on a rare SKIPPED day is not the cost this closes); the two platforms
/// produce identical scores and differ only in how much work a relaunch repeats.
enum DayScanCacheStore {
    /// Bump on ANY change to the encoded shape. A mismatch (or any decode failure) is treated as "no cache",
    /// which costs exactly the cold pass we have today — so getting this wrong degrades, never corrupts.
    ///
    /// v2 (#1005-COST): added `Envelope.skipEntries` — the negative half of the cache (a day whose raw HR
    /// fell under the scoring floor, so it can skip re-reading `hrSamples` next pass too, not just
    /// re-scoring). A v1 on-disk file has no such key and, more directly, carries `version: 1` — the
    /// `load()` version guard below rejects it outright, same as any other mismatch, costing exactly ONE
    /// cold pass on the affected device the first time this ships. Degrades, never corrupts, per this
    /// type's own policy.
    static let currentVersion = 2

    /// KNOWN AND ACCEPTED: the envelope does not record the `maxDays` window it was produced under.
    /// `analyzeRecent` is usually called at the default window, but the #313 Effort rescore and the #547
    /// timestamp heal pass a WIDER `maxDays`. A wide pass persists its extra days; the next ordinary pass
    /// loads them, prunes to its own narrower window (`IntelligenceEngine.swift:1463-1465`, which runs on
    /// the loop's copy and therefore on what gets saved), and writes the smaller set back. So a wide pass's
    /// surplus days are dropped and re-scored if another wide pass runs.
    ///
    /// Left as-is deliberately: those callers are rare one-off migrations, a missing entry only ever costs
    /// that day a normal cold score (never a wrong one), and recording the window would mean either
    /// refusing to load a narrower cache — which would make the COMMON case cold to protect the rare one —
    /// or keeping out-of-window days alive, which is unbounded growth. Revisit only if a wide pass becomes
    /// routine.

    // MARK: - On-disk shape

    struct Envelope: Codable {
        let version: Int
        /// The pass config signature the entries were produced under. Loaded back into
        /// `dayScanCacheConfigSig` so a cold process can recognise its own previous signature — without
        /// this the first pass drops the cache it just loaded and the whole change does nothing.
        let configSig: String
        let entries: [String: Entry]
        /// v2: the negative-cache entries — see `SkipEntry`.
        let skipEntries: [String: SkipEntry]
    }

    struct Entry: Codable {
        let key: String
        let scan: Scan
    }

    /// A day that fell under `analyzeRecent`'s `hr.count >= 200` scoring floor, so the next pass can
    /// replay `sleep day=… SKIPPED hrSamples=N` without re-reading the stream — see `daySkipCache`'s doc
    /// on `IntelligenceEngine`. `key` invalidates it the same way `Entry.key` invalidates a positive scan.
    struct SkipEntry: Codable {
        let key: String
        let hrCount: Int
    }

    /// The projection of `IntelligenceEngine.DayScan` that pass 2 actually consumes.
    struct Scan: Codable {
        // DayResult, 7 of 15 fields (see the type doc for why the other 8 are omitted).
        let daily: DailyMetric
        let cachedSleep: [CachedSleepSession]
        let workouts: [ExerciseSession]
        let strain: Double?
        let nightlySkinTempC: Double?
        let sessionMotionByStart: [Int: [Double]]
        let sessionSleepStateByStart: [Int: [Int]]
        // DayScan's own fields — all 13 are read by the fold.
        let rhrLine: String?
        let respLine: String?
        let readOwner: String
        let hrRows: Int
        let sleepTrace: [String]
        let stepsTrace: [String]
        let hrvTrace: [String]
        let hrvDiag: String?
        let spo2Candidate: Int?
        let hrvOverCounted: Bool?
        let primarySessionRHR: Double?
        let primarySessionRHRCoverage: PrimarySessionRestingHR.Coverage?
    }

    // MARK: - Location

    /// `Application Support/noop-dayscan-cache.json`. Deliberately NOT `UserDefaults`: the two session bands
    /// are on a 30 s grid (~960 entries per 8 h night), so this runs to hundreds of KB across a full window,
    /// and `UserDefaults` is read wholesale into memory at launch.
    static var fileURL: URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent("noop-dayscan-cache.json")
    }

    // MARK: - IO

    /// Returns nil on absence, unreadable file, version mismatch or any decode failure — all of which mean
    /// "run the cold pass", the behaviour we already have.
    static func load() -> Envelope? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        guard env.version == currentVersion else { return nil }
        return env
    }

    /// Best-effort. A failed write costs a cold pass next launch and nothing else, so it is not surfaced as
    /// an error — but it IS reported to the diagnostic sink, because a cache that silently stops persisting
    /// would look exactly like the bug this change fixes.
    @discardableResult
    static func save(configSig: String, entries: [String: Entry],
                     skipEntries: [String: SkipEntry] = [:]) -> Bool {
        guard let url = fileURL else { return false }
        let env = Envelope(version: currentVersion, configSig: configSig, entries: entries,
                           skipEntries: skipEntries)
        guard let data = try? JSONEncoder().encode(env) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            // The cache holds banked-derived analytics for the owner's own nights. Nothing here leaves the
            // device, but there is no reason for it to sit in an iCloud/iTunes backup either — it is
            // rebuildable by construction.
            var resource = URLResourceValues()
            resource.isExcludedFromBackup = true
            var mutable = url
            try? mutable.setResourceValues(resource)
            return true
        } catch {
            return false
        }
    }

    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Projection to and from the engine's in-memory scan

extension DayScanCacheStore.Scan {
    init(_ scan: IntelligenceEngine.DayScan) {
        let r = scan.result
        self.init(daily: r.daily, cachedSleep: r.cachedSleep, workouts: r.workouts, strain: r.strain,
                  nightlySkinTempC: r.nightlySkinTempC,
                  sessionMotionByStart: r.sessionMotionByStart,
                  sessionSleepStateByStart: r.sessionSleepStateByStart,
                  rhrLine: scan.rhrLine, respLine: scan.respLine, readOwner: scan.readOwner,
                  hrRows: scan.hrRows, sleepTrace: scan.sleepTrace, stepsTrace: scan.stepsTrace,
                  hrvTrace: scan.hrvTrace, hrvDiag: scan.hrvDiag, spo2Candidate: scan.spo2Candidate,
                  hrvOverCounted: scan.hrvOverCounted, primarySessionRHR: scan.primarySessionRHR,
                  primarySessionRHRCoverage: scan.primarySessionRHRCoverage)
    }

    /// Rebuild the engine scan. The eight omitted `DayResult` fields take that type's OWN defaults —
    /// `sleepSessions: []`, `recovery: nil`, `restScore: nil`, the three `ScoreConfidence`s `.calibrating`,
    /// `chargeDrivers: []`, `skinTempRelative: nil` — which is exactly what pass 2 sees for them today,
    /// because pass 2 never reads any of the eight. See the type doc.
    func toScan() -> IntelligenceEngine.DayScan {
        IntelligenceEngine.DayScan(
            result: AnalyticsEngine.DayResult(
                daily: daily, sleepSessions: [], cachedSleep: cachedSleep, workouts: workouts,
                recovery: nil, strain: strain, nightlySkinTempC: nightlySkinTempC,
                sessionMotionByStart: sessionMotionByStart,
                sessionSleepStateByStart: sessionSleepStateByStart),
            rhrLine: rhrLine, respLine: respLine, readOwner: readOwner, hrRows: hrRows,
            sleepTrace: sleepTrace, stepsTrace: stepsTrace, hrvTrace: hrvTrace, hrvDiag: hrvDiag,
            spo2Candidate: spo2Candidate, hrvOverCounted: hrvOverCounted,
            primarySessionRHR: primarySessionRHR,
            primarySessionRHRCoverage: primarySessionRHRCoverage)
    }
}
