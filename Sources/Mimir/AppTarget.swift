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
}
