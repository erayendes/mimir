import XCTest
@testable import Mimir

/// `geminiQuotaRows` folds `retrieveUserQuota`'s per-model buckets (every version plus its `_vertex`
/// twin) into one row per family, at that family's most-spent bucket.
final class GeminiProviderTests: XCTestCase {
    private let ds = LiveUsageDataSource()

    func testFoldsModelsIntoFamiliesAtTheirLowestFraction() {
        let buckets: [[String: Any]] = [
            ["modelId": "gemini-2.5-pro", "remainingFraction": 0.9, "resetTime": "2026-09-30T00:00:00Z"],
            ["modelId": "gemini-2.5-pro_vertex", "remainingFraction": 0.4, "resetTime": "2026-09-30T01:00:00Z"],
            ["modelId": "gemini-2.5-flash", "remainingFraction": 1],
            ["modelId": "gemini-2.5-flash-lite", "remainingFraction": 0.25],
            ["modelId": "text-embedding", "remainingFraction": 0],
        ]
        let rows = ds.geminiQuotaRows(buckets: buckets)
        XCTAssertEqual(rows.map(\.name), ["Gemini Pro", "Gemini Flash", "Gemini Flash Lite"])
        XCTAssertEqual(rows.map(\.remainingPercent), [40, 100, 25])
        XCTAssertEqual(rows[0].resetAt, ds.parseISO8601("2026-09-30T01:00:00Z"))
        XCTAssertTrue(rows.allSatisfy { $0.window == .session })
    }
}
