import XCTest
@testable import Strand

/// Pins the #1005-STORM offload-fraction fix, caught by code review before merge: the original code
/// divided by wall-clock elapsed since `beginOffload` instead of `now - frontierAtBurstStart` (both are
/// epoch timestamps — see `SyncProgress`'s type doc), so the fraction clamped to `offloadWeight` (0.7)
/// within seconds of every burst starting regardless of backlog size. `testGapBasedSweepMatchesFormula`
/// is the case that fails on that code and passes on the fix. Also pins the entry-gating (finding #1's
/// second half) and the monotonic clamp (finding #1's third half, covering the unordered per-chunk
/// `ackHistoricalChunk` Task race in `BLEManager`).
@MainActor
final class SyncProgressTests: XCTestCase {

    /// `SyncProgress.now` is `() -> Date`, injectable for exactly this test.
    private func fakeClock(startingAt epoch: Int) -> (progress: SyncProgress, advance: (Int) -> Void) {
        var current = Date(timeIntervalSince1970: TimeInterval(epoch))
        let progress = SyncProgress()
        progress.now = { current }
        return (progress, { seconds in current = current.addingTimeInterval(TimeInterval(seconds)) })
    }

    // Backlog: 1 hour behind at burst start (T0 = now0 - 3600). Frontier advances at 2x wall-clock
    // (r=2) — a genuinely draining backlog, not the near-1:1 crawl case documented separately below.
    // The formula is self-normalizing: it reaches exactly `offloadWeight` when frontier catches up to
    // `now`, at t=3600s here (frontier = T0 + 2*3600 = now0 + 3600 = now(3600)).
    func testGapBasedSweepMatchesFormula() {
        let now0 = 2_000_000
        let t0 = now0 - 3600
        let (progress, advance) = fakeClock(startingAt: now0)

        progress.beginOffload(frontier: t0)
        XCTAssertEqual(progress.phase, .offload)
        XCTAssertEqual(progress.fraction, 0)

        // t=1800s: frontier has advanced 2*1800=3600 -> T0+3600. total = now(1800)-T0 = 5400.
        // raw = 3600/5400 = 0.6667 -> fraction = 0.6667 * 0.7 = 0.4667.
        advance(1800)
        progress.updateOffload(frontier: t0 + 3600)
        XCTAssertEqual(progress.fraction, 0.4667, accuracy: 0.001,
                        "with today's (buggy) elapsed-since-begin denominator this would already be "
                        + "pinned at 0.7 — the whole backlog would read as 67% closed in 30 minutes of "
                        + "a hard-clamped-to-1 ratio computed from wall time alone")

        // t=3600s: frontier = T0 + 7200 = now(3600). Fully caught up -> exactly offloadWeight.
        advance(1800)
        progress.updateOffload(frontier: t0 + 7200)
        XCTAssertEqual(progress.fraction, 0.7, accuracy: 0.0001)
    }

    /// The measured on-device case (37 min, frontier delta 2,189s vs wall delta 2,187s — r≈1.0009):
    /// the backlog is barely shrinking because live HR keeps streaming while the offload drains it, so
    /// the fraction should crawl, staying well short of `offloadWeight` even after real wall time has
    /// passed. This is the expected shape, not a regression of the fix.
    func testNearOneToOneRateCrawlsRatherThanPinning() {
        let now0 = 2_000_000
        let t0 = now0 - 3600   // 1 hour behind
        let (progress, advance) = fakeClock(startingAt: now0)

        progress.beginOffload(frontier: t0)
        advance(1800)
        // r≈1: frontier advances ~1800s of data in 1800s of wall time.
        progress.updateOffload(frontier: t0 + 1800)
        // total = now(1800) - T0 = 5400; closed = 1800; raw = 0.333 -> fraction ≈ 0.233.
        XCTAssertEqual(progress.fraction, 0.233, accuracy: 0.001)
        XCTAssertLessThan(progress.fraction, 0.5, "a near-1:1 drain rate must not read as more than "
                           + "half-swept after only 30 minutes")
    }

    func testNilFrontierStaysIdle() {
        let (progress, _) = fakeClock(startingAt: 2_000_000)
        progress.beginOffload(frontier: nil)
        XCTAssertEqual(progress.phase, .idle,
                        "a failed frontier read must not anchor a phase whose updateOffload can never "
                        + "satisfy its own guard")
    }

    func testGapBelowFloorStaysIdle() {
        let now0 = 2_000_000
        let (progress, _) = fakeClock(startingAt: now0)
        // Only 30s behind — well under the 120s floor. Nothing worth a determinate sweep.
        progress.beginOffload(frontier: now0 - 30)
        XCTAssertEqual(progress.phase, .idle)
    }

    func testGapAtFloorEntersOffload() {
        let now0 = 2_000_000
        let (progress, _) = fakeClock(startingAt: now0)
        progress.beginOffload(frontier: now0 - 120)
        XCTAssertEqual(progress.phase, .offload)
    }

    /// `ackHistoricalChunk` fires an unordered `Task` per acked chunk (`BLEManager.swift`) — a
    /// late-resuming call carrying a stale, smaller frontier must never walk the bar backwards.
    func testUpdateOffloadIsMonotonic() {
        let now0 = 2_000_000
        let t0 = now0 - 3600
        let (progress, advance) = fakeClock(startingAt: now0)

        progress.beginOffload(frontier: t0)
        advance(1800)
        progress.updateOffload(frontier: t0 + 3600)
        let advancedFraction = progress.fraction
        XCTAssertGreaterThan(advancedFraction, 0)

        // A stale Task resumes late, carrying an EARLIER (smaller) frontier read.
        progress.updateOffload(frontier: t0 + 100)
        XCTAssertEqual(progress.fraction, advancedFraction,
                        "a stale, smaller-frontier update must not lower a fraction already rendered")
    }

    func testFinishResetsToIdle() {
        let now0 = 2_000_000
        let t0 = now0 - 3600
        let (progress, advance) = fakeClock(startingAt: now0)

        progress.beginOffload(frontier: t0)
        advance(1800)
        progress.updateOffload(frontier: t0 + 3600)
        XCTAssertGreaterThan(progress.fraction, 0)

        progress.finish()
        XCTAssertEqual(progress.phase, .idle)
        XCTAssertEqual(progress.fraction, 0)

        // A finished session must not leave a stale anchor that a later updateOffload could read.
        progress.updateOffload(frontier: t0 + 7200)
        XCTAssertEqual(progress.fraction, 0, "updateOffload after finish() must no-op (phase != .offload)")
    }
}
