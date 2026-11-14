import Foundation
import Testing
@testable import Mimir

/// All disk operations and subprocess HOME/config overrides are isolated. These tests never call
/// the production lifecycle entry points, which resolve the user's actual CLI directories.
struct CLIStatusLineHookTests {
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

    private func runAGY(input: String, chained: String? = nil) throws -> String {
        var result = ""
        try withDirectory { directory in
            try write(input, "input.json", in: directory)
            let inputHandle = try FileHandle(forReadingFrom: directory.appendingPathComponent("input.json"))
            defer { try? inputHandle.close() }
            let output = Pipe()
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = ["-c", AntigravityStatusLineHook.scriptBody(chained: chained)]
            var environment = ProcessInfo.processInfo.environment
            for key in ["HOME", "CLAUDE_CONFIG_DIR", "CODEX_HOME"] { environment[key] = directory.path }
            task.environment = environment
            task.standardInput = inputHandle
            task.standardOutput = output
            try task.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            #expect(task.terminationStatus == 0, "Rendering requires jq on PATH")
            result = String(decoding: data, as: UTF8.self)
        }
        return result
    }

    @Test(arguments: [
        (0.0, 0), (1.0, 100), (0.815, 82), (0.304, 30), (0.305, 31),
        (0.306, 31), (0.005, 1), (0.004, 0), (-0.1, 0), (1.5, 100),
    ])
    func agyRemainingPercent(fraction: Double, expected: Int) throws {
        let input = """
        {"model":{"id":"gemini-4-argon"},"quota":{
          "gemini-5h":{"remaining_fraction":\(fraction),"reset_in_seconds":100},
          "gemini-weekly":{"remaining_fraction":0.9378,"reset_in_seconds":50},
          "3p-5h":{"remaining_fraction":0.01},"3p-weekly":{"remaining_fraction":0.02}}}
        """
        #expect(try runAGY(input: input) == "Mimir  5h \(expected)%  ·  7d 94%\n")
    }

    @Test(arguments: [
        (#"{"quota":{"gemini-5h":{"remaining_fraction":0.8}}}"#, "Mimir  5h 80%\n"),
        (#"{"quota":{"gemini-weekly":{"remaining_fraction":0.9378}}}"#, "Mimir  7d 94%\n"),
        (#"{"quota":{"gemini-5h":{"remaining_fraction":null},"gemini-weekly":{"remaining_fraction":"0.5"}}}"#, "Mimir  7d 50%\n"),
        (#"{"quota":{"gemini-5h":{"remaining_fraction":"unknown"},"gemini-weekly":{"remaining_fraction":0.5}}}"#, "Mimir  7d 50%\n"),
        (#"{"quota":{"gemini-5h":{"remaining_fraction":0.9,"disabled":true}}}"#, ""),
        (#"{"quota":{"gemini-weekly":{"remaining_amount":100}}}"#, ""),
        (#"{"quota":null}"#, ""),
        (#"{"model":null}"#, ""),
        (#"{"quota":{}}"#, ""),
    ])
    func agyOmitsMissingWindows(input: String, expected: String) throws {
        #expect(try runAGY(input: input) == expected)
    }

    @Test func agySelectsFamilyAndUsesMinimumWhenAmbiguous() throws {
        let quota = #"""
        "quota":{"gemini-5h":{"remaining_fraction":0.8},"gemini-weekly":{"remaining_fraction":0.1},
        "claude-5h":{"remaining_fraction":0.3},"claude-weekly":{"remaining_fraction":0.7}}
        """#
        #expect(try runAGY(input: "{\"model\":{\"display_name\":\"Claude Opus\"}," + quota + "}")
            == "Mimir  5h 30%  ·  7d 70%\n")
        #expect(try runAGY(input: "{\"model\":{\"id\":\"opaque-id\",\"display_name\":\"Claude Opus\"}," + quota + "}")
            == "Mimir  5h 30%  ·  7d 70%\n")
        #expect(try runAGY(input: "{\"model\":{\"id\":\"custom\"}," + quota + "}")
            == "Mimir  5h 30%  ·  7d 10%\n")
        // A known family's missing window must not borrow a different family's number.
        #expect(try runAGY(input: #"{"model":{"id":"Gemini"},"quota":{"gemini-weekly":{"remaining_fraction":0.5},"3p-5h":{"remaining_fraction":0.2}}}"#)
            == "Mimir  7d 50%\n")
        // 3p is not sufficient evidence of a Claude-only bucket: conservative per-window min.
        #expect(try runAGY(input: #"{"model":{"id":"Claude"},"quota":{"gemini-weekly":{"remaining_fraction":0.5},"3p-weekly":{"remaining_fraction":0.2}}}"#)
            == "Mimir  7d 20%\n")
    }

    @Test func agyChainsInputAndOutputVerbatim() throws {
        let input = #"{"quota":{"gemini-5h":{"remaining_fraction":0.8}}}"#
        #expect(try runAGY(input: input, chained: "printf 'custom status\\n'; cat") == "custom status\n" + input)
    }

    @Test(arguments: [false, true])
    func agyWireAndRestore(existing: Bool) throws {
        try withDirectory { directory in
            let original = existing
                ? #"{"statusLine":{"type":"command","command":"printf 'old status'","enabled":true,"padding":2},"other":42}"#
                : #"{"other":42}"#
            try write(original, "settings.json", in: directory)
            let hook = AntigravityStatusLineHook(directory: directory)
            hook.enable()
            let wired = try settings(in: directory)
            let status = try #require(wired["statusLine"] as? [String: Any])
            #expect(status["command"] as? String == hook.hookCommand)
            #expect(status["enabled"] as? Bool == true)
            #expect(wired["other"] as? Int == 42)
            #expect(try read("settings.json.mimir-backup", in: directory) == original)
            let script = try read("mimir-statusline.sh", in: directory)
            #expect(script == AntigravityStatusLineHook.scriptBody(chained: existing ? "printf 'old status'" : nil))
            let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("mimir-statusline.sh").path)
            #expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o755)
            let beforeRefresh = try read("settings.json", in: directory)
            try write("old script", "mimir-statusline.sh", in: directory)
            hook.refreshScript()
            hook.enable()
            #expect(try read("settings.json", in: directory) == beforeRefresh)
            #expect(try read("mimir-statusline.sh", in: directory) == script)
            hook.disable()
            let restored = try settings(in: directory)
            let expected = try JSONSerialization.jsonObject(with: Data(original.utf8)) as! NSDictionary
            #expect(NSDictionary(dictionary: restored) == expected)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("mimir-prev-statusline.json").path))
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("mimir-statusline.sh").path))
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
