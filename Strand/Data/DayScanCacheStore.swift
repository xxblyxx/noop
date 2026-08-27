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
/// **No Kotlin twin.** This is a device-local derived cache: it holds no user data that is not already
/// banked, feeds no formula, has no schema and no migration, and changes WHICH days recompute, never WHAT
/// they compute to. Android keeps the in-memory-only cache; the two platforms produce identical scores and
/// differ only in how much work a relaunch repeats.
enum DayScanCacheStore {
    /// Bump on ANY change to the encoded shape. A mismatch (or any decode failure) is treated as "no cache",
    /// which costs exactly the cold pass we have today — so getting this wrong degrades, never corrupts.
    static let currentVersion = 2

    // MARK: - On-disk shape

    struct Envelope: Codable {
        let version: Int
        /// The pass config signature the entries were produced under. Loaded back into
        /// `dayScanCacheConfigSig` so a cold process can recognise its own previous signature — without
        /// this the first pass drops the cache it just loaded and the whole change does nothing.
        let configSig: String
        let entries: [String: Entry]
    }

    struct Entry: Codable {
        let key: String
        let scan: Scan
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
    static func save(configSig: String, entries: [String: Entry]) -> Bool {
        guard let url = fileURL else { return false }
        let env = Envelope(version: currentVersion, configSig: configSig, entries: entries)
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
