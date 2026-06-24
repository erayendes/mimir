import XCTest
@testable import Mimir

/// Covers the pure parsing/math helpers in LiveUsageDataSource — the fragile, reverse-engineered
/// logic that turns raw provider JSON into percentages and dates. LiveUsageDataSource is stateless,
/// so a throwaway instance is fine.
final class UsageParsingTests: XCTestCase {
    private let ds = LiveUsageDataSource()

    func testRemainingPercentFromUsed() {
        XCTAssertEqual(ds.remainingPercent(fromUsed: 0), 100)
        XCTAssertEqual(ds.remainingPercent(fromUsed: 100), 0)
        XCTAssertEqual(ds.remainingPercent(fromUsed: 30), 70)
        XCTAssertEqual(ds.remainingPercent(fromUsed: 30.4), 70)   // rounds
        XCTAssertEqual(ds.remainingPercent(fromUsed: 150), 0)     // clamps low
        XCTAssertEqual(ds.remainingPercent(fromUsed: -10), 100)   // clamps high
    }

    func testDoubleValueCoercions() {
        XCTAssertEqual(ds.doubleValue(5), 5)
        XCTAssertEqual(ds.doubleValue(5.5), 5.5)
        XCTAssertEqual(ds.doubleValue("5.5"), 5.5)
        XCTAssertNil(ds.doubleValue("not a number"))
        XCTAssertNil(ds.doubleValue(nil))
    }

    func testEpochMillisToDate() {
        XCTAssertEqual(ds.epochMillisToDate(1_700_000_000_000),
                       Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(ds.epochMillisToDate("1700000000000"),
                       Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(ds.epochMillisToDate(0))
        XCTAssertNil(ds.epochMillisToDate(nil))
    }

    func testCodexAPIWindow() {
        let (used, reset) = ds.codexAPIWindow(["used_percent": 42.0, "reset_at": 1_700_000_000.0])
        XCTAssertEqual(used, 42.0)
        XCTAssertEqual(reset, Date(timeIntervalSince1970: 1_700_000_000))

        let (usedInt, _) = ds.codexAPIWindow(["used_percent": 30])   // Int coerced
        XCTAssertEqual(usedInt, 30)

        let (none, noReset) = ds.codexAPIWindow(nil)
        XCTAssertNil(none)
        XCTAssertNil(noReset)
    }

    func testJWTExpiry() {
        let token = Self.makeJWT(payload: ["exp": 2_000_000_000])
        XCTAssertEqual(ds.jwtExpiry(token), Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertNil(ds.jwtExpiry("garbage"))
        XCTAssertNil(ds.jwtExpiry("only.two"))   // invalid base64 payload
    }

    func testDecodeJWTPayload() {
        let token = Self.makeJWT(payload: ["sub": "abc", "n": 7])
        let payload = ds.decodeJWTPayload(token)
        XCTAssertEqual(payload?["sub"] as? String, "abc")
        XCTAssertNil(ds.decodeJWTPayload("x"))
    }

    /// Right after a 5-hour boundary the API briefly returns a `five_hour` reset that has already
    /// passed (the old window's). Live data must keep the session — it's authoritative — otherwise
    /// Claude's card and widget vanish for a few minutes. Stale fallbacks still blank a lapsed window.
    func testLiveClaudeKeepsSessionWhenResetJustLapsed() {
        let root: [String: Any] = [
            "five_hour": ["utilization": 7.0, "resets_at": "2020-01-01T00:00:00Z"],   // long past
            "seven_day": ["utilization": 1.0, "resets_at": "2030-01-01T00:00:00Z"],   // future
        ]
        // Live: session percent survives the lapsed reset.
        let live = ds.buildClaudeStatus(from: root, note: "oauth usage api", live: true)
        XCTAssertEqual(live.sessionRemainingPercent, 93)
        XCTAssertEqual(live.weeklyRemainingPercent, 99)
        XCTAssertTrue(live.isAvailable)

        // Stale fallback: a window whose reset has passed is blanked (it refilled); the weekly (future
        // reset) survives.
        let stale = ds.buildClaudeStatus(from: root, note: "snapshot", live: false)
        XCTAssertNil(stale.sessionRemainingPercent)
        XCTAssertEqual(stale.weeklyRemainingPercent, 99)
    }

    /// Build a base64url JWT (header.payload.sig) from a payload dict — only the payload is read.
    private static func makeJWT(payload: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let b64url = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(b64url).signature"
    }
}
