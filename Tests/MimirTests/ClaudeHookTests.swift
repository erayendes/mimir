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
        XCTAssertEqual(parsed?.five?.used, 4)
        XCTAssertEqual(parsed?.five?.reset, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(parsed?.seven?.used, 81.5)
        XCTAssertEqual(parsed?.seven?.reset, Date(timeIntervalSince1970: 1_700_600_000))
    }

    func testParseHookMissingRateLimitsReturnsNil() {
        // No rate_limits at all (older Claude Code / no subscription limits) → nil, callers fall through.
        XCTAssertNil(LiveUsageDataSource.parseHookRateLimits(["model": ["display_name": "Opus"]]))
    }

    func testParseHookToleratesOneWindowMissing() {
        // Anthropic's own statusline docs confirm five_hour/seven_day can each be independently
        // absent (no session yet this launch, a Team-plan account, or a window past its reset) — a
        // partial reading must still come back rather than being discarded outright.
        let fiveOnly = LiveUsageDataSource.parseHookRateLimits([
            "rate_limits": ["five_hour": ["used_percentage": 10]]
        ])
        XCTAssertEqual(fiveOnly?.five?.used, 10)
        XCTAssertNil(fiveOnly?.seven)

        let sevenOnly = LiveUsageDataSource.parseHookRateLimits([
            "rate_limits": ["seven_day": ["used_percentage": 33]]
        ])
        XCTAssertNil(sevenOnly?.five)
        XCTAssertEqual(sevenOnly?.seven?.used, 33)
    }

    func testParseHookToleratesMissingResetAndStringNumbers() {
        let root: [String: Any] = [
            "rate_limits": [
                "five_hour": ["used_percentage": "12"],            // numeric string, no reset
                "seven_day": ["used_percentage": 50, "resets_at": "1700000000"],
            ]
        ]
        let parsed = LiveUsageDataSource.parseHookRateLimits(root)
        XCTAssertEqual(parsed?.five?.used, 12)
        XCTAssertNil(parsed?.five?.reset)                         // absent reset → nil, not a crash
        XCTAssertEqual(parsed?.seven?.reset, Date(timeIntervalSince1970: 1_700_000_000))
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

    func testScriptRendersRemainingPercentWithAppRoundingAndClamping() throws {
        let source = LiveUsageDataSource()
        let cases: [(Double, Int)] = [
            (0, 100), (100, 0), (4, 96), (81.5, 19), (30.4, 70), (30.5, 70),
            (30.6, 69), (99.5, 1), (99.6, 0), (-10, 100), (150, 0),
        ]
        for (used, remaining) in cases {
            let input = """
            {"rate_limits":{"five_hour":{"used_percentage":\(used)},"seven_day":{"used_percentage":81.5}}}
            """
            XCTAssertEqual(try runScript(input: input),
                           "Mimir  5h \(remaining)%  ·  7d 19%\n",
                           "used_percentage = \(used)")
            XCTAssertEqual(source.remainingPercent(fromUsed: used), remaining)
        }
    }

    func testScriptOmitsUnavailableWindows() throws {
        let cases = [
            (#"{"rate_limits":{"five_hour":{"used_percentage":0}}}"#, "Mimir  5h 100%\n"),
            (#"{"rate_limits":{"seven_day":{"used_percentage":100}}}"#, "Mimir  7d 0%\n"),
            (#"{"rate_limits":{"five_hour":null,"seven_day":{"used_percentage":33}}}"#, "Mimir  7d 67%\n"),
            (#"{"rate_limits":{"five_hour":{},"seven_day":{"used_percentage":33}}}"#, "Mimir  7d 67%\n"),
            (#"{"rate_limits":{"five_hour":{"used_percentage":null},"seven_day":{"used_percentage":"12"}}}"#, "Mimir  7d 88%\n"),
            (#"{"rate_limits":{"five_hour":{"used_percentage":"unknown"},"seven_day":{"used_percentage":33}}}"#, "Mimir  7d 67%\n"),
            (#"{"rate_limits":{}}"#, ""),
            (#"{"rate_limits":null}"#, ""),
            (#"{"model":{"display_name":"Opus"}}"#, ""),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(try runScript(input: input), expected, input)
        }
    }

    func testScriptPreservesChainedOutputAndInput() throws {
        let input = #"{"rate_limits":{"five_hour":{"used_percentage":4}}}"#
        XCTAssertEqual(try runScript(input: input, chained: "printf 'custom status\\n'; cat"),
                       "custom status\n" + input)
    }

    /// Run the generated hook in an isolated Claude config directory; never touch the user's hook.
    private func runScript(input: String, chained: String? = nil) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimir-test-statusline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let inputURL = directory.appendingPathComponent("input.json")
        try Data(input.utf8).write(to: inputURL)
        let inputHandle = try FileHandle(forReadingFrom: inputURL)
        defer { try? inputHandle.close() }
        let output = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", MimirStatusLineHook.scriptBody(chained: chained)]
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CONFIG_DIR"] = directory.path
        task.environment = environment
        task.standardInput = inputHandle
        task.standardOutput = output
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        XCTAssertEqual(task.terminationStatus, 0, "Hook failed; rendering requires jq on PATH")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("mimir-usage.json"),
                                  encoding: .utf8), input)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - wire extra dirs

    func testWireExtraDirsOnlyWiresOnceAndBacksUpSettings() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mimir-test-extra-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settingsPath = tempDir.appendingPathComponent("settings.json").path
        let markerPath = tempDir.appendingPathComponent("mimir-wired").path
        let backupPath = tempDir.appendingPathComponent("settings.json.mimir-backup").path

        let initialSettings = "{\n  \"env\": \"work\"\n}"
        try initialSettings.write(toFile: settingsPath, atomically: true, encoding: .utf8)

        let account = ExtraAccount(name: "Claude Work", dir: tempDir)

        // First wiring: creates backup, writes hook to settings.json, creates mimir-wired marker
        MimirStatusLineHook.wireExtraDirs(true, accounts: [account])

        XCTAssertTrue(FileManager.default.fileExists(atPath: markerPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupPath))
        let backedUpContent = try String(contentsOfFile: backupPath, encoding: .utf8)
        XCTAssertEqual(backedUpContent, initialSettings)

        let wiredData = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let wiredJson = try JSONSerialization.jsonObject(with: wiredData) as? [String: Any]
        let cmd = (wiredJson?["statusLine"] as? [String: Any])?["command"] as? String
        XCTAssertTrue(MimirStatusLineHook.isOurCommand(cmd))

        // User deliberately removes hook from settings.json
        try initialSettings.write(toFile: settingsPath, atomically: true, encoding: .utf8)

        // Subsequent wire (e.g. app launch / refreshScript) skips because marker exists
        MimirStatusLineHook.wireExtraDirs(true, accounts: [account])
        let recheckedContent = try String(contentsOfFile: settingsPath, encoding: .utf8)
        XCTAssertEqual(recheckedContent, initialSettings)

        // Unwiring removes the marker
        MimirStatusLineHook.wireExtraDirs(false, accounts: [account])
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath))
    }
}
