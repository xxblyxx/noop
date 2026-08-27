import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// `DayScanCacheStore` — the on-disk form of the per-day reuse cache (#1005-WARM).
///
/// The load-bearing property is the PROJECTION: the store keeps only what pass 2 of `analyzeRecent`
/// consumes, so a round-tripped scan must be indistinguishable — for those fields — from the one that went
/// in. Everything else (version rejection, corrupt input) must degrade to "no cache", i.e. the cold pass
/// that already exists, never to a wrong or partial score.
final class DayScanCacheStoreTests: XCTestCase {
    private func daily(day: String = "2026-08-26") -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: 431, efficiency: 0.92, deepMin: 88, remMin: 104,
                    lightMin: 239, disturbances: 7, restingHr: 53, avgHrv: 71.5, recovery: 64,
                    strain: 11.2, exerciseCount: 1, skinTempDevC: -0.13, respRateBpm: 10.9,
                    steps: 8_412, avgSdnn: 66.1)
    }

    private func workout() -> ExerciseSession {
        ExerciseSession(start: 1_700_000_000, end: 1_700_003_600, avgHR: 132.4, peakHR: 168,
                        strain: 9.4, durationS: 3_600, zoneTimePct: [0: 5, 1: 20, 2: 40, 3: 25, 4: 10],
                        avgHRRPct: 61.2, hrmax: 186, hrmaxSource: "tanaka",
                        caloriesKcal: 612, caloriesKJ: 2_561)
    }

    private func scan(day: String = "2026-08-26") -> IntelligenceEngine.DayScan {
        IntelligenceEngine.DayScan(
            result: AnalyticsEngine.DayResult(
                daily: daily(day: day), sleepSessions: [], cachedSleep: [
                    CachedSleepSession(startTs: 1_699_950_000, endTs: 1_699_976_000, efficiency: 0.92,
                                       restingHr: 53, avgHrv: 71.5, stagesJSON: "[{\"stage\":2}]",
                                       userEdited: true, startTsAdjusted: 1_699_950_600,
                                       stagingSparse: false),
                ],
                workouts: [workout()], recovery: nil, strain: 11.2, nightlySkinTempC: 33.42,
                sessionMotionByStart: [1_699_950_000: [0.1, 0.2, 0.3]],
                sessionSleepStateByStart: [1_699_950_000: [0, 1, 2, 3]]),
            rhrLine: "rhr day=\(day) floor=53", respLine: "resp day=\(day) rpm=10.9",
            readOwner: "whoop-5B0", hrRows: 178_000,
            sleepTrace: ["sleep trace a"], stepsTrace: ["steps trace b"], hrvTrace: ["hrv trace c"],
            hrvDiag: "hrv diag …", spo2Candidate: 82, hrvOverCounted: false,
            primarySessionRHR: 56.8,
            primarySessionRHRCoverage: PrimarySessionRestingHR.Coverage(validSamples: 26_941,
                                                                        durationSec: 26_000))
    }

    /// Every field the fold reads must survive the round trip. If a field is ever ADDED to `DayScan` and not
    /// to the projection, this is the test that should fail — so it asserts field by field, deliberately,
    /// rather than through a blanket `Equatable`.
    func testRoundTripPreservesEverythingPassTwoReads() throws {
        let original = scan()
        let data = try JSONEncoder().encode(DayScanCacheStore.Scan(original))
        let back = try JSONDecoder().decode(DayScanCacheStore.Scan.self, from: data).toScan()

        XCTAssertEqual(back.result.daily, original.result.daily)
        XCTAssertEqual(back.result.cachedSleep, original.result.cachedSleep)
        XCTAssertEqual(back.result.workouts, original.result.workouts)
        XCTAssertEqual(back.result.strain, original.result.strain)
        XCTAssertEqual(back.result.nightlySkinTempC, original.result.nightlySkinTempC)
        XCTAssertEqual(back.result.sessionMotionByStart, original.result.sessionMotionByStart)
        XCTAssertEqual(back.result.sessionSleepStateByStart, original.result.sessionSleepStateByStart)
        XCTAssertEqual(back.rhrLine, original.rhrLine)
        XCTAssertEqual(back.respLine, original.respLine)
        XCTAssertEqual(back.readOwner, original.readOwner)
        XCTAssertEqual(back.hrRows, original.hrRows)
        XCTAssertEqual(back.sleepTrace, original.sleepTrace)
        XCTAssertEqual(back.stepsTrace, original.stepsTrace)
        XCTAssertEqual(back.hrvTrace, original.hrvTrace)
        XCTAssertEqual(back.hrvDiag, original.hrvDiag)
        XCTAssertEqual(back.spo2Candidate, original.spo2Candidate)
        XCTAssertEqual(back.hrvOverCounted, original.hrvOverCounted)
        XCTAssertEqual(back.primarySessionRHR, original.primarySessionRHR)
        XCTAssertEqual(back.primarySessionRHRCoverage, original.primarySessionRHRCoverage)
    }

    /// A `userEdited` session with an adjusted onset is the case most likely to be silently flattened by a
    /// projection, and `effectiveStartTs` is what the fold and the Sleep tab actually display.
    func testEditedSleepSessionSurvivesWithItsAdjustedOnset() throws {
        let back = try JSONDecoder()
            .decode(DayScanCacheStore.Scan.self,
                    from: JSONEncoder().encode(DayScanCacheStore.Scan(scan()))).toScan()
        let session = try XCTUnwrap(back.result.cachedSleep.first)
        XCTAssertTrue(session.userEdited)
        XCTAssertEqual(session.startTsAdjusted, 1_699_950_600)
        XCTAssertEqual(session.effectiveStartTs, 1_699_950_600)
    }

    /// The eight `DayResult` fields the projection omits come back at that type's OWN defaults. Pinned so a
    /// future reader can see the omission is deliberate and bounded — and so that if any of the eight ever
    /// becomes load-bearing in pass 2, the reviewer has this list to check against.
    func testOmittedFieldsComeBackAtDayResultDefaults() throws {
        let back = try JSONDecoder()
            .decode(DayScanCacheStore.Scan.self,
                    from: JSONEncoder().encode(DayScanCacheStore.Scan(scan()))).toScan()
        XCTAssertTrue(back.result.sleepSessions.isEmpty)
        XCTAssertNil(back.result.recovery)
        XCTAssertNil(back.result.restScore)
        XCTAssertNil(back.result.skinTempRelative)
        XCTAssertTrue(back.result.chargeDrivers.isEmpty)
        XCTAssertEqual(back.result.chargeConfidence, .calibrating)
        XCTAssertEqual(back.result.effortConfidence, .calibrating)
        XCTAssertEqual(back.result.restConfidence, .calibrating)
    }

    /// A stale encoding must be REJECTED, not decoded into a half-populated cache. Degrading to "no cache"
    /// costs exactly the cold pass we have today.
    func testVersionMismatchIsRejected() throws {
        let env = DayScanCacheStore.Envelope(
            version: DayScanCacheStore.currentVersion + 1, configSig: "sig",
            entries: ["2026-08-26": .init(key: "k", scan: DayScanCacheStore.Scan(scan()))])
        let url = try XCTUnwrap(DayScanCacheStore.fileURL)
        defer { DayScanCacheStore.clear() }
        try JSONEncoder().encode(env).write(to: url, options: .atomic)
        XCTAssertNil(DayScanCacheStore.load(), "a future version must read as no cache")
    }

    /// Same for a truncated / garbage file — a decode failure is a cold pass, never a crash.
    func testCorruptFileIsRejected() throws {
        let url = try XCTUnwrap(DayScanCacheStore.fileURL)
        defer { DayScanCacheStore.clear() }
        try Data("{not json".utf8).write(to: url, options: .atomic)
        XCTAssertNil(DayScanCacheStore.load())
    }

    /// Save → load must reproduce the entry keys, the per-day cache key and the signature. Without the
    /// signature surviving, a cold process would load the cache and then immediately drop it as "changed",
    /// which is the whole change doing nothing.
    func testSaveLoadRoundTripIncludingConfigSignature() throws {
        defer { DayScanCacheStore.clear() }
        let entries = ["2026-08-26": DayScanCacheStore.Entry(key: "owner|1:2:nil:s",
                                                             scan: DayScanCacheStore.Scan(scan()))]
        XCTAssertTrue(DayScanCacheStore.save(configSig: "SIG-A", entries: entries))
        let loaded = try XCTUnwrap(DayScanCacheStore.load())
        XCTAssertEqual(loaded.configSig, "SIG-A")
        XCTAssertEqual(loaded.entries.keys.sorted(), ["2026-08-26"])
        XCTAssertEqual(loaded.entries["2026-08-26"]?.key, "owner|1:2:nil:s")
        XCTAssertEqual(loaded.entries["2026-08-26"]?.scan.toScan().result.daily, daily())
    }

    func testClearRemovesTheFile() throws {
        XCTAssertTrue(DayScanCacheStore.save(configSig: "S", entries: [:]))
        XCTAssertNotNil(DayScanCacheStore.load())
        DayScanCacheStore.clear()
        XCTAssertNil(DayScanCacheStore.load())
    }
}
