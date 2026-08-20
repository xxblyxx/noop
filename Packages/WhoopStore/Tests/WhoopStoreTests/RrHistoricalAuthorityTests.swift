import XCTest
import WhoopProtocol
@testable import WhoopStore

/// #1451: the strap's own banked record is authoritative for every second it covers, so a historical
/// batch replaces what the live stream already wrote for those seconds instead of piling on beside it.
///
/// The defect this pins: two paths write R-R for the same wall-second — the live stream as beats arrive,
/// and the offload when the strap's record of those seconds is downloaded later. They disagree by a few
/// milliseconds, so `ON CONFLICT(deviceId, ts, rrMs, seq) DO NOTHING` cannot collapse them and both
/// survive. Measured on a real 5.0: 1.65x the strap's own claim stored, ~2.1 s of beat-time per wall
/// second wherever two batches wrote, and zero duplication across a 2 h 18 m BLE disconnect.
final class RrHistoricalAuthorityTests: XCTestCase {

    private func store() async throws -> WhoopStore {
        let s = try await WhoopStore.inMemory()
        try await s.upsertDevice(id: "dev1", mac: nil, name: nil)
        return s
    }

    private func rrMs(_ s: WhoopStore, ts: Int) async throws -> [Int] {
        try await s.rrIntervals(deviceId: "dev1", from: ts, to: ts, limit: 100).map(\.rrMs)
    }

    /// The whole point: the live copy of a second does not survive the strap's own record of it.
    func testHistoricalBatchReplacesTheLiveCopyOfTheSameSecond() async throws {
        let s = try await store()
        // Live first — this is the order it happens in: beats stream while connected, the offload lands later.
        _ = try await s.insert(Streams(rr: [RRInterval(ts: 100, rrMs: 785)]), deviceId: "dev1")
        _ = try await s.insertHistorical(Streams(rr: [RRInterval(ts: 100, rrMs: 801)]), deviceId: "dev1")

        // Not [785, 801] — that pair IS the bug, two records of one heartbeat a few ms apart.
        let stored = try await rrMs(s, ts: 100)
        XCTAssertEqual(stored, [801], "the strap's own record must be the only copy left")
    }

    /// The deliberate exception: a second the strap banked NO beats for keeps whatever the live stream
    /// saw. 240 such seconds appeared in the measured window; deleting them would drop data with nothing
    /// to put in its place.
    func testASecondTheHistoricalBatchDoesNotCoverKeepsItsLiveRows() async throws {
        let s = try await store()
        _ = try await s.insert(Streams(rr: [RRInterval(ts: 100, rrMs: 785),
                                            RRInterval(ts: 101, rrMs: 790)]), deviceId: "dev1")
        // The offload covers 100 but reports nothing at all for 101.
        _ = try await s.insertHistorical(Streams(rr: [RRInterval(ts: 100, rrMs: 801)]), deviceId: "dev1")

        let covered = try await rrMs(s, ts: 100)
        let uncovered = try await rrMs(s, ts: 101)
        XCTAssertEqual(covered, [801])
        XCTAssertEqual(uncovered, [790], "an uncovered second must not be cleared")
    }

    /// Re-offloading a chunk (a held ack, a re-sent window) must not change the stored result — the
    /// delete+insert has to stay as idempotent as the DO NOTHING it replaces.
    func testReOffloadingTheSameChunkIsIdempotent() async throws {
        let s = try await store()
        let batch = Streams(rr: [RRInterval(ts: 100, rrMs: 801), RRInterval(ts: 100, rrMs: 812)])
        _ = try await s.insertHistorical(batch, deviceId: "dev1")
        _ = try await s.insertHistorical(batch, deviceId: "dev1")

        let stored = try await rrMs(s, ts: 100)
        XCTAssertEqual(stored, [801, 812])
    }

    /// A plain live insert keeps the old behaviour exactly — first writer wins, nothing is deleted. Only
    /// the historical path carries authority.
    func testALiveInsertNeverClearsAnything() async throws {
        let s = try await store()
        _ = try await s.insertHistorical(Streams(rr: [RRInterval(ts: 100, rrMs: 801)]), deviceId: "dev1")
        _ = try await s.insert(Streams(rr: [RRInterval(ts: 100, rrMs: 785)]), deviceId: "dev1")

        // Both present: a live batch has no licence to remove the strap's record, and the differing value
        // is a genuinely distinct key. This is the residual the fix does NOT address — see the test below.
        let stored = try await rrMs(s, ts: 100)
        XCTAssertEqual(stored, [785, 801])
    }

    /// The delete is scoped to one device. A second strap (or an Oura ring) sharing a timestamp is
    /// untouched — the blast radius is `(deviceId, ts)`, never a time range.
    func testTheClearIsScopedToTheDeviceItWasWrittenFor() async throws {
        let s = try await store()
        try await s.upsertDevice(id: "dev2", mac: nil, name: nil)
        _ = try await s.insert(Streams(rr: [RRInterval(ts: 100, rrMs: 785)]), deviceId: "dev2")
        _ = try await s.insertHistorical(Streams(rr: [RRInterval(ts: 100, rrMs: 801)]), deviceId: "dev1")

        let other = try await s.rrIntervals(deviceId: "dev2", from: 100, to: 100, limit: 10).map(\.rrMs)
        XCTAssertEqual(other, [785], "another device's beats for the same second must survive")
    }

    /// `rrSecondsCovered` is the delete's entire blast radius, so it is pure and pinned on both platforms.
    func testCoveredSecondsAreTheDistinctTimestampsAscending() {
        let covered = WhoopStore.rrSecondsCovered([
            RRInterval(ts: 102, rrMs: 800), RRInterval(ts: 100, rrMs: 810),
            RRInterval(ts: 102, rrMs: 795), RRInterval(ts: 100, rrMs: 805),
        ])
        XCTAssertEqual(covered, [100, 102])
        XCTAssertEqual(WhoopStore.rrSecondsCovered([]), [])
    }
}
