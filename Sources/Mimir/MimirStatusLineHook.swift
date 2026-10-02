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
    /// Claude Code's config directory. `CLAUDE_CONFIG_DIR` is Anthropic's own override and points
    /// every Claude path — credentials, settings, our hook's output — somewhere other than
    /// `~/.claude`. Launched from Finder the app inherits no shell environment, so a variable the
    /// user exported in their profile is invisible here; `launchctl getenv` is the one place a
    /// GUI-launched process can still see it. Resolved once: the variable doesn't change under a
    /// running app, and `launchctl` is a subprocess we'd rather not spawn on every path lookup.
    /// Memoised by hand rather than as a `static let`: that form resolves under `dispatch_once`,
    /// and this resolution spawns `launchctl`. Called the first time from a SwiftUI body, the once
    /// token deadlocked and trapped the app on launch. A plain cache has no such rule — the value
    /// is computed at most twice in the worst case and never blocks anyone.
    nonisolated(unsafe) private static var cachedClaudeDir: String?

    static var claudeDir: String {
        if let cachedClaudeDir { return cachedClaudeDir }
        let resolved: String
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !env.isEmpty {
            resolved = env
        } else if let launchd = launchctlEnv("CLAUDE_CONFIG_DIR"), !launchd.isEmpty {
            resolved = launchd
        } else {
            resolved = (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        }
        cachedClaudeDir = resolved
        return resolved
    }

    static func claudePath(_ component: String) -> String {
        (claudeDir as NSString).appendingPathComponent(component)
    }

    /// One `launchctl getenv KEY`. Any failure — missing binary, non-zero exit, empty value — reads
    /// as "not set" and the caller falls back, so this can never be the reason a path stops resolving.
    private static func launchctlEnv(_ key: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["getenv", key]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
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
        printf '%s' "$input" > "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/mimir-usage.json"
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

    private static func writeSettings(_ settings: [String: Any], to path: String = settingsPath) -> Bool {
        guard let data = try? JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else { return false }
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
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
        wireExtraDirs(true)
    }

    /// Second logins (`ExtraAccount.claude`, e.g. `~/.claude-work`) point at the same script, which
    /// writes into whichever config dir Claude Code runs with. ponytail: a dir that already has a
    /// status line of its own is left alone — chaining it would need a sidecar per dir.
    static func wireExtraDirs(_ on: Bool, accounts: [ExtraAccount] = ExtraAccount.claude) {
        for account in accounts {
            let path = account.dir.appendingPathComponent("settings.json").path
            let markerPath = account.dir.appendingPathComponent("mimir-wired").path
            let backupPath = account.dir.appendingPathComponent("settings.json.mimir-backup").path
            let data = FileManager.default.contents(atPath: path)
            let current = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if data?.isEmpty == false, current == nil { continue }   // unparseable: never clobber it
            let cmd = (current?["statusLine"] as? [String: Any])?["command"] as? String
            if on {
                guard !FileManager.default.fileExists(atPath: markerPath) else { continue }
                if isOurCommand(cmd) {   // wired before the marker existed
                    FileManager.default.createFile(atPath: markerPath, contents: nil)
                    continue
                }
                guard cmd == nil else { continue }   // the user's own
                if FileManager.default.fileExists(atPath: path),
                   !FileManager.default.fileExists(atPath: backupPath) {
                    try? FileManager.default.copyItem(atPath: path, toPath: backupPath)
                }
                if writeSettings(wiredSettings(from: current).settings, to: path) {
                    FileManager.default.createFile(atPath: markerPath, contents: nil)
                }
            } else {
                try? FileManager.default.removeItem(atPath: markerPath)
                guard isOurCommand(cmd) else { continue }
                _ = writeSettings(unwiredSettings(from: current, chained: nil), to: path)
                try? FileManager.default.removeItem(at: account.dir.appendingPathComponent("mimir-usage.json"))
            }
        }
    }

    /// Wire the hook: chain any existing statusLine, back up settings.json (once), write the script,
    /// point settings at it. Idempotent. Aborts without touching anything if settings.json is present
    /// but unparseable.
    @discardableResult static func enable() -> Outcome {
        if settingsIsCorrupt() { return .failed(String(localized: "~/.claude/settings.json is not valid JSON")) }
        let current = readSettings()
        if isOurCommand((current?["statusLine"] as? [String: Any])?["command"] as? String) {
            _ = writeScript(chained: savedChain())   // still refresh the script body
            wireExtraDirs(true)
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
        wireExtraDirs(true)
        return chained == nil ? .enabled : .chained
    }

    /// Unwire: restore the chained statusLine (or remove ours), delete the script, sidecar, and stale
    /// usage file. Leaves a non-Mimir statusLine untouched.
    @discardableResult static func disable() -> Outcome {
        if settingsIsCorrupt() { return .failed(String(localized: "~/.claude/settings.json is not valid JSON")) }
        let settings = unwiredSettings(from: readSettings(), chained: savedChain())
        guard writeSettings(settings) else { return .failed(String(localized: "couldn't write to ~/.claude")) }
        wireExtraDirs(false)
        for path in [scriptPath, prevPath, usagePath] {
            try? FileManager.default.removeItem(atPath: path)
        }
        return .disabled
    }
}
