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

    /// Which providers are in use (available or showing stale data) — boolean only, never a value.
    static func providerParameters(from services: [ServiceStatus]) -> [String: String] {
        func active(_ name: String) -> String {
            (services.first { $0.name == name }.map { $0.isAvailable || $0.isStale } ?? false)
                ? "true" : "false"
        }
        return ["claude": active("Claude"), "codex": active("Codex"), "antigravity": active("Antigravity")]
    }

    /// Count of placed widgets per family (from WidgetCenter family raw names).
    static func widgetParameters(families: [String]) -> [String: String] {
        func count(_ raw: String) -> String { String(families.filter { $0 == raw }.count) }
        return ["small": count("systemSmall"), "medium": count("systemMedium"),
                "large": count("systemLarge"), "extraLarge": count("systemExtraLarge")]
    }
}
