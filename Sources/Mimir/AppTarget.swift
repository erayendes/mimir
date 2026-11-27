import AppKit

/// Maps a provider to the GUI app a user would open to refresh its data. Powers two things that
/// must agree: gating the "data unavailable — open it" state on the app being *installed* (so an
/// uninstalled provider's stale snapshot stops nagging), and launching that app on tap.
///
/// Providers with no openable app — Claude Code and Codex are CLIs / remote APIs, not apps you
/// "open" — map to `nil` and therefore never get the open-the-app empty state or a tap target.
enum AppTarget {
    private static let bundleIDs: [String: String] = [
        "Antigravity": "com.google.antigravity",
    ]

    static func bundleID(for provider: String) -> String? { bundleIDs[provider] }

    /// The installed app's URL, or `nil` when the provider has no mapping OR the app isn't installed.
    static func installedURL(for provider: String) -> URL? {
        guard let id = bundleID(for: provider) else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }

    /// Launch the provider's app. No-op if the provider is unmapped or the app isn't installed.
    static func open(_ provider: String) {
        guard let url = installedURL(for: provider) else { return }
        NSWorkspace.shared.open(url)
    }

    /// What a card whose login ran out runs in a terminal: Claude Code itself (it renews an expired
    /// token on start, and asks to log in when it can't), or `codex login`. A second login keeps its
    /// own config dir. nil for a provider with no CLI login.
    static func loginCommand(for service: String, dir: URL?) -> String? {
        let env = dir.map { "'\($0.path.replacingOccurrences(of: "'", with: "'\\''"))' " } ?? ""
        if service == "Claude" || service.hasPrefix("Claude ") {
            return (dir == nil ? "" : "CLAUDE_CONFIG_DIR=" + env) + "claude"
        }
        if service == "Codex" || service.hasPrefix("Codex ") {
            return (dir == nil ? "" : "CODEX_HOME=" + env) + "codex login"
        }
        return nil
    }

    /// Opens a terminal window that runs the login command. A `.command` file opens in Terminal (or
    /// whatever handles them) with no Apple Events, so macOS asks no permission to control it; the
    /// login, interactive shell (`-li`) brings the user's own PATH, where `claude` and `codex` live.
    static func openLogin(_ service: String) {
        let dir = (ExtraAccount.claude + ExtraAccount.codex).first { $0.name == service }?.dir
        guard let command = loginCommand(for: service, dir: dir) else { return }
        let url = LiveUsageDataSource.supportDirectory.appendingPathComponent("login.command")
        let script = "#!/bin/zsh -li\ncd ~\n\(command)\n"
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {}
    }
}
