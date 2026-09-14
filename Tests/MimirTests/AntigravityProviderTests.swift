import XCTest
@testable import Mimir

/// `antigravityQuotaSummaryRows` classifies each `RetrieveUserQuotaSummary` bucket into a 5h/weekly
/// `ModelWindow`. Several independent competitor implementations, reading real Antigravity responses,
/// agree the flat `window` field this used to rely on is either absent or unreliable — the window is
/// instead baked into the bucket's own id (`gemini-5h`, `gemini-weekly`, `3p-5h`, `3p-weekly`, …). These
/// tests lock in bucketId-first classification and, in particular, the failure mode it fixes: without
/// it, a missing/wrong `window` field makes every bucket read as `.session`, and `antigravityFamilies`
/// (PopoverViews.swift) — which keys its 5h/weekly readings by `ModelWindow` in a dictionary — lets one
/// silently overwrite the other, dropping a whole row with no error.
final class AntigravityProviderTests: XCTestCase {
    private let ds = LiveUsageDataSource()

    private func bucket(_ id: String, fraction: Double, window: String? = nil) -> [String: Any] {
        var b: [String: Any] = ["bucketId": id, "remainingFraction": fraction]
        if let window { b["window"] = window }
        return b
    }

    func testClassifiesByBucketIdWhenWindowFieldIsAbsent() {
        // The scenario several competitors' real parsers report: no "window" field at all.
        let groups: [[String: Any]] = [[
            "displayName": "Gemini",
            "buckets": [
                bucket("gemini-5h", fraction: 0.8),
                bucket("gemini-weekly", fraction: 0.4),
            ],
        ]]
        let rows = ds.antigravityQuotaSummaryRows(groups: groups)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0.window == .session }?.remainingPercent, 80)
        XCTAssertEqual(rows.first { $0.window == .weekly }?.remainingPercent, 40)
    }

    func testBucketIdWinsOverAMisleadingFlatWindowField() {
        // If some account/region *does* return a flat "window" field but it disagrees with the
        // bucket's own id, the id must win — it's the more specific, more widely-agreed-upon signal.
        let groups: [[String: Any]] = [[
            "displayName": "Claude/GPT",
            "buckets": [
                bucket("3p-5h", fraction: 0.9, window: "weekly"),
                bucket("3p-weekly", fraction: 0.5, window: "weekly"),
            ],
        ]]
        let rows = ds.antigravityQuotaSummaryRows(groups: groups)
        XCTAssertEqual(rows.first { $0.window == .session }?.remainingPercent, 90)
        XCTAssertEqual(rows.first { $0.window == .weekly }?.remainingPercent, 50)
    }

    func testFallsBackToFlatWindowFieldWhenIdIsInconclusive() {
        // An id that says nothing about the window (no "5h"/"weekly"/"session"/"hour"/"7d" hint)
        // still has to land somewhere — fall back to the old flat `window` field rather than guessing.
        let groups: [[String: Any]] = [[
            "displayName": "Gemini",
            "buckets": [bucket("bucket-1", fraction: 0.6, window: "weekly")],
        ]]
        let rows = ds.antigravityQuotaSummaryRows(groups: groups)
        XCTAssertEqual(rows.first?.window, .weekly)
    }

    func testBothBucketsSurviveEvenWhenNeitherReportsAWindowField() {
        // The exact regression this fix targets: previously, with no "window" field, BOTH buckets
        // read as `.session`, and PopoverViews' dictionary-keyed grouping let the second overwrite the
        // first — losing the weekly row entirely with no error. Both must now come back distinctly.
        let groups: [[String: Any]] = [[
            "displayName": "Gemini",
            "buckets": [
                bucket("gemini-weekly", fraction: 0.4),   // listed first this time — order must not matter
                bucket("gemini-5h", fraction: 0.8),
            ],
        ]]
        let rows = ds.antigravityQuotaSummaryRows(groups: groups)
        XCTAssertEqual(rows.count, 2, "both the 5h and weekly bucket must survive as distinct rows")
        XCTAssertEqual(rows.first { $0.window == .session }?.remainingPercent, 80)
        XCTAssertEqual(rows.first { $0.window == .weekly }?.remainingPercent, 40)
    }
}
