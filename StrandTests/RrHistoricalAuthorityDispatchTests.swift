import XCTest
import WhoopProtocol
import WhoopStore
@testable import Strand

/// #1451: the Backfiller writes through `BackfillStoreWriting`, and that protocol carries a DEFAULT
/// `insertHistorical` that forwards to plain `insert` — it exists so a test double need not implement the
/// authority path. That default is also the failure mode worth pinning: if `WhoopStore`'s witness ever
/// stops matching the requirement (a signature drift, a visibility change), Swift binds silently to the
/// default instead of failing to compile, and the fix becomes a no-op in production with every unit test
/// still green.
///
/// So this asserts DISPATCH, not storage: called through the protocol, the real store must still clear the
/// second. `WhoopStoreTests/RrHistoricalAuthorityTests` covers the behaviour itself.
final class RrHistoricalAuthorityDispatchTests: XCTestCase {

    func testTheProtocolBindsToWhoopStoresWitnessNotTheForwardingDefault() async throws {
        let concrete = try await WhoopStore.inMemory()
        try await concrete.upsertDevice(id: "dev1", mac: nil, name: nil)
        // Deliberately through the protocol — the Backfiller's own view of the store.
        let store: BackfillStoreWriting = concrete

        _ = try await store.insert(Streams(rr: [RRInterval(ts: 100, rrMs: 785)]), deviceId: "dev1")
        _ = try await store.insertHistorical(Streams(rr: [RRInterval(ts: 100, rrMs: 801)]), deviceId: "dev1")

        let stored = try await concrete.rrIntervals(deviceId: "dev1", from: 100, to: 100, limit: 10).map(\.rrMs)
        XCTAssertEqual(stored, [801],
                       "protocol dispatch reached the forwarding default — the strap's record did not win")
    }
}
