import Foundation

/// Anonymous, privacy-first usage telemetry (TelemetryDeck). Every send passes through
/// `shouldSend`; dev builds and opted-out users never send. Signals are categorical only —
/// no quota percentages, reset times, credits, account ids, tokens, or any PII.
enum Telemetry {
    /// TelemetryDeck app id — non-secret, embedded in the client (like the Sentry DSN). Empty or
    /// the placeholder → `start()` is a no-op, so the app builds and runs before one is provisioned.
    static let appID = "REPLACE_WITH_TELEMETRYDECK_APP_ID"

    static let enabledKey = "telemetry.enabled"

    /// Opt-out: an absent key counts as enabled (default on).
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static var isDevBuild: Bool {
        Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false
    }

    /// The single gate every transmission passes through. Pure → unit-tested.
    static func shouldSend(isDev: Bool, enabled: Bool) -> Bool { !isDev && enabled }
}
