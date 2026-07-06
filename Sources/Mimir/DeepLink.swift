/// Routing for the `mimir://open?app=<provider>` deep link the widget taps into. Kept pure (no
/// AppKit) so the decision is unit-testable without a running app.
enum DeepLinkAction: Equatable {
    /// Provider has an openable GUI app (Antigravity) → launch it; it writes its own credentials
    /// file which Mimir then reads prompt-free in the background.
    case openProvider(String)
    /// Provider is a CLI/API with nothing to open (Claude, Codex) → bring Mimir up and do a
    /// user-initiated refresh. That's the only way to pull a fresh token: a background read of
    /// Claude Code's keychain item would pop the macOS prompt, so it's gated to a user action.
    case openSelfAndRefresh
}

enum DeepLink {
    static func action(forApp app: String) -> DeepLinkAction {
        AppTarget.bundleID(for: app) != nil ? .openProvider(app) : .openSelfAndRefresh
    }
}
