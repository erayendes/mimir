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

    /// #111: a five-hour window the fresh hook left out has reset — refilled to 100% on a normal
    /// account, but not rebuilt from an older cache on Ultra (it loses the window after
    /// verification). The weekly one refills either way.
    func testHookWithoutFiveHourRefillsItUnlessUltra() {
        let cached: [String: Any] = ["five_hour": ["utilization": 40.0], "seven_day": ["utilization": 30.0]]
        let source = LiveUsageDataSource()
        for plan: String? in [nil, "Pro", "Max", "Team"] {
            let card = source.claudeCardFromHook((five: nil, seven: (used: 12, reset: nil)), cached: cached, plan: plan)
            XCTAssertEqual(card.sessionRemainingPercent, 100, "plan: \(String(describing: plan))")
            XCTAssertNotNil(card.weeklyRemainingPercent)
        }
        let ultra = source.claudeCardFromHook((five: nil, seven: (used: 12, reset: nil)), cached: cached, plan: "Ultra")
        XCTAssertNil(ultra.sessionRemainingPercent)
        XCTAssertNotNil(ultra.weeklyRemainingPercent)
        // A cache whose answer already had the five-hour window null never grows one back.
        let noFive = source.claudeCardFromHook((five: nil, seven: (used: 12, reset: nil)),
                                               cached: ["five_hour": NSNull(), "seven_day": ["utilization": 30.0]],
                                               plan: "Max")
        XCTAssertNil(noFive.sessionRemainingPercent)
        let sevenGone = source.claudeCardFromHook((five: (used: 5, reset: nil), seven: nil), cached: cached, plan: "Ultra")
        XCTAssertEqual(sevenGone.weeklyRemainingPercent, 100)
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

    private func expectedWindow(_ label: String, _ percent: Int) -> String {
        let color = percent >= 40 ? 32 : (percent >= 10 ? 33 : 31)
        let filled = (percent + 5) / 10
        let bar = (filled > 0 ? "\u{1B}[\(color)m" + String(repeating: "█", count: filled) + "\u{1B}[0m" : "")
            + (filled < 10 ? "\u{1B}[2m" + String(repeating: "░", count: 10 - filled) + "\u{1B}[0m" : "")
        return "\(label) \(bar) \u{1B}[\(color)m\(percent)%\u{1B}[0m"
    }

    private func markedWindow(_ label: String, _ percent: Int, marker: Int,
                              color: Int = 32, countdown: String? = nil, note: String? = nil) -> String {
        let filled = (percent + 5) / 10
        let bar = (0..<10).map { cell in
            if cell == marker { return "\u{1B}[1;97m│\u{1B}[0m" }
            if cell < filled { return "\u{1B}[\(color)m█\u{1B}[0m" }
            return "\u{1B}[2m░\u{1B}[0m"
        }.joined()
        return "\(label) \(bar) \u{1B}[\(color)m\(percent)%\u{1B}[0m"
            + (countdown.map { " " + $0 } ?? "") + (note.map { " " + $0 } ?? "")
    }

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
                           "Mimir  \(expectedWindow("5h", remaining))  ·  \(expectedWindow("7d", 19))\n",
                           "used_percentage = \(used)")
            XCTAssertEqual(source.remainingPercent(fromUsed: used), remaining)
        }
    }

    func testScriptUsesStaticColorBoundariesAndExactANSIBytes() throws {
        for (remaining, color) in [(40, 32), (39, 33), (10, 33), (9, 31)] {
            let input = "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":\(100 - remaining)}}}"
            let actual = try runScript(input: input)
            let expected = "Mimir  \(expectedWindow("5h", remaining))\n"
            XCTAssertEqual(Data(actual.utf8), Data(expected.utf8), "remaining = \(remaining), ANSI = \(color)")
        }
        let input = #"{"rate_limits":{"five_hour":{"used_percentage":30}}}"#
        XCTAssertEqual(Data(try runScript(input: input).utf8),
                       Data("Mimir  5h \u{1B}[32m███████\u{1B}[0m\u{1B}[2m░░░\u{1B}[0m \u{1B}[32m70%\u{1B}[0m\n".utf8))
    }

    func testScriptRoundsBarFromUnroundedRemaining() throws {
        for (used, filled) in [(25.5, 7), (25.0, 8)] {
            let input = "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":\(used)}}}"
            let bar = "\u{1B}[32m" + String(repeating: "█", count: filled) + "\u{1B}[0m"
                + "\u{1B}[2m" + String(repeating: "░", count: 10 - filled) + "\u{1B}[0m"
            let expected = "Mimir  5h \(bar) \u{1B}[32m75%\u{1B}[0m\n"
            XCTAssertEqual(Data(try runScript(input: input).utf8), Data(expected.utf8))
        }
    }

    func testScriptOmitsUnavailableWindows() throws {
        let cases = [
            (#"{"rate_limits":{"five_hour":{"used_percentage":0}}}"#, "Mimir  \(expectedWindow("5h", 100))\n"),
            (#"{"rate_limits":{"seven_day":{"used_percentage":100}}}"#, "Mimir  \(expectedWindow("7d", 0))\n"),
            (#"{"rate_limits":{"five_hour":null,"seven_day":{"used_percentage":33}}}"#, "Mimir  \(expectedWindow("7d", 67))\n"),
            (#"{"rate_limits":{"five_hour":{},"seven_day":{"used_percentage":33}}}"#, "Mimir  \(expectedWindow("7d", 67))\n"),
            (#"{"rate_limits":{"five_hour":{"used_percentage":null},"seven_day":{"used_percentage":"12"}}}"#, "Mimir  \(expectedWindow("7d", 88))\n"),
            (#"{"rate_limits":{"five_hour":{"used_percentage":"unknown"},"seven_day":{"used_percentage":33}}}"#, "Mimir  \(expectedWindow("7d", 67))\n"),
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

    func testCountdownAndMarkerInFilledAndEmptyCells() throws {
        let now = 2_000_000_000
        let five = now + 2 * 3600 + 15 * 60
        let week = now + 3 * 86400 + 4 * 3600 // ideal 45%: cell 4
        for (remaining, markerInFill) in [(70, true), (20, false)] {
            let input = """
            {"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":\(five)},
              "seven_day":{"used_percentage":\(100 - remaining),"resets_at":\(week)}}}
            """
            let expected = "Mimir  \(expectedWindow("5h", 70)) 2h15m  ·  "
                + markedWindow("7d", remaining, marker: 4,
                               color: remaining >= 40 ? 32 : 33, countdown: "3d4h") + "\n"
            XCTAssertEqual(Data(try runScript(input: input, clock: now).utf8), Data(expected.utf8),
                           "markerInFill = \(markerInFill)")
        }
    }

    func testMarkerEdgesAndEarlyStretch() throws {
        let now = 2_000_000_000
        let reset = now + 3 * 86400
        for (ideal, marker) in [(0, 0), (99, 9)] {
            let pace = """
            {"windows":{"seven_day":{"tone":"green","idealPercent":\(ideal),"resetAt":\(reset),"writtenAt":\(now)}}}
            """
            let input = "{\"rate_limits\":{\"seven_day\":{\"used_percentage\":50,\"resets_at\":\(reset)}}}"
            XCTAssertEqual(try runScript(input: input, pace: pace, clock: now),
                           "Mimir  " + markedWindow("7d", 50, marker: marker, countdown: "3d") + "\n")
        }
        let early = now + 7 * 86400 - 3600
        let input = "{\"rate_limits\":{\"seven_day\":{\"used_percentage\":50,\"resets_at\":\(early)}}}"
        XCTAssertEqual(try runScript(input: input, clock: now), "Mimir  \(expectedWindow("7d", 50)) 6d23h\n")
    }

    func testFreshPaceOverridesColorAndAppendsRedNoteButStaleFallsBack() throws {
        let now = 2_000_000_000
        let reset = now + 3 * 86400 + 4 * 3600
        let input = "{\"rate_limits\":{\"seven_day\":{\"used_percentage\":30,\"resets_at\":\(reset)}}}"
        func pace(_ written: Int, _ resetAt: Int) -> String {
            "{\"windows\":{\"seven_day\":{\"tone\":\"red\",\"idealPercent\":80,\"note\":\"~2 gün kotasız\",\"resetAt\":\(resetAt),\"writtenAt\":\(written)}}}"
        }
        let fresh = "Mimir  " + markedWindow("7d", 70, marker: 8, color: 31,
                                               countdown: "3d4h", note: "~2 gün kotasız") + "\n"
        XCTAssertEqual(Data(try runScript(input: input, pace: pace(now, reset), clock: now).utf8), Data(fresh.utf8))
        let fallback = "Mimir  " + markedWindow("7d", 70, marker: 4, countdown: "3d4h") + "\n"
        for file in [nil, pace(now - 1801, reset), pace(now, reset + 3600)] {
            XCTAssertEqual(Data(try runScript(input: input, pace: file, clock: now).utf8), Data(fallback.utf8))
        }
    }

    func testMinuteCountdownAndExpiredReset() throws {
        let now = 2_000_000_000
        let input = "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":60,\"resets_at\":\(now + 45 * 60)},\"seven_day\":{\"used_percentage\":60,\"resets_at\":\(now - 1)}}}"
        XCTAssertEqual(try runScript(input: input, clock: now),
                       "Mimir  \(expectedWindow("5h", 40)) 45m  ·  \(expectedWindow("7d", 40))\n")
    }

    func testClaudeWidthDropsCountdownsThenBars() throws {
        let now = 2_000_000_000
        let input = "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":30,\"resets_at\":\(now + 8100)},\"seven_day\":{\"used_percentage\":60,\"resets_at\":\(now + 3 * 86400 + 4 * 3600)}}}"
        let bare = "Mimir  5h ██████████ 70%  ·  7d ██████████ 40%"
        let full = "Mimir  5h ██████████ 70% 2h15m  ·  7d ██████████ 40% 3d4h"
        let bars = "Mimir  \(expectedWindow("5h", 70))  ·  "
            + markedWindow("7d", 40, marker: 4) + "\n"
        XCTAssertEqual(try runScript(input: input, columns: full.count - 1, clock: now), bars)
        let percent = "Mimir  5h \u{1B}[32m70%\u{1B}[0m  ·  7d \u{1B}[32m40%\u{1B}[0m\n"
        XCTAssertEqual(Data(try runScript(input: input, columns: bare.count - 1, clock: now).utf8), Data(percent.utf8))
        let reset = now + 3 * 86400 + 4 * 3600
        let pace = "{\"windows\":{\"seven_day\":{\"tone\":\"red\",\"idealPercent\":80,\"note\":\"~2 gün kotasız\",\"resetAt\":\(reset),\"writtenAt\":\(now)}}}"
        let withNote = "Mimir  5h \u{1B}[32m70%\u{1B}[0m  ·  7d \u{1B}[31m40%\u{1B}[0m ~2 gün kotasız\n"
        XCTAssertEqual(Data(try runScript(input: input, pace: pace, columns: bare.count - 1, clock: now).utf8),
                       Data(withNote.utf8))
    }

    /// Run the generated hook in an isolated Claude config directory; never touch the user's hook.
    private func runScript(input: String, chained: String? = nil, pace: String? = nil,
                           columns: Int? = nil, clock: Int? = nil) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimir-test-statusline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let inputURL = directory.appendingPathComponent("input.json")
        try Data(input.utf8).write(to: inputURL)
        if let pace { try pace.write(to: directory.appendingPathComponent("mimir-pace.json"), atomically: true, encoding: .utf8) }
        if let clock {
            let bin = directory.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let date = bin.appendingPathComponent("date")
            try "#!/bin/sh\necho \(clock)\n".write(to: date, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: date.path)
        }
        let inputHandle = try FileHandle(forReadingFrom: inputURL)
        defer { try? inputHandle.close() }
        let output = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", MimirStatusLineHook.scriptBody(chained: chained)]
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CONFIG_DIR"] = directory.path
        if let columns { environment["COLUMNS"] = String(columns) } else { environment.removeValue(forKey: "COLUMNS") }
        if clock != nil { environment["PATH"] = directory.appendingPathComponent("bin").path + ":" + (environment["PATH"] ?? "/usr/bin:/bin") }
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
