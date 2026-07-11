import XCTest
@testable import Mimir

/// The prompt-free statusLine hook: parsing Claude Code's `rate_limits` JSON, and the pure
/// settings-transform logic that wires/unwires the hook while chaining any existing status line.
final class ClaudeHookTests: XCTestCase {

    // MARK: - rate_limits parsing (resets_at is epoch SECONDS, unlike the OAuth API's ISO string)

    func testParseHookRateLimits() {
        let root: [String: Any] = [
            "rate_limits": [
                "five_hour": ["used_percentage": 4, "resets_at": 1_700_000_000],
                "seven_day": ["used_percentage": 81.5, "resets_at": 1_700_600_000],
            ],
            "model": ["display_name": "Opus"],
        ]
        let parsed = LiveUsageDataSource.parseHookRateLimits(root)
        XCTAssertEqual(parsed?.five.used, 4)
        XCTAssertEqual(parsed?.five.reset, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(parsed?.seven.used, 81.5)
        XCTAssertEqual(parsed?.seven.reset, Date(timeIntervalSince1970: 1_700_600_000))
    }

    func testParseHookMissingRateLimitsReturnsNil() {
        // No rate_limits (older Claude Code / no subscription limits) → nil, so callers fall through.
        XCTAssertNil(LiveUsageDataSource.parseHookRateLimits(["model": ["display_name": "Opus"]]))
        // Only one window present → nil (both are required for a session/weekly card).
        XCTAssertNil(LiveUsageDataSource.parseHookRateLimits([
            "rate_limits": ["five_hour": ["used_percentage": 10]]
        ]))
    }

    func testParseHookToleratesMissingResetAndStringNumbers() {
        let root: [String: Any] = [
            "rate_limits": [
                "five_hour": ["used_percentage": "12"],            // numeric string, no reset
                "seven_day": ["used_percentage": 50, "resets_at": "1700000000"],
            ]
        ]
        let parsed = LiveUsageDataSource.parseHookRateLimits(root)
        XCTAssertEqual(parsed?.five.used, 12)
        XCTAssertNil(parsed?.five.reset)                          // absent reset → nil, not a crash
        XCTAssertEqual(parsed?.seven.reset, Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: - statusLine wiring (pure)

    func testWireChainsExistingStatusLine() {
        let current: [String: Any] = [
            "statusLine": ["type": "command", "command": "bash \"/Users/x/.claude/ponytail.sh\""],
            "otherKey": 42,
        ]
        let (settings, chained) = MimirStatusLineHook.wiredSettings(from: current)
        XCTAssertEqual(chained, "bash \"/Users/x/.claude/ponytail.sh\"")   // preserved for passthrough
        let cmd = (settings["statusLine"] as? [String: Any])?["command"] as? String
        XCTAssertTrue(MimirStatusLineHook.isOurCommand(cmd))               // now points at our hook
        XCTAssertEqual(settings["otherKey"] as? Int, 42)                   // untouched
    }

    func testWireFromNoStatusLine() {
        let (settings, chained) = MimirStatusLineHook.wiredSettings(from: [:])
        XCTAssertNil(chained)
        XCTAssertTrue(MimirStatusLineHook.isOurCommand(
            (settings["statusLine"] as? [String: Any])?["command"] as? String))
    }

    func testWireWhenAlreadyOursDoesntSelfChain() {
        let current: [String: Any] = ["statusLine": ["type": "command", "command": MimirStatusLineHook.hookCommand]]
        let (_, chained) = MimirStatusLineHook.wiredSettings(from: current)
        XCTAssertNil(chained)   // never chain our own hook into itself (would recurse)
    }

    // MARK: - statusLine unwiring (pure)

    func testUnwireRestoresChainedCommand() {
        let current: [String: Any] = ["statusLine": ["type": "command", "command": MimirStatusLineHook.hookCommand]]
        let restored = MimirStatusLineHook.unwiredSettings(from: current, chained: "bash \"/x/ponytail.sh\"")
        XCTAssertEqual((restored["statusLine"] as? [String: Any])?["command"] as? String,
                       "bash \"/x/ponytail.sh\"")
    }

    func testUnwireDropsStatusLineWhenNoChain() {
        let current: [String: Any] = ["statusLine": ["type": "command", "command": MimirStatusLineHook.hookCommand]]
        let restored = MimirStatusLineHook.unwiredSettings(from: current, chained: nil)
        XCTAssertNil(restored["statusLine"])
    }

    func testUnwireLeavesForeignStatusLineUntouched() {
        // If the current statusLine isn't ours (user re-pointed it), don't clobber it.
        let current: [String: Any] = ["statusLine": ["type": "command", "command": "bash \"/x/other.sh\""]]
        let restored = MimirStatusLineHook.unwiredSettings(from: current, chained: "bash \"/x/ponytail.sh\"")
        XCTAssertEqual((restored["statusLine"] as? [String: Any])?["command"] as? String, "bash \"/x/other.sh\"")
    }

    // MARK: - script body

    func testScriptBodyAlwaysSavesUsageAndChainsWhenGiven() {
        let chained = MimirStatusLineHook.scriptBody(chained: "bash \"/x/ponytail.sh\"")
        XCTAssertTrue(chained.contains("mimir-usage.json"))        // always saves the raw JSON
        XCTAssertTrue(chained.contains("/x/ponytail.sh"))          // runs the chained command
        let solo = MimirStatusLineHook.scriptBody(chained: nil)
        XCTAssertTrue(solo.contains("mimir-usage.json"))
        XCTAssertTrue(solo.contains("jq"))                         // solo renders its own line via jq
    }
}
