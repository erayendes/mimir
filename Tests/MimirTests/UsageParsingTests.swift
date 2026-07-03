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

    /// `secureAtomicWrite` must land the file at 0o600 (never the umask default), on both a fresh
    /// write and an overwrite — that's the whole point of the TOCTOU fix for token files.
    func testSecureAtomicWriteIsAlways0600() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mimir-secwrite-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        func perms() throws -> Int? {
            try FileManager.default.attributesOfItem(atPath: tmp.path)[.posixPermissions] as? Int
        }

        // Fresh write (target absent → moveItem path).
        let first = Data("{\"token\":\"a\"}".utf8)
        try LiveUsageDataSource.secureAtomicWrite(data: first, to: tmp)
        XCTAssertEqual(try Data(contentsOf: tmp), first)
        XCTAssertEqual(try perms(), 0o600)

        // Overwrite (target exists → replaceItemAt path) still 0o600, new content.
        let second = Data("{\"token\":\"b\"}".utf8)
        try LiveUsageDataSource.secureAtomicWrite(data: second, to: tmp)
        XCTAssertEqual(try Data(contentsOf: tmp), second)
        XCTAssertEqual(try perms(), 0o600)
    }

    /// A symlinked credential file (dotfile-manager pattern) must be written *through*: the link is
    /// preserved and the real file behind it gets the new 0o600 content, not clobbered into a file.
    func testSecureAtomicWriteFollowsSymlink() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
        let real = dir.appendingPathComponent("mimir-real-\(UUID()).json")
        let link = dir.appendingPathComponent("mimir-link-\(UUID()).json")
        defer { try? fm.removeItem(at: real); try? fm.removeItem(at: link) }

        try Data("{\"t\":\"old\"}".utf8).write(to: real)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        let new = Data("{\"t\":\"new\"}".utf8)
        try LiveUsageDataSource.secureAtomicWrite(data: new, to: link)

        // Link still a symlink pointing at `real` (not replaced by a regular file)…
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), real.path)
        // …and the real file behind it got the new content at 0o600.
        XCTAssertEqual(try Data(contentsOf: real), new)
        XCTAssertEqual(try fm.attributesOfItem(atPath: real.path)[.posixPermissions] as? Int, 0o600)
    }

    /// Per-model weekly rows come from the `limits` array (`scope.model.display_name`), not the
    /// legacy flat `seven_day_<model>` keys — the API now returns those as null. This mirrors a real
    /// captured response: session 93%, all-models 34%, and a scoped "Fable" row at 66% used.
    func testClaudeScopedModelRowFromLimitsArray() {
        let root: [String: Any] = [
            "five_hour": ["utilization": 93.0, "resets_at": "2030-01-01T00:00:00Z"],
            "seven_day": ["utilization": 34.0, "resets_at": "2030-01-08T00:00:00Z"],
            "seven_day_sonnet": NSNull(),   // legacy key: now dead, must be ignored
            "limits": [
                ["kind": "session", "group": "session", "percent": 93, "resets_at": "2030-01-01T00:00:00Z", "scope": NSNull()],
                ["kind": "weekly_all", "group": "weekly", "percent": 34, "resets_at": "2030-01-08T00:00:00Z", "scope": NSNull()],
                ["kind": "weekly_scoped", "group": "weekly", "percent": 66, "resets_at": "2030-01-08T00:00:00Z",
                 "scope": ["model": ["id": NSNull(), "display_name": "Fable"], "surface": NSNull()]],
            ],
        ]
        let status = ds.buildClaudeStatus(from: root, note: "oauth usage api")
        XCTAssertEqual(status.models.map(\.name), ["Fable"])
        XCTAssertEqual(status.models.first?.remainingPercent, 34)   // 100 - 66
    }

    /// Multiple scoped models appear as separate rows, in the order the API returns them — no
    /// hardcoded model list needed for a new tier to show up.
    func testClaudeMultipleScopedModelRows() {
        let root: [String: Any] = [
            "five_hour": ["utilization": 10.0, "resets_at": "2030-01-01T00:00:00Z"],
            "seven_day": ["utilization": 10.0, "resets_at": "2030-01-08T00:00:00Z"],
            "limits": [
                ["kind": "weekly_scoped", "group": "weekly", "percent": 20, "resets_at": "2030-01-08T00:00:00Z",
                 "scope": ["model": ["display_name": "Fable"], "surface": NSNull()]],
                ["kind": "weekly_scoped", "group": "weekly", "percent": 50, "resets_at": "2030-01-08T00:00:00Z",
                 "scope": ["model": ["display_name": "Opus"], "surface": NSNull()]],
            ],
        ]
        let status = ds.buildClaudeStatus(from: root, note: "oauth usage api")
        XCTAssertEqual(status.models.map(\.name), ["Fable", "Opus"])
        XCTAssertEqual(status.models.map(\.remainingPercent), [80, 50])
    }

    /// The new `spend` object is preferred over the legacy `extra_usage` shape when both are present
    /// and `spend` is enabled.
    func testClaudeBillingPrefersSpendOverLegacyExtraUsage() {
        let root: [String: Any] = [
            "five_hour": ["utilization": 0.0, "resets_at": "2030-01-01T00:00:00Z"],
            "seven_day": ["utilization": 0.0, "resets_at": "2030-01-08T00:00:00Z"],
            "extra_usage": ["is_enabled": true, "used_credits": 999.0, "monthly_limit": 999.0, "currency": "USD"],
            "spend": [
                "enabled": true,
                "percent": 50.0,
                "used": ["amount_minor": 500, "currency": "USD", "exponent": 2],
                "limit": ["amount_minor": 1000, "currency": "USD", "exponent": 2],
            ],
        ]
        let status = ds.buildClaudeStatus(from: root, note: "oauth usage api")
        let billing = status.models.first { $0.name == "Billing" }
        XCTAssertEqual(billing?.valueText, "5 USD / 10 USD")
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
