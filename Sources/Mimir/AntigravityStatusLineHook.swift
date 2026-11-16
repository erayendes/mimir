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
    var usageURL: URL { directory.appendingPathComponent("mimir-usage.json") }
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
    /// 3p-{5h,weekly} and gemini-argon-wtu-weekly also occur in real payloads. 3p is shared by
    /// Claude and GPT models. When model-to-bucket matching is ambiguous, take the minimum per
    /// named window. Never infer window length from reset_in_seconds (time left, not duration).
    static func scriptBody(chained: String?) -> String {
        let render: String
        if let cmd = chained, !cmd.isEmpty {
            let escaped = cmd.replacingOccurrences(of: "'", with: "'\\''")
            render = "printf '%s' \"$input\" | bash -c '\(escaped)'"
        } else {
            render = #"""
            command -v jq >/dev/null 2>&1 && printf '%s' "$input" | jq -r '
              def color($percent):
                if $percent >= 40 then "32" elif $percent >= 10 then "33" else "31" end;
              def display($bars):
                .label + " " +
                (if $bars then
                  .filled as $filled
                  | (if $filled > 0 then "\u001b[" + color(.percent) + "m" + ("█" * $filled) + "\u001b[0m" else "" end)
                    + (if $filled < 10 then "\u001b[2m" + ("░" * (10 - $filled)) + "\u001b[0m" else "" end) + " "
                else "" end)
                + "\u001b[" + color(.percent) + "m" + (.percent | tostring) + "%\u001b[0m";
              def family:
                ascii_downcase
                | if test("argon") then "argon"
                  elif test("gemini") then "gemini"
                  elif test("3p|claude|opus|sonnet|haiku|gpt|oss") then "3p"
                  else null end;
              def window($pattern; $label):
                [.[] | select(.key | ascii_downcase | test($pattern))
                 | .value.remaining_fraction | select(. != null) | tonumber?]
                | select(length > 0) | min | (. * 100)
                | ([0, .] | max) | ([100, .] | min)
                | . as $remaining
                | {label: $label, percent: ($remaining + 0.5 | floor),
                   filled: ($remaining / 10 + 0.5 | floor)};
              .terminal_width as $terminal_width
              | ((.model.display_name // .model.id // "") | sub(" \\([^()]*\\)$"; "")) as $model
              | ([(.model.id // ""), (.model.display_name // "")] | join(" ") | family) as $family
              | (.quota // {} | to_entries
                 | map(select((.value | type) == "object" and .value.disabled != true))) as $all
              | [$all[] | select($family != null and (.key | family) == $family)] as $matched
              | (if ($matched | length) > 0 then $matched else $all end)
              | [(window("(^|[-_])(5h|five[-_]hour)$"; "5h")),
                 (window("(^|[-_])(weekly|7d|seven[-_]day)$"; "7d"))] as $windows
              | select($windows | length > 0)
              | ("Mimir  " + (if $model != "" then $model + "  " else "" end)) as $prefix
              | ($prefix + ([$windows[] | .label + " " + (.percent | tostring) + "%"] | join("  ·  ")) | length
                 + 11 * ($windows | length)) as $full_width
              | ($terminal_width == null or ($terminal_width | tonumber? // 0) >= $full_width) as $bars
              | $prefix + ([$windows[] | display($bars)] | join("  ·  "))
            ' 2>/dev/null
            """#
        }
        return """
        #!/bin/bash
        # Mimir — Antigravity statusline hook (auto-generated; do not edit).
        # Unknown model families use the lowest remaining quota per window.
        # Preserve trailing newlines too; command substitution alone would strip them.
        input=$(cat; printf '.')
        input=${input%.}
        # Save beside this script, including when installed into an injected directory.
        # Private and atomic: the payload can include account/session metadata.
        (
            umask 077
            usage_dir=$(dirname -- "${BASH_SOURCE[0]}")
            capture=$(mktemp "$usage_dir/.mimir-usage.XXXXXX") || exit 1
            trap 'rm -f "$capture"' EXIT
            printf '%s' "$input" > "$capture" && mv -f "$capture" "$usage_dir/mimir-usage.json"
        ) 2>/dev/null
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
            for url in [scriptURL, previousURL, usageURL] {
                try? FileManager.default.removeItem(at: url)
            }
        } catch {
            Self.log.error("Skipping Antigravity statusLine disable: \(error.localizedDescription)")
        }
    }
}
