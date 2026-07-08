import Foundation

/// Prompt-free Claude sourcing: instead of reading Claude Code's keychain item (which pops the macOS
/// permission prompt), Mimir installs a tiny statusLine hook into `~/.claude/settings.json`. Claude
/// Code hands its own session JSON — including the official 5h/7d rate-limit numbers it already
/// fetched server-side — to the hook on stdin every render; the hook saves it to
/// `~/.claude/mimir-usage.json`, which `LiveUsageDataSource.readClaudeHookUsage` reads. No keychain,
/// no token, no network, no prompt.
///
/// The wiring mirrors the prompt-free-first, don't-break-the-user's-setup posture: any existing
/// statusLine command is chained through (its output is preserved), remembered in a sidecar so
/// disable/upgrade can reconstruct or restore it, and `settings.json` is backed up before the first
/// write and never clobbered when it doesn't parse.
enum MimirStatusLineHook {
    static func claudePath(_ component: String) -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/\(component)")
    }
    static var scriptPath: String { claudePath("mimir-statusline.sh") }
    static var usagePath: String { claudePath("mimir-usage.json") }
    static var settingsPath: String { claudePath("settings.json") }
    static var prevPath: String { claudePath("mimir-prev-statusline") }
    static var backupPath: String { claudePath("settings.json.mimir-backup") }

    /// The statusLine command that points Claude Code at our hook.
    static var hookCommand: String { "bash \"\(scriptPath)\"" }

    enum Outcome: Equatable {
        case enabled        // wired from scratch
        case chained        // wired, preserving an existing status line
        case alreadyOn      // already pointed at our hook — no change
        case disabled       // unwired, previous status line restored (or removed)
        case failed(String)
    }

    // MARK: - Pure core (unit-testable without disk)

    /// True when a statusLine command already points at our hook.
    static func isOurCommand(_ cmd: String?) -> Bool {
        cmd?.contains("mimir-statusline.sh") ?? false
    }

    /// Compute the settings after wiring our hook, plus the command to chain through (the user's
    /// previous statusLine command, if any and not already ours). Pure.
    static func wiredSettings(from current: [String: Any]?)
        -> (settings: [String: Any], chained: String?) {
        var settings = current ?? [:]
        let prevCmd = (settings["statusLine"] as? [String: Any])?["command"] as? String
        let chained = isOurCommand(prevCmd) ? nil : prevCmd
        settings["statusLine"] = ["type": "command", "command": hookCommand]
        return (settings, chained)
    }

    /// Compute the settings after unwiring: restore the chained command if there was one, else drop
    /// the statusLine key. Only touches statusLine when it's currently ours. Pure.
    static func unwiredSettings(from current: [String: Any]?, chained: String?) -> [String: Any] {
        var settings = current ?? [:]
        let cmd = (settings["statusLine"] as? [String: Any])?["command"] as? String
        guard isOurCommand(cmd) else { return settings }   // not ours → leave alone
        if let chained, !chained.isEmpty {
            settings["statusLine"] = ["type": "command", "command": chained]
        } else {
            settings.removeValue(forKey: "statusLine")
        }
        return settings
    }

    /// The hook script. Saves Claude Code's raw stdin JSON for Mimir (no jq needed for the save —
    /// just `cat` + redirect), then renders a status line: the chained command's output when we're
    /// preserving one, otherwise a compact Mimir 5h/7d line when `jq` is available (else nothing).
    /// No backslashes leak into the script — jq builds its string with `+`, not Swift interpolation.
    static func scriptBody(chained: String?) -> String {
        let render: String
        if let cmd = chained, !cmd.isEmpty {
            let escaped = cmd.replacingOccurrences(of: "'", with: "'\\''")
            render = "printf '%s' \"$input\" | bash -c '\(escaped)'"
        } else {
            render = "command -v jq >/dev/null 2>&1 && printf '%s' \"$input\" | jq -r '\"Mimir  5h \" + ((.rate_limits.five_hour.used_percentage // 0) | floor | tostring) + \"%  ·  7d \" + ((.rate_limits.seven_day.used_percentage // 0) | floor | tostring) + \"%\"' 2>/dev/null"
        }
        return """
        #!/bin/bash
        # Mimir — Claude Code statusline hook (auto-generated; do not edit).
        # Saves Claude Code's status data so the Mimir menu bar app can read your usage locally —
        # no API, no token, no keychain prompt. Toggle it from Mimir's menu.
        input=$(cat)
        printf '%s' "$input" > "$HOME/.claude/mimir-usage.json"
        \(render)
        """
    }

    // MARK: - Disk I/O

    static func isWired() -> Bool {
        isOurCommand((readSettings()?["statusLine"] as? [String: Any])?["command"] as? String)
    }

    private static func readSettings() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root
    }

    /// True only when settings.json exists but does NOT parse as a JSON object — the one case where
    /// we must abort rather than risk clobbering the user's file.
    private static func settingsIsCorrupt() -> Bool {
        guard let data = FileManager.default.contents(atPath: settingsPath), !data.isEmpty else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] == nil
    }

    private static func writeSettings(_ settings: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else { return false }
        do {
            try FileManager.default.createDirectory(atPath: claudePath(""), withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
            return true
        } catch { return false }
    }

    private static func writeScript(chained: String?) -> Bool {
        do {
            try FileManager.default.createDirectory(atPath: claudePath(""), withIntermediateDirectories: true)
            try scriptBody(chained: chained).write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            return true
        } catch { return false }
    }

    private static func savedChain() -> String? {
        let s = (try? String(contentsOfFile: prevPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    }

    /// Rewrite the script in place from current code, preserving any chained command — cheap, touches
    /// no settings. Call on launch when wired so app upgrades take effect.
    static func refreshScript() {
        guard isWired() else { return }
        _ = writeScript(chained: savedChain())
    }

    /// Wire the hook: chain any existing statusLine, back up settings.json (once), write the script,
    /// point settings at it. Idempotent. Aborts without touching anything if settings.json is present
    /// but unparseable.
    @discardableResult static func enable() -> Outcome {
        if settingsIsCorrupt() { return .failed(String(localized: "~/.claude/settings.json is not valid JSON")) }
        let current = readSettings()
        if isOurCommand((current?["statusLine"] as? [String: Any])?["command"] as? String) {
            _ = writeScript(chained: savedChain())   // still refresh the script body
            return .alreadyOn
        }
        let (settings, chained) = wiredSettings(from: current)
        // Remember the chain so disable/upgrade can restore or preserve it.
        try? (chained ?? "").write(toFile: prevPath, atomically: true, encoding: .utf8)
        // Back up the user's settings once, before our first write.
        if FileManager.default.fileExists(atPath: settingsPath),
           !FileManager.default.fileExists(atPath: backupPath) {
            try? FileManager.default.copyItem(atPath: settingsPath, toPath: backupPath)
        }
        guard writeScript(chained: chained), writeSettings(settings) else {
            return .failed(String(localized: "couldn't write to ~/.claude"))
        }
        return chained == nil ? .enabled : .chained
    }

    /// Unwire: restore the chained statusLine (or remove ours), delete the script, sidecar, and stale
    /// usage file. Leaves a non-Mimir statusLine untouched.
    @discardableResult static func disable() -> Outcome {
        if settingsIsCorrupt() { return .failed(String(localized: "~/.claude/settings.json is not valid JSON")) }
        let settings = unwiredSettings(from: readSettings(), chained: savedChain())
        guard writeSettings(settings) else { return .failed(String(localized: "couldn't write to ~/.claude")) }
        for path in [scriptPath, prevPath, usagePath] {
            try? FileManager.default.removeItem(atPath: path)
        }
        return .disabled
    }
}
