import Foundation
import os

/// The same command/sidecar/one-time-backup wiring as the Claude hook. Paths are injectable so
/// tests never install into a real CLI home. The sidecar keeps the entire previous statusLine,
/// including enabled=false and any rendering options, for an exact semantic restore.
struct AntigravityStatusLineHook {
    var directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini/antigravity-cli")

    private static let log = Logger(subsystem: "com.erayendes.mimir", category: "agy-statusline")
    /// Symlinks (dotfile managers) are followed so an atomic write replaces the target, not the link.
    private var settingsURL: URL { directory.appendingPathComponent("settings.json").resolvingSymlinksInPath() }
    private var scriptURL: URL { directory.appendingPathComponent("mimir-statusline.sh") }
    private var previousURL: URL { directory.appendingPathComponent("mimir-prev-statusline.json") }
    private var backupURL: URL { directory.appendingPathComponent("settings.json.mimir-backup") }
    var hookCommand: String {
        "bash '" + scriptURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private enum Failure: Error { case invalidSettings, invalidSidecar, missingSidecar }

    /// Payload schema: https://antigravity.google/docs/cli/statusline/
    /// quota is a bucket-ID -> object map; remaining_fraction is already REMAINING, not used.
    /// The local agy binary also exposes map[string]types.StatusLineQuotaBucket and these JSON
    /// field tags. Bucket IDs are server supplied: gemini-weekly is documented; gemini-5h and
    /// 3p-{5h,weekly} also occur in the provider's quota fixtures. A 3p bucket alone does not prove
    /// a Claude-only family. When model-to-bucket matching is ambiguous, take the minimum per
    /// named window. Never infer window length from reset_in_seconds (time left, not duration).
    static func scriptBody(chained: String?) -> String {
        let render: String
        if let cmd = chained, !cmd.isEmpty {
            let escaped = cmd.replacingOccurrences(of: "'", with: "'\\''")
            render = "printf '%s' \"$input\" | bash -c '\(escaped)'"
        } else {
            render = #"""
            command -v jq >/dev/null 2>&1 && printf '%s' "$input" | jq -r '
              def family:
                ascii_downcase
                | if test("gemini") then "gemini"
                  elif test("claude|opus|sonnet|haiku") then "claude"
                  else null end;
              def window($pattern; $label):
                [.[] | select(.key | ascii_downcase | test($pattern))
                 | .value.remaining_fraction | select(. != null) | tonumber?]
                | select(length > 0) | min | (. * 100)
                | ([0, .] | max) | ([100, .] | min)
                | (. + 0.5 | floor | tostring) | $label + " " + . + "%";
              (((.model.id // "") | family) // ((.model.display_name // "") | family)) as $family
              | (.quota // {} | to_entries
                 | map(select((.value | type) == "object" and .value.disabled != true))) as $all
              | [$all[] | select($family != null and (.key | family) == $family)] as $matched
              | (if ($matched | length) > 0 then $matched else $all end)
              | [(window("(^|[-_])(5h|five[-_]hour)$"; "5h")),
                 (window("(^|[-_])(weekly|7d|seven[-_]day)$"; "7d"))]
              | select(length > 0) | "Mimir  " + join("  ·  ")
            ' 2>/dev/null
            """#
        }
        return """
        #!/bin/bash
        # Mimir — Antigravity statusline hook (auto-generated; do not edit).
        # Unknown model families use the lowest remaining quota per window.
        input=$(cat)
        \(render)
        """
    }

    private func readObject(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.invalidSettings
        }
        return object
    }

    private func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        return try readObject(settingsURL)
    }

    private func savedPrevious() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: previousURL.path) else {
            throw Failure.missingSidecar
        }
        let saved = try readObject(previousURL)
        guard saved["version"] as? Int == 1 else { throw Failure.invalidSidecar }
        return saved
    }

    private func command(in settings: [String: Any]) -> String? {
        (settings["statusLine"] as? [String: Any])?["command"] as? String
    }

    /// Same test as MimirStatusLineHook.isOurCommand: any command running a Mimir hook script is
    /// ours, even under another spelling of the path. Chaining it would make the script run itself.
    private func isOurs(_ command: String?) -> Bool {
        command?.contains("mimir-statusline.sh") ?? false
    }

    /// The previous command worth running: never our own script, never one the user had disabled.
    private func chained(_ previous: [String: Any]) -> String? {
        guard let status = previous["statusLine"] as? [String: Any],
              status["enabled"] as? Bool != false,
              let command = status["command"] as? String, !isOurs(command) else { return nil }
        return command
    }

    private func writeObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let mode = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        try data.write(to: url, options: .atomic)
        if let mode { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }
    }

    private func writeScript(previous: [String: Any]) throws {
        try Self.scriptBody(chained: chained(previous))
            .write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    func enable() {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return } // do not install agy for the user
        do {
            var settings = try readSettings()
            if isOurs(command(in: settings)) {
                try writeScript(previous: savedPrevious())
                return
            }
            // A previous install that the user has since replaced is theirs to keep. Do not lose
            // its restore record or re-enable it on launch behind their back.
            guard !FileManager.default.fileExists(atPath: previousURL.path) else { return }
            var previous: [String: Any] = ["version": 1]
            previous["statusLine"] = settings["statusLine"]
            if FileManager.default.fileExists(atPath: settingsURL.path),
               !FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.copyItem(at: settingsURL, to: backupURL)
            }
            try writeObject(previous, to: previousURL)
            do {
                try writeScript(previous: previous)
                settings["statusLine"] = ["type": "command", "command": hookCommand, "enabled": true]
                try writeObject(settings, to: settingsURL)
            } catch {
                try? FileManager.default.removeItem(at: previousURL)
                throw error
            }
        } catch {
            Self.log.error("Skipping Antigravity statusLine enable: \(error.localizedDescription)")
        }
    }

    /// Also installs for existing Claude-hook users on their first launch after the upgrade.
    /// enable() refreshes the script but leaves already-wired settings byte-identical.
    func refreshScript() { enable() }

    func disable() {
        guard FileManager.default.fileExists(atPath: previousURL.path) else { return }
        do {
            var settings = try readSettings()
            if isOurs(command(in: settings)) {
                let previous = try savedPrevious()
                settings["statusLine"] = previous["statusLine"]
                try writeObject(settings, to: settingsURL)
            }
            for url in [scriptURL, previousURL] {
                try? FileManager.default.removeItem(at: url)
            }
        } catch {
            Self.log.error("Skipping Antigravity statusLine disable: \(error.localizedDescription)")
        }
    }
}
