import XCTest
@testable import Strand

/// #103: the Today Blood Oxygen tile shows the strap's @82 nightly estimate when no calibrated
/// `spo2Pct` exists (always, on a WHOOP 5/MG). These cover the descriptor the tap-through opens —
/// it must follow the same fallback the VALUE follows, or the tile either goes inert (no catalog
/// entry for `spo2_candidate`) or opens a permanently empty calibrated chart.
final class MetricCatalogSpo2Tests: XCTestCase {
    func testCalibratedSpo2OpensTheCalibratedDetail() {
        let metric = MetricCatalog.todaySpo2Metric(hasCalibrated: true, hasCandidate: false)

        XCTAssertEqual(metric?.key, "spo2")
        XCTAssertEqual(metric?.source, "my-whoop")
    }

    /// A calibrated reading always wins, even when the @82 candidate is also present.
    func testCalibratedSpo2WinsOverTheCandidate() {
        let metric = MetricCatalog.todaySpo2Metric(hasCalibrated: true, hasCandidate: true)

        XCTAssertEqual(metric?.key, "spo2")
        XCTAssertEqual(metric?.source, "my-whoop")
    }

    /// The WHOOP 5/MG case: no calibrated value, the tile shows the strap estimate, so the tap must
    /// open THAT series — resolvable, i.e. the tile is no longer inert.
    func testCandidateOnlyOpensTheStrapEstimateDetail() {
        let metric = MetricCatalog.todaySpo2Metric(hasCalibrated: false, hasCandidate: true)

        XCTAssertEqual(metric?.key, "spo2_candidate")
        XCTAssertEqual(metric?.source, "my-whoop")
        XCTAssertNotNil(metric)
    }

    /// The estimate is never presented under the calibrated metric's name (the `steps_est` precedent),
    /// and it formats on the same 0-decimal percent axis so the two read alike.
    func testCandidateTitleIsDistinctFromTheCalibratedMetric() {
        let candidate = MetricCatalog.spo2CandidateMetric
        let calibrated = MetricCatalog.metric(key: "spo2", source: "my-whoop")

        XCTAssertNotEqual(candidate.title, calibrated?.title)
        XCTAssertNotNil(candidate.description)
        XCTAssertEqual(candidate.unit, "%")
        XCTAssertEqual(candidate.decimals, 0)
        XCTAssertEqual(candidate.higherIsBetter, true)
    }

    /// A tile with nothing to show keeps the destination it has always had.
    func testNoDataKeepsTheCalibratedDestination() {
        let metric = MetricCatalog.todaySpo2Metric(hasCalibrated: false, hasCandidate: false)

        XCTAssertEqual(metric?.key, "spo2")
        XCTAssertEqual(metric?.source, "my-whoop")
    }

    /// The candidate is an experimental, default-off signal: it must stay OUT of the catalog list that
    /// builds the Metric Explorer, Compare and the correlation scan. It is reachable only through
    /// `todaySpo2Metric`, which the tile hands straight to `MetricDetailView`.
    func testCandidateIsNotAMemberOfTheCatalog() {
        XCTAssertNil(MetricCatalog.all.first(where: { $0.key == "spo2_candidate" }))
        XCTAssertNil(MetricCatalog.metric(key: "spo2_candidate", source: "my-whoop"))
    }
}
