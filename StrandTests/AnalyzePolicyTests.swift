import XCTest
@testable import Strand

/// `AnalyzePolicy` rate-limiter (#1005-STORM, 2026-08-25) — the forced-pass floor between AUTOMATIC
/// re-score triggers. Pure value logic, no store/BLE/UI seam. Style mirrors `BackfillPolicyTests`
/// (`BackfillPolicy` is this type's closest sibling, `Strand/BLE/BackfillPolicy.swift`).
final class AnalyzePolicyTests: XCTestCase {
    private let floor = AnalyzePolicy.forcedFloorSeconds   // 900

    func testFirstPassAlwaysRuns() {
        XCTAssertEqual(AnalyzePolicy.decide(trigger: .idleTick, now: 1000, lastPassEndedAt: nil, tzOffsetSec: 0), .run)
        XCTAssertEqual(AnalyzePolicy.decide(trigger: .postOffload, now: 1000, lastPassEndedAt: nil, tzOffsetSec: 0), .run)
    }

    // The `>=` boundary must match `BackfillPolicy.shouldRun`'s existing convention (`elapsed >= floor`).
    func testFloorBoundary() {
        XCTAssertEqual(AnalyzePolicy.decide(trigger: .postOffload, now: 1000, lastPassEndedAt: 1000 - floor + 1, tzOffsetSec: 0),
                       .deferUntil(1000 - floor + 1 + floor))
        XCTAssertEqual(AnalyzePolicy.decide(trigger: .postOffload, now: 1000, lastPassEndedAt: 1000 - floor, tzOffsetSec: 0), .run)
    }

    // `.dataChange` (every user- or data-driven caller) and `.background` (the BGProcessingTask wake,
    // whose OWN whole-store fingerprint gate is trustworthy while the process is suspended) are never
    // floored, even immediately after another pass.
    func testDataChangeAndBackgroundAreNeverFloored() {
        XCTAssertEqual(AnalyzePolicy.decide(trigger: .dataChange, now: 1000, lastPassEndedAt: 1000, tzOffsetSec: 0), .run)
        XCTAssertEqual(AnalyzePolicy.decide(trigger: .background, now: 1000, lastPassEndedAt: 1000, tzOffsetSec: 0), .run)
    }

    func testBackwardsClockAlwaysRuns() {
        XCTAssertEqual(AnalyzePolicy.decide(trigger: .idleTick, now: 1000, lastPassEndedAt: 2000, tzOffsetSec: 0), .run)
    }

    // Local-midnight rollover must use the SAME day-key helper `analyzeRecent`'s scoring loop uses
    // (`AnalyticsEngine.dayString(_:offsetSec:)`), so this boundary can never disagree with scoring's own.
    // Run at a non-zero, negative `tzOffsetSec` (America/Los_Angeles-shaped, this owner's zone) so a
    // UTC-only implementation fails these two.
    func testLocalMidnightRolloverForcesRunEvenWithinTheFloor() {
        let tz = -25200  // -7h
        // ts + tz == an exact multiple of 86400 is local midnight in the shifted-UTC-day sense.
        let localMidnight: TimeInterval = 100 * 86400 - Double(tz)
        let last = localMidnight - 120   // 23:58:00 local, the day before
        let now  = localMidnight + 60    // 00:01:00 local, the day after — 180s elapsed, well under the floor
        XCTAssertEqual(AnalyzePolicy.decide(trigger: .idleTick, now: now, lastPassEndedAt: last, tzOffsetSec: tz), .run)
    }

    func testSameElapsedWhollyInsideOneLocalDayIsFloored() {
        let tz = -25200
        let localMidnight: TimeInterval = 100 * 86400 - Double(tz)
        let last = localMidnight - 3600  // 23:00:00 local, the day before
        let now  = last + 180            // 23:03:00 local, SAME local day — same 180s gap as the test above
        XCTAssertEqual(AnalyzePolicy.decide(trigger: .idleTick, now: now, lastPassEndedAt: last, tzOffsetSec: tz),
                       .deferUntil(last + floor))
    }
}
