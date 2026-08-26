import XCTest
@testable import StrandAnalytics

/// `AnalyzeRecentDayCache.cacheKey` — the per-day reuse identity for `analyzeRecent`'s pass-1 loop.
/// Oracle for the Android `AnalyzeRecentDayCacheTest`; keep the two in lockstep on the invalidation rules
/// (the exact key STRING may differ across platforms — the cache is in-memory and per-platform — but the
/// set of changes that must / must not invalidate a reused day is a shared contract).
final class AnalyzeRecentDayCacheTests: XCTestCase {
    /// The default-path flag value: with the HRV trace OFF, `hrvWindowDetail` is constantly false (the
    /// caller gates it on `hrvTraceActive`), so every case below that isn't ABOUT the flag passes false and
    /// reads as the shipping behaviour.
    private static let noDetail = false

    private func key(owner: String = "dev1", hrCount: Int = 178_000, hrMaxTs: Int = 1_700_000_000,
                     skinAnchorRaw: Double? = 1290, hrvWindowDetail: Bool = noDetail) -> String {
        AnalyzeRecentDayCache.cacheKey(owner: owner, hrCount: hrCount, hrMaxTs: hrMaxTs,
                                       skinAnchorRaw: skinAnchorRaw, hrvWindowDetail: hrvWindowDetail)
    }

    // Unchanged inputs → identical key → the day is reused.
    func testStableInputsReuse() {
        XCTAssertEqual(key(), key())
    }

    // A new HR row (count moves) OR a later newest-ts must invalidate — the day changed.
    func testHrChangeInvalidates() {
        XCTAssertNotEqual(key(), key(hrCount: 178_001))
        XCTAssertNotEqual(key(), key(hrMaxTs: 1_700_000_060))
    }

    // A shifted window-wide skin anchor (another night's skin changed the 4.0 median) must invalidate even
    // when this night's HR fingerprint is identical — the skin conversion changed.
    func testAnchorShiftInvalidates() {
        XCTAssertNotEqual(key(), key(skinAnchorRaw: 1290.5))
    }

    // A 5/MG night (no anchor) is a distinct, self-consistent key: nil reuses nil, and nil ≠ a real anchor
    // (so a 4.0 and a 5/MG night with the same fingerprint never alias to each other's scan).
    func testNilAnchorDistinctButStable() {
        XCTAssertEqual(key(hrCount: 5_000, skinAnchorRaw: nil), key(hrCount: 5_000, skinAnchorRaw: nil))
        XCTAssertNotEqual(key(hrCount: 5_000, skinAnchorRaw: nil), key(hrCount: 5_000, skinAnchorRaw: 0))
    }

    // Multi-strap (4.0 + 5/MG): if a day's resolved owner flips between straps, the key must invalidate
    // EXPLICITLY — even in the astronomically-unlikely case that the two straps produced an identical
    // count+maxTs for the same window. The owner id is part of the key, so it never falsely reuses one
    // strap's scan for the other.
    func testDifferentOwnerInvalidates() {
        XCTAssertNotEqual(key(owner: "whoop4-A"), key(owner: "whoop5-B"))
    }

    // #1575: the HRV per-window DETAIL entitlement is part of the key. A night cached as "today" (detail
    // emitted) becomes an ordinary night after local midnight, when a fresh scan would emit only the
    // one-line summary — so the cached scan must NOT be reused across that rollover, or it would replay
    // detail it is no longer entitled to. This is what lets an active trace stop disabling reuse outright.
    func testHrvWindowDetailInvalidates() {
        XCTAssertNotEqual(key(hrvWindowDetail: true), key(hrvWindowDetail: false))
    }

    // ...and the flag is otherwise inert: with the HRV trace off it is constantly false on both sides, so
    // it never invalidates on its own. This is the half that keeps the DEFAULT path free — the flag is
    // gated on `hrvTraceActive` at the call site precisely so a rollover doesn't charge every user an
    // extra day's re-score to protect lines they never see.
    func testHrvWindowDetailStableWhenTraceOff() {
        XCTAssertEqual(key(hrvWindowDetail: false), key(hrvWindowDetail: false))
    }
}
