import Foundation
import Testing
@testable import Mimir

/// All disk operations and subprocess HOME/config overrides are isolated. These tests never call
/// the production lifecycle entry points, which resolve the user's actual CLI directories.
struct CLIStatusLineHookTests {
    private static func expectedWindow(_ label: String, _ percent: Int, bars: Bool = true) -> String {
        let color = percent >= 40 ? 32 : (percent >= 10 ? 33 : 31)
        let filled = (percent + 5) / 10
        let bar = bars
            ? (filled > 0 ? "\u{1B}[\(color)m" + String(repeating: "█", count: filled) + "\u{1B}[0m" : "")
                + (filled < 10 ? "\u{1B}[2m" + String(repeating: "░", count: 10 - filled) + "\u{1B}[0m" : "") + " "
            : ""
        return "\(label) \(bar)\u{1B}[\(color)m\(percent)%\u{1B}[0m"
    }

    private static func markedWeek(_ percent: Int, marker: Int, color: Int,
                                   countdown: String = "", note: String = "") -> String {
        let filled = (percent + 5) / 10
        let cells = (0..<10).map { cell in
            if cell == marker { return "\u{1B}[1;97m│\u{1B}[0m" }
            return cell < filled ? "\u{1B}[\(color)m█\u{1B}[0m" : "\u{1B}[2m░\u{1B}[0m"
        }.joined()
        return "7d \(cells) \u{1B}[\(color)m\(percent)%\u{1B}[0m" + countdown + note
    }

    private static func expectedLine(_ model: String = "", _ five: Int? = nil, _ week: Int? = nil, bars: Bool = true) -> String {
        let windows = [("5h", five), ("7d", week)].compactMap { label, percent in
            percent.map { expectedWindow(label, $0, bars: bars) }
        }
        guard !windows.isEmpty else { return "" }
        return "" + (model.isEmpty ? "" : model + "  ") + windows.joined(separator: "  ·  ") + "\n"
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimir-cli-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func write(_ text: String, _ name: String, in directory: URL) throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func read(_ name: String, in directory: URL) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    private func settings(in directory: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("settings.json")))
            as? [String: Any])
    }

    private func runAGY(input: String, chained: String? = nil,
                        displayMode: StatusLineDisplayMode = .keepCurrent, expectChainedRun: Bool? = nil,
                        pace: String? = nil,
                        clock: Int? = nil) throws -> String {
        var result = ""
        try withDirectory { directory in
            try write(input, "input.json", in: directory)
            try write(AntigravityStatusLineHook.scriptBody(chained: chained, displayMode: displayMode), "mimir-statusline.sh", in: directory)
            if let pace { try write(pace, "mimir-pace.json", in: directory) }
            if let clock {
                let bin = directory.appendingPathComponent("bin")
                try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                try write("#!/bin/sh\necho \(clock)\n", "bin/date", in: directory)
                try FileManager.default.setAttributes([.posixPermissions: 0o755],
                    ofItemAtPath: bin.appendingPathComponent("date").path)
            }
            let inputHandle = try FileHandle(forReadingFrom: directory.appendingPathComponent("input.json"))
            defer { try? inputHandle.close() }
            let output = Pipe()
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [directory.appendingPathComponent("mimir-statusline.sh").path]
            var environment = ProcessInfo.processInfo.environment
            for key in ["HOME", "CLAUDE_CONFIG_DIR", "CODEX_HOME"] { environment[key] = directory.path }
            environment.removeValue(forKey: "COLUMNS")
            if clock != nil { environment["PATH"] = directory.appendingPathComponent("bin").path + ":" + (environment["PATH"] ?? "/usr/bin:/bin") }
            task.environment = environment
            task.standardInput = inputHandle
            task.standardOutput = output
            try task.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            if let expectChainedRun {
                #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("chained-input").path) == expectChainedRun)
                if expectChainedRun { #expect(try read("chained-input", in: directory) == input) }
            }
            #expect(task.terminationStatus == 0, "Rendering requires jq on PATH")
            result = String(decoding: data, as: UTF8.self)
            #expect(try read("mimir-usage.json", in: directory) == input)
            let mode = try FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent("mimir-usage.json").path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o600)
        }
        return result
    }

    @Test(arguments: [
        (0.0, 0), (1.0, 100), (0.815, 82), (0.304, 30), (0.305, 31),
        (0.306, 31), (0.005, 1), (0.004, 0), (-0.1, 0), (1.5, 100),
    ])
    func agyRemainingPercent(fraction: Double, expected: Int) throws {
        let input = """
        {"model":{"id":"gemini-3.8-flash","display_name":"Gemini 3.8 Flash (Medium)"},"quota":{
          "gemini-5h":{"remaining_fraction":\(fraction)},
          "gemini-weekly":{"remaining_fraction":0.9378},
          "3p-5h":{"remaining_fraction":0.01},"3p-weekly":{"remaining_fraction":0.02}}}
        """
        #expect(try runAGY(input: input) == CLIStatusLineHookTests.expectedLine("Gemini 3.8 Flash", expected, 94))
    }

    @Test(arguments: [(0.4, 40), (0.39, 39), (0.1, 10), (0.09, 9)])
    func agyUsesStaticColorBoundaries(fraction: Double, remaining: Int) throws {
        let input = "{\"quota\":{\"gemini-5h\":{\"remaining_fraction\":\(fraction)}}}"
        #expect(Data(try runAGY(input: input).utf8) == Data(CLIStatusLineHookTests.expectedLine("", remaining).utf8))
    }

    @Test func agyDropsBarsOnlyWhenTerminalIsNarrow() throws {
        let quota = #""quota":{"gemini-5h":{"remaining_fraction":0.7},"gemini-weekly":{"remaining_fraction":0.4}}"#
        let prefix = "{\"model\":{\"display_name\":\"Gemini 3.8 Flash\"}," + quota
        let fullWidth = "Gemini 3.8 Flash  5h 70%  ·  7d 40%".count + 22
        let full = try runAGY(input: prefix + ",\"terminal_width\":\(fullWidth)}")
        let narrow = try runAGY(input: prefix + ",\"terminal_width\":\(fullWidth - 1)}")
        #expect(Data(full.utf8) == Data(CLIStatusLineHookTests.expectedLine("Gemini 3.8 Flash", 70, 40).utf8))
        #expect(Data(narrow.utf8) == Data(CLIStatusLineHookTests.expectedLine("Gemini 3.8 Flash", 70, 40, bars: false).utf8))
        #expect(Data(narrow.utf8) == Data("Gemini 3.8 Flash  5h \u{1B}[32m70%\u{1B}[0m  ·  7d \u{1B}[32m40%\u{1B}[0m\n".utf8))
    }

    @Test func agyCountdownPaceAndWidthStages() throws {
        let now = 2_000_000_000
        let reset = now + 3 * 86400 + 4 * 3600
        let iso = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(reset)))
        let quota = "\"model\":{\"id\":\"gemini\"},\"quota\":{\"gemini-5h\":{\"remaining_fraction\":0.7,\"reset_in_seconds\":8100},\"gemini-weekly\":{\"remaining_fraction\":0.4,\"reset_time\":\"\(iso)\"}}"
        let input = "{" + quota + "}"
        let five = Self.expectedWindow("5h", 70)
        let week = Self.markedWeek(40, marker: 4, color: 32, countdown: " 3d4h")
        #expect(Data(try runAGY(input: input, clock: now).utf8) == Data("gemini  \(five) 2h15m  ·  \(week)\n".utf8))

        let pace = "{\"windows\":{\"gemini\":{\"tone\":\"red\",\"idealPercent\":80,\"note\":\"~2 gün kotasız\",\"resetAt\":\(reset),\"writtenAt\":\(now)}}}"
        let red = "gemini  \(five) 2h15m  ·  "
            + Self.markedWeek(40, marker: 8, color: 31, countdown: " 3d4h", note: " ~2 gün kotasız") + "\n"
        #expect(Data(try runAGY(input: input, pace: pace, clock: now).utf8) == Data(red.utf8))
        let stale = pace.replacingOccurrences(of: "\"writtenAt\":\(now)", with: "\"writtenAt\":\(now - 1801)")
        #expect(Data(try runAGY(input: input, pace: stale, clock: now).utf8)
                == Data("gemini  \(five) 2h15m  ·  \(week)\n".utf8))

        let noCountdown = "gemini  5h ██████████ 70%  ·  7d ██████████ 40%"
        let full = "gemini  5h ██████████ 70% 2h15m  ·  7d ██████████ 40% 3d4h"
        let barsInput = "{" + quota + ",\"terminal_width\":\(full.count - 1)}"
        #expect(Data(try runAGY(input: barsInput, clock: now).utf8)
                == Data("gemini  \(five)  ·  \(Self.markedWeek(40, marker: 4, color: 32))\n".utf8))
        let narrowInput = "{" + quota + ",\"terminal_width\":\(noCountdown.count - 1)}"
        #expect(Data(try runAGY(input: narrowInput, clock: now).utf8)
                == Data("gemini  5h \u{1B}[32m70%\u{1B}[0m  ·  7d \u{1B}[32m40%\u{1B}[0m\n".utf8))
    }

    @Test(arguments: [(0.745, 7), (0.75, 8)])
    func agyRoundsBarFromUnroundedRemaining(fraction: Double, filled: Int) throws {
        let input = "{\"quota\":{\"gemini-5h\":{\"remaining_fraction\":\(fraction)}}}"
        let bar = "\u{1B}[32m" + String(repeating: "█", count: filled) + "\u{1B}[0m"
            + "\u{1B}[2m" + String(repeating: "░", count: 10 - filled) + "\u{1B}[0m"
        let expected = "5h \(bar) \u{1B}[32m75%\u{1B}[0m\n"
        #expect(Data(try runAGY(input: input).utf8) == Data(expected.utf8))
    }

    @Test(arguments: [
        (#"{"quota":{"gemini-5h":{"remaining_fraction":0.8}}}"#, CLIStatusLineHookTests.expectedLine("", 80)),
        (#"{"quota":{"gemini-weekly":{"remaining_fraction":0.9378}}}"#, CLIStatusLineHookTests.expectedLine("", nil, 94)),
        (#"{"quota":{"gemini-5h":{"remaining_fraction":null},"gemini-weekly":{"remaining_fraction":"0.5"}}}"#, CLIStatusLineHookTests.expectedLine("", nil, 50)),
        (#"{"quota":{"gemini-5h":{"remaining_fraction":"unknown"},"gemini-weekly":{"remaining_fraction":0.5}}}"#, CLIStatusLineHookTests.expectedLine("", nil, 50)),
        (#"{"quota":{"gemini-5h":{"remaining_fraction":0.9,"disabled":true}}}"#, ""),
        (#"{"quota":{"gemini-weekly":{"remaining_amount":100}}}"#, ""),
        (#"{"model":{"display_name":"Gemini 3.8 Flash (Medium)"},"quota":{}}"#, ""),
        (#"{"quota":null}"#, ""),
        (#"{"model":null}"#, ""),
        (#"{"quota":{}}"#, ""),
    ])
    func agyOmitsMissingWindows(input: String, expected: String) throws {
        #expect(try runAGY(input: input) == expected)
    }

    @Test func agyDisplaysModelNameAndFallsBackToID() throws {
        let quota = #""quota":{"gemini-5h":{"remaining_fraction":0.99},"gemini-weekly":{"remaining_fraction":0.99}}"#
        #expect(try runAGY(input: "{\"model\":{\"id\":\"gemini-3.8-flash\",\"display_name\":\"Gemini 3.8 Flash (Medium)\"}," + quota + "}")
            == CLIStatusLineHookTests.expectedLine("Gemini 3.8 Flash", 99, 99))
        #expect(try runAGY(input: "{\"model\":{\"id\":\"gemini-3.8-flash\"}," + quota + "}")
            == CLIStatusLineHookTests.expectedLine("gemini-3.8-flash", 99, 99))
    }

    @Test func agySelectsFamilyAndUsesMinimumWhenAmbiguous() throws {
        let quota = #"""
        "quota":{"gemini-5h":{"remaining_fraction":0.8},"gemini-weekly":{"remaining_fraction":0.1},
        "3p-5h":{"remaining_fraction":0.3},"3p-weekly":{"remaining_fraction":0.7}}
        """#
        #expect(try runAGY(input: "{\"model\":{\"display_name\":\"Claude Opus\"}," + quota + "}")
            == CLIStatusLineHookTests.expectedLine("Claude Opus", 30, 70))
        #expect(try runAGY(input: "{\"model\":{\"id\":\"opaque-id\",\"display_name\":\"Claude Opus\"}," + quota + "}")
            == CLIStatusLineHookTests.expectedLine("Claude Opus", 30, 70))
        #expect(try runAGY(input: "{\"model\":{\"id\":\"custom\"}," + quota + "}")
            == CLIStatusLineHookTests.expectedLine("custom", 30, 10))
        // A known family's missing window must not borrow a different family's number.
        #expect(try runAGY(input: #"{"model":{"id":"Gemini"},"quota":{"gemini-weekly":{"remaining_fraction":0.5},"3p-5h":{"remaining_fraction":0.2}}}"#)
            == CLIStatusLineHookTests.expectedLine("Gemini", nil, 50))
        #expect(try runAGY(input: #"{"model":{"id":"Claude"},"quota":{"gemini-weekly":{"remaining_fraction":0.5},"3p-weekly":{"remaining_fraction":0.2}}}"#)
            == CLIStatusLineHookTests.expectedLine("Claude", nil, 20))
    }

    @Test func agyKeepsArgonQuotaSeparateFromGemini() throws {
        let quota = #"""
        "quota":{"3p-5h":{"remaining_fraction":0.05},"3p-weekly":{"remaining_fraction":0.06},
        "gemini-5h":{"remaining_fraction":0.8},"gemini-weekly":{"remaining_fraction":0.9},
        "gemini-argon-wtu-weekly":{"remaining_fraction":0.1}}
        """#
        #expect(try runAGY(input: "{\"model\":{\"id\":\"gemini-3.8-flash\",\"display_name\":\"Gemini 3.8 Flash\"}," + quota + "}")
            == CLIStatusLineHookTests.expectedLine("Gemini 3.8 Flash", 80, 90))
        #expect(try runAGY(input: "{\"model\":{\"id\":\"opaque-id\",\"display_name\":\"Gemini 4 Argon\"}," + quota + "}")
            == CLIStatusLineHookTests.expectedLine("Gemini 4 Argon", nil, 10))
        #expect(try runAGY(input: "{\"model\":{\"id\":\"gemini-4-argon\",\"display_name\":\"Gemini 4\"}," + quota + "}")
            == CLIStatusLineHookTests.expectedLine("Gemini 4", nil, 10))
    }

    @Test func agyUsesShared3pQuotaForGPTAndClaude() throws {
        let quota = #"""
        "quota":{"3p-5h":{"remaining_fraction":0.4},"3p-weekly":{"remaining_fraction":0.6},
        "gemini-5h":{"remaining_fraction":0.05},"gemini-weekly":{"remaining_fraction":0.1}}
        """#
        #expect(try runAGY(input: "{\"model\":{\"id\":\"gpt-oss-120b\",\"display_name\":\"GPT-OSS 120B\"}," + quota + "}")
            == CLIStatusLineHookTests.expectedLine("GPT-OSS 120B", 40, 60))
        #expect(try runAGY(input: "{\"model\":{\"id\":\"claude-sonnet-4\",\"display_name\":\"Claude Sonnet 4\"}," + quota + "}")
            == CLIStatusLineHookTests.expectedLine("Claude Sonnet 4", 40, 60))
    }

    @Test func agyChainsInputAndOutputVerbatim() throws {
        let input = #"{"quota":{"gemini-5h":{"remaining_fraction":0.8}}}"# + "\n\n"
        #expect(try runAGY(input: input, chained: "printf 'custom status\\n'; cat") == "custom status\n" + input)
    }

    @Test(arguments: StatusLineDisplayMode.allCases)
    func agyScriptDisplayChoices(displayMode: StatusLineDisplayMode) throws {
        let input = #"{"model":{"id":"gemini"},"quota":{"gemini-5h":{"remaining_fraction":0.7}}}"# + "\n\n"
        let mimir = try runAGY(input: input)
        for suffix in ["", "\n", "\n\n"] {
            let user = "custom status" + suffix
            let command = "cat > \"$HOME/chained-input\"; printf '%s' '\(user)'"
            let expected: String
            switch displayMode {
            case .showBoth: expected = user + (suffix.isEmpty ? "\n" : "") + mimir
            case .useMimir: expected = mimir
            case .keepCurrent: expected = user
            }
            #expect(try runAGY(input: input, chained: command, displayMode: displayMode,
                               expectChainedRun: displayMode != .useMimir) == expected)
        }
        #expect(try runAGY(input: input, displayMode: displayMode) == mimir)
    }

    @Test func agyLegacySidecarKeepsCurrentLine() throws {
        try withDirectory { directory in
            let original = #"{"statusLine":{"type":"command","command":"printf 'old status'","padding":2}}"#
            try write(original, "settings.json", in: directory)
            let hook = AntigravityStatusLineHook(directory: directory)
            hook.enable(displayMode: .showBoth)
            let legacy = #"{"version":1,"statusLine":{"type":"command","command":"printf 'old status'","padding":2}}"#
            try write(legacy, "mimir-prev-statusline.json", in: directory)
            let wired = try read("settings.json", in: directory)
            AntigravityStatusLineHook(directory: directory).refreshScript()
            #expect(try read("mimir-statusline.sh", in: directory)
                == AntigravityStatusLineHook.scriptBody(chained: "printf 'old status'", displayMode: .keepCurrent))
            #expect(try read("settings.json", in: directory) == wired)
            #expect(try read("mimir-prev-statusline.json", in: directory) == legacy)
            hook.disable()
            #expect(try settings(in: directory) as NSDictionary
                == JSONSerialization.jsonObject(with: Data(original.utf8)) as? NSDictionary)
        }
    }

    @Test func agyFreshCaptureUsesTheExistingFamiliesAndWindows() throws {
        try withDirectory { directory in
            let now = Date(timeIntervalSince1970: 2_000_000_000)
            let captured = now.addingTimeInterval(-60)
            let input = #"""
            {"model":{"id":"gemini"},"quota":{
              "gemini-weekly":{"remaining_fraction":0.9378,"reset_time":"2099-01-01T00:00:00Z","reset_in_seconds":1},
              "gemini-5h":{"remaining_fraction":"0.815","reset_in_seconds":600},
              "3p-weekly":{"remaining_fraction":0},
              "3p-5h":{"remaining_fraction":1},
              "argon-weekly":{"remaining_fraction":0.25}}}
            """#
            try write(input, "mimir-usage.json", in: directory)
            let path = directory.appendingPathComponent("mimir-usage.json").path
            try FileManager.default.setAttributes([.modificationDate: captured], ofItemAtPath: path)
            let status = try #require(LiveUsageDataSource().readAntigravityHookUsage(path: path, now: now))
            #expect(status.isAvailable)
            #expect(status.models.map(\.name) == ["Gemini", "Gemini", "Claude", "Claude", "Gemini 4 Argon"])
            #expect(status.models.map(\.window) == [.session, .weekly, .session, .weekly, .weekly])
            #expect(status.models.map(\.remainingPercent) == [82, 94, 100, 0, 25])
            #expect(status.models[0].resetAt == captured.addingTimeInterval(600))
            #expect(status.models[1].resetAt == ISO8601DateFormatter().date(from: "2099-01-01T00:00:00Z"))
            #expect(status.sessionResetAt == captured.addingTimeInterval(600))
        }
    }

    @Test(arguments: [(0.0, true), (1_800.0, true), (1_801.0, false), (-60.0, false)])
    func agyCaptureFreshness(age: TimeInterval, accepted: Bool) throws {
        try withDirectory { directory in
            let now = Date(timeIntervalSince1970: 2_000_000_000)
            try write(#"{"quota":{"gemini-weekly":{"remaining_fraction":0.5}}}"#, "mimir-usage.json", in: directory)
            let path = directory.appendingPathComponent("mimir-usage.json").path
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: path)
            #expect((LiveUsageDataSource().readAntigravityHookUsage(path: path, now: now) != nil) == accepted)
        }
    }

    @Test(arguments: [
        (#"{"quota":{"gemini-weekly":{"remaining_fraction":0.5}}}"#, [ModelWindow.weekly], [50]),
        (#"{"quota":{"gemini-5h":{"remaining_fraction":1.2}}}"#, [ModelWindow.session], [100]),
        (#"{"quota":{"gemini-5h":{"remaining_fraction":-0.1}}}"#, [ModelWindow.session], [0]),
        (#"{"quota":{"gemini-weekly":{"remaining_fraction":0.5},"gemini-5h":{"remaining_fraction":null}}}"#, [ModelWindow.weekly], [50]),
        (#"{"quota":{"gemini-5h":{"remaining_fraction":0.5,"disabled":true}}}"#, [], []),
        (#"{"quota":{"gemini-weekly":{"remaining_amount":100,"reset_in_seconds":100}}}"#, [], []),
        (#"{"quota":{"gemini-unknown":{"remaining_fraction":0.5,"reset_in_seconds":18000}}}"#, [], []),
        (#"{"quota":{"unknown-weekly":{"remaining_fraction":0.5}}}"#, [], []),
        (#"{"quota":{"gemini-weekly":{"remaining_fraction":true}}}"#, [], []),
        (#"{"quota":{"gemini-weekly":{"remaining_fraction":"NaN"}}}"#, [], []),
        (#"{"quota":{"gemini-weekly":{"remaining_fraction":0.5,"reset_time":"2000-01-01T00:00:00Z"}}}"#, [], []),
        (#"{"quota":{}}"#, [], []), (#"{"quota":null}"#, [], []), ("{}", [], []), ("broken", [], []),
    ])
    func agyCaptureOmitsMissingOrUnusableWindows(input: String, windows: [ModelWindow], percents: [Int]) throws {
        try withDirectory { directory in
            try write(input, "mimir-usage.json", in: directory)
            let status = LiveUsageDataSource().readAntigravityHookUsage(
                path: directory.appendingPathComponent("mimir-usage.json").path)
            #expect(status?.models.map(\.window) ?? [] == windows)
            #expect(status?.models.map(\.remainingPercent) ?? [] == percents)
            #expect((status == nil) == windows.isEmpty)
        }
    }

    @Test func agyMissingCaptureFallsThrough() throws {
        try withDirectory { directory in
            #expect(LiveUsageDataSource().readAntigravityHookUsage(
                path: directory.appendingPathComponent("mimir-usage.json").path) == nil)
        }
    }

    @Test(arguments: [false, true], StatusLineDisplayMode.allCases)
    func agyWireAndRestore(existing: Bool, displayMode: StatusLineDisplayMode) throws {
        try withDirectory { directory in
            let original = existing
                ? #"{"statusLine":{"type":"command","command":"printf 'old status'","enabled":true,"padding":2},"other":42}"#
                : #"{"other":42}"#
            try write(original, "settings.json", in: directory)
            let hook = AntigravityStatusLineHook(directory: directory)
            #expect(hook.hasExistingStatusLine == existing)
            hook.enable(displayMode: displayMode)
            #expect(!hook.hasExistingStatusLine)
            let sidecar = try #require(JSONSerialization.jsonObject(with: Data(read("mimir-prev-statusline.json", in: directory).utf8)) as? [String: Any])
            #expect(sidecar["displayMode"] as? String == displayMode.rawValue)
            let wired = try settings(in: directory)
            let status = try #require(wired["statusLine"] as? [String: Any])
            #expect(status["command"] as? String == hook.hookCommand)
            #expect(status["enabled"] as? Bool == true)
            #expect(wired["other"] as? Int == 42)
            #expect(try read("settings.json.mimir-backup", in: directory) == original)
            let script = try read("mimir-statusline.sh", in: directory)
            #expect(script == AntigravityStatusLineHook.scriptBody(chained: existing ? "printf 'old status'" : nil, displayMode: displayMode))
            let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("mimir-statusline.sh").path)
            #expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o755)
            let beforeRefresh = try read("settings.json", in: directory)
            try write("old script", "mimir-statusline.sh", in: directory)
            AntigravityStatusLineHook(directory: directory).refreshScript()
            hook.enable()
            #expect(try read("settings.json", in: directory) == beforeRefresh)
            #expect(try read("mimir-statusline.sh", in: directory) == script)
            try write("{}", "mimir-usage.json", in: directory)
            hook.disable()
            let restored = try settings(in: directory)
            let expected = try JSONSerialization.jsonObject(with: Data(original.utf8)) as! NSDictionary
            #expect(NSDictionary(dictionary: restored) == expected)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("mimir-prev-statusline.json").path))
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("mimir-statusline.sh").path))
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("mimir-usage.json").path))
            #expect(try read("settings.json.mimir-backup", in: directory) == original)
            hook.disable()
            hook.enable()
            #expect(try read("settings.json.mimir-backup", in: directory) == original)
        }
    }

    @Test func agyAbsentDirectoryAndAbsentSettings() throws {
        try withDirectory { directory in
            let missing = directory.appendingPathComponent("not-installed")
            AntigravityStatusLineHook(directory: missing).enable()
            #expect(!FileManager.default.fileExists(atPath: missing.path))
            let hook = AntigravityStatusLineHook(directory: directory)
            hook.refreshScript()
            let wired = try settings(in: directory)
            #expect((wired["statusLine"] as? [String: Any])?["enabled"] as? Bool == true)
            hook.disable()
            let restored = try settings(in: directory)
            #expect(restored.isEmpty)
        }
    }

    @Test(arguments: ["", "not json", "[]", "{broken"])
    func agyCorruptSettingsAreUntouched(original: String) throws {
        try withDirectory { directory in
            try write(original, "settings.json", in: directory)
            let hook = AntigravityStatusLineHook(directory: directory)
            hook.enable()
            hook.refreshScript()
            hook.disable()
            #expect(try read("settings.json", in: directory) == original)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["settings.json"])
        }
    }

    @Test func agyPreservesUserReplacementAndCorruptRestoreState() throws {
        try withDirectory { directory in
            let hook = AntigravityStatusLineHook(directory: directory)
            hook.enable()
            try write("{bad", "mimir-prev-statusline.json", in: directory)
            let wired = try read("settings.json", in: directory)
            hook.disable()
            #expect(try read("settings.json", in: directory) == wired)
            let replacement = #"{"statusLine":{"type":"command","command":"user-replacement"},"new":true}"#
            try write(replacement, "settings.json", in: directory)
            hook.refreshScript()
            hook.disable()
            #expect(try read("settings.json", in: directory) == replacement)
        }
    }

    @Test func agyNeverChainsDisabledCommandOrItself() throws {
        try withDirectory { directory in
            let hook = AntigravityStatusLineHook(directory: directory)
            let disabled = #"{"statusLine":{"type":"command","command":"printf old","enabled":false}}"#
            try write(disabled, "settings.json", in: directory)
            hook.enable()
            #expect(try read("mimir-statusline.sh", in: directory) == AntigravityStatusLineHook.scriptBody(chained: nil))
            hook.disable()
            #expect(try settings(in: directory)["statusLine"] as? NSDictionary
                == (try JSONSerialization.jsonObject(with: Data(disabled.utf8)) as? [String: Any])?["statusLine"] as? NSDictionary)
            // Our own script under another spelling, its sidecar lost: chaining it would recurse.
            let ownScript = "{\"statusLine\":{\"type\":\"command\",\"command\":\"bash \\\"\(directory.path)/mimir-statusline.sh\\\"\"}}"
            try write(ownScript, "settings.json", in: directory)
            hook.enable()
            #expect(try read("settings.json", in: directory) == ownScript)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("mimir-statusline.sh").path))
        }
    }

    @Test func agyKeepsSymlinkAndPermissions() throws {
        try withDirectory { directory in
            let target = directory.appendingPathComponent("dotfiles-settings.json")
            try #"{"other":1}"#.write(to: target, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("settings.json").path,
                                                       withDestinationPath: target.path)
            let hook = AntigravityStatusLineHook(directory: directory)
            hook.enable()
            let link = try FileManager.default.destinationOfSymbolicLink(atPath: directory.appendingPathComponent("settings.json").path)
            #expect(link == target.path)
            #expect(try read("settings.json.mimir-backup", in: directory) == #"{"other":1}"#)
            let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o600)
            hook.disable()
            #expect(try settings(in: directory)["other"] as? Int == 1)
        }
    }

    @Test func codexExtraAccountsKeepTheirOwnBackupAndUndoState() throws {
        try withDirectory { directory in
            let first = directory.appendingPathComponent(".codex-work")
            let second = directory.appendingPathComponent(".codex-other")
            for dir in [first, second] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try write("{}", "auth.json", in: dir)
            }
            let original = "# work\n[tui]\nstatus_line = ['model-name', 'five-hour-limit'] # keep\n"
            try write(original, "config.toml", in: first)
            let accounts = ExtraAccount.find(base: ".codex", title: "Codex", marker: "auth.json", home: directory)
            #expect(accounts.count == 2)
            CodexStatusLineHook.wireExtraDirs(true, accounts: accounts)
            #expect(try read("config.toml", in: first)
                == "# work\n[tui]\nstatus_line = ['model-name', 'five-hour-limit', \"weekly-limit\"] # keep\n")
            #expect(try read("config.toml.mimir-backup", in: first) == original)
            #expect(try read("config.toml", in: second)
                == "[tui]\nstatus_line = [\"model-with-reasoning\", \"current-dir\", \"thread-name\", \"five-hour-limit\", \"weekly-limit\"]\n")
            // A user edit survives both launch refresh and undo; a duplicate primary/extra dir is harmless.
            let changed = "[tui]\nstatus_line = ['git-branch', 'five-hour-limit']\n"
            try write(changed, "config.toml", in: first)
            CodexStatusLineHook.wireExtraDirs(true, accounts: accounts + accounts)
            #expect(try read("config.toml", in: first) == changed)
            CodexStatusLineHook.wireExtraDirs(false, accounts: accounts + accounts)
            #expect(try read("config.toml", in: first) == changed)
            #expect(try read("config.toml", in: second) == "[tui]\n")
            for dir in [first, second] {
                #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("mimir-statusline.json").path))
            }
            CodexStatusLineHook.wireExtraDirs(true, accounts: accounts)
            CodexStatusLineHook.wireExtraDirs(false, accounts: accounts)
            #expect(try read("config.toml.mimir-backup", in: first) == original)
        }
    }

    @Test func codexExtraAccountsSkipUnsafeAndMissingDirectories() throws {
        try withDirectory { directory in
            let original = "[tui]\nstatus_line = [\n 'model-name'\n]\n"
            try write(original, "config.toml", in: directory)
            let missing = directory.appendingPathComponent("missing")
            let accounts = [ExtraAccount(name: "Codex Work", dir: directory), ExtraAccount(name: "Codex Other", dir: missing)]
            CodexStatusLineHook.wireExtraDirs(true, accounts: accounts)
            CodexStatusLineHook.wireExtraDirs(false, accounts: accounts)
            #expect(try read("config.toml", in: directory) == original)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["config.toml"])
        }
    }

    @Test func codexDoesNotReaddItemsTheUserRemoved() throws {
        try withDirectory { directory in
            let hook = CodexStatusLineHook(directory: directory)
            try write("[tui]\nstatus_line = ['model-name']\n", "config.toml", in: directory)
            hook.enable()
            try write("[tui]\nstatus_line = ['model-name']\n", "config.toml", in: directory)
            hook.refreshScript()
            hook.enable()
            #expect(try read("config.toml", in: directory) == "[tui]\nstatus_line = ['model-name']\n")
            hook.disable()
            hook.enable() // a fresh toggle-on adopts again
            #expect(try read("config.toml", in: directory) == "[tui]\nstatus_line = ['model-name', \"five-hour-limit\", \"weekly-limit\"]\n")
        }
    }

    @Test func codexDisableNeverEmptiesTheStatusLine() throws {
        try withDirectory { directory in
            let hook = CodexStatusLineHook(directory: directory)
            hook.enable() // missing config.toml: the generated line
            let commented = try read("config.toml", in: directory).replacingOccurrences(of: "limit\"]\n", with: "limit\"] # mine\n")
            try write(commented, "config.toml", in: directory)
            hook.disable()
            #expect(try read("config.toml", in: directory)
                == "[tui]\nstatus_line = [\"model-with-reasoning\", \"current-dir\", \"thread-name\"] # mine\n")
        }
    }

    @Test func codexKeepsSymlinkAndPermissions() throws {
        try withDirectory { directory in
            let target = directory.appendingPathComponent("dotfiles-config.toml")
            try "[tui]\nstatus_line = []\n".write(to: target, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            let link = directory.appendingPathComponent("config.toml").path
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target.path)
            let hook = CodexStatusLineHook(directory: directory)
            hook.enable()
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == target.path)
            #expect(try read("config.toml.mimir-backup", in: directory) == "[tui]\nstatus_line = []\n")
            #expect(try read("config.toml", in: directory) == "[tui]\nstatus_line = [\"five-hour-limit\", \"weekly-limit\"]\n")
            let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o600)
            hook.disable()
            #expect(try read("config.toml", in: directory) == "[tui]\nstatus_line = []\n")
        }
    }

    @Test(arguments: [
        ("", "[tui]\nstatus_line = [\"model-with-reasoning\", \"current-dir\", \"thread-name\", \"five-hour-limit\", \"weekly-limit\"]\n"),
        ("model = 'gpt'", "model = 'gpt'\n[tui]\nstatus_line = [\"model-with-reasoning\", \"current-dir\", \"thread-name\", \"five-hour-limit\", \"weekly-limit\"]\n"),
        ("[tui]\n# keep\nnotifications = true\n[next]\nx = 1\n", "[tui]\nstatus_line = [\"model-with-reasoning\", \"current-dir\", \"thread-name\", \"five-hour-limit\", \"weekly-limit\"]\n# keep\nnotifications = true\n[next]\nx = 1\n"),
        ("[tui]", "[tui]\nstatus_line = [\"model-with-reasoning\", \"current-dir\", \"thread-name\", \"five-hour-limit\", \"weekly-limit\"]\n"),
        ("[tui]\r\nnotifications = true\r\n", "[tui]\r\nstatus_line = [\"model-with-reasoning\", \"current-dir\", \"thread-name\", \"five-hour-limit\", \"weekly-limit\"]\r\nnotifications = true\r\n"),
    ])
    func codexAbsentArray(original: String, expected: String) throws {
        let edit = try CodexStatusLineHook.enabling(original)
        #expect(edit.text == expected)
        #expect(edit.added == ["model-with-reasoning", "current-dir", "thread-name", "five-hour-limit", "weekly-limit"])
    }

    @Test func codexAppendsOnlyMissingAndPreservesOtherBytes() throws {
        let original = "# ö 🌙\r\nmodel = 'gpt'\r\n[tui] # ui\r\n  status_line\t= [ 'model-name', 'five-hour-limit', ]  # keep\r\n[tui.other]\r\nstatus_line = ['elsewhere']\r\n"
        let edit = try CodexStatusLineHook.enabling(original)
        #expect(edit.text == original.replacingOccurrences(of: "'five-hour-limit', ]", with: "'five-hour-limit', \"weekly-limit\", ]"))
        #expect(edit.added == ["weekly-limit"])
    }

    @Test func codexAlreadyCompleteIsByteIdentical() throws {
        let original = "[tui]\nstatus_line = [\"weekly-limit\", 'five-hour-limit', 'git-branch'] # done\n"
        let edit = try CodexStatusLineHook.enabling(original)
        #expect(edit.text == original)
        #expect(edit.added.isEmpty)
        try withDirectory { directory in
            try write(original, "config.toml", in: directory)
            let hook = CodexStatusLineHook(directory: directory)
            hook.enable()
            hook.disable()
            #expect(try read("config.toml", in: directory) == original)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["config.toml"])
        }
    }

    @Test(arguments: [
        "tui = { status_line = ['model-name'] }\n",
        "tui.status_line = ['model-name']\n",
        "'tui'.'status_line' = []\n",
        "[tui]\nstatus_line = [\n  'model-name'\n]\n",
        "[tui]\nstatus_line = 'model-name'\n",
        "[tui]\nstatus_line = []\nstatus_line = []\n",
        "[tui]\nstatus_line = []\n[tui]\n",
        "[tui.status_line]\nx = 1\n",
        "[[tui]]\nstatus_line = []\n",
        "[tui]\nstatus_line = [\"escaped\\tname\"]\n",
        "notes = '''\n[tui]\n'''\n",
        "notes = \"\"\"\n[tui]\n\"\"\"\n",
        "[tui]\nstatus_line = [1, 2]\n",
        "broken input\n",
        "values = [1, 2}\n[tui]\nstatus_line = []\n",
        "options = { x = 1 ]\n[tui]\nstatus_line = []\n",
        "[tui]\nstatus_line = [\"model-name\"\n",
    ])
    func codexUnsafeShapesSkipWithoutWriting(original: String) throws {
        #expect(throws: CodexStatusLineHook.EditError.self) { try CodexStatusLineHook.enabling(original) }
        try withDirectory { directory in
            try write(original, "config.toml", in: directory)
            let hook = CodexStatusLineHook(directory: directory)
            hook.enable()
            hook.refreshScript()
            hook.disable()
            #expect(try read("config.toml", in: directory) == original)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["config.toml"])
        }
    }

    @Test func codexIgnoresTableLookalikesInOtherArraysAndComments() throws {
        let original = "# [tui]\nvalues = [\n  '[tui]',\n  'status_line = []',\n]\n[other]\nstatus_line = []\n"
        #expect(try CodexStatusLineHook.enabling(original).text == original + "[tui]\nstatus_line = [\"model-with-reasoning\", \"current-dir\", \"thread-name\", \"five-hour-limit\", \"weekly-limit\"]\n")
        #expect(try CodexStatusLineHook.enabling("[\"tui\"]\n'status_line' = []\n").text
            == "[\"tui\"]\n'status_line' = [\"five-hour-limit\", \"weekly-limit\"]\n")
    }

    @Test func codexBackupRefreshAndDisableOnlyOurItems() throws {
        try withDirectory { directory in
            let original = "# keep\n[tui]\nstatus_line = ['five-hour-limit', 'model-name'] # mine\n[other]\nx = 1\n"
            try write(original, "config.toml", in: directory)
            let hook = CodexStatusLineHook(directory: directory)
            hook.enable()
            let wired = try read("config.toml", in: directory)
            #expect(try read("config.toml.mimir-backup", in: directory) == original)
            hook.refreshScript()
            #expect(try read("config.toml", in: directory) == wired)
            // A fresh value proves that ownership survives app relaunches, not just this instance.
            CodexStatusLineHook(directory: directory).disable()
            #expect(try read("config.toml", in: directory) == original)
            hook.enable()
            let userEdited = wired.replacingOccurrences(of: "'model-name'", with: "'model-name', 'git-branch'")
            try write(userEdited, "config.toml", in: directory)
            hook.disable()
            #expect(try read("config.toml", in: directory)
                == original.replacingOccurrences(of: "'model-name'", with: "'model-name', 'git-branch'"))
            #expect(try read("config.toml.mimir-backup", in: directory) == original)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("mimir-statusline.json").path))
        }
    }

    @Test func codexReenableDoesNotLoseInterveningUserItems() throws {
        try withDirectory { directory in
            let hook = CodexStatusLineHook(directory: directory)
            try write("[tui]\nstatus_line = ['model-name']\n", "config.toml", in: directory)
            hook.enable()
            try write("[tui]\nstatus_line = ['model-name', 'five-hour-limit', 'git-branch'] # new\n", "config.toml", in: directory)
            hook.refreshScript()
            hook.disable()
            #expect(try read("config.toml", in: directory) == "[tui]\nstatus_line = ['model-name', 'git-branch'] # new\n")
        }
    }

    @Test func codexDisableRemovesBothAdditionsFromChangedArray() throws {
        try withDirectory { directory in
            let hook = CodexStatusLineHook(directory: directory)
            hook.enable() // missing config.toml
            try write("[tui]\nstatus_line = ['five-hour-limit', 'git-branch', 'weekly-limit', ] # keep\n", "config.toml", in: directory)
            hook.disable()
            #expect(try read("config.toml", in: directory) == "[tui]\nstatus_line = ['git-branch', ] # keep\n")
        }
    }

    @Test func codexUnsafeDisablePreservesOwnershipForRetry() throws {
        try withDirectory { directory in
            let hook = CodexStatusLineHook(directory: directory)
            hook.enable()
            let installed = try read("config.toml", in: directory)
            let unsafe = "tui = { status_line = ['five-hour-limit', 'weekly-limit'] }\n"
            try write(unsafe, "config.toml", in: directory)
            hook.disable()
            #expect(try read("config.toml", in: directory) == unsafe)
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("mimir-statusline.json").path))
            try write(installed, "config.toml", in: directory)
            hook.disable()
            #expect(try read("config.toml", in: directory) == "[tui]\n")
        }
    }
}
