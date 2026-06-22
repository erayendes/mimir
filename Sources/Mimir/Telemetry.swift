import Foundation
import TelemetryDeck

/// Anonymous, privacy-first usage telemetry (TelemetryDeck). Every send passes through
/// `shouldSend`; dev builds and opted-out users never send. Signals are categorical only —
/// no quota percentages, reset times, credits, account ids, tokens, or any PII.
enum Telemetry {
    /// TelemetryDeck app id — non-secret, embedded in the client (like the Sentry DSN). Empty →
    /// `start()` is a no-op. Namespace scopes signals to our org on the ingestion side.
    static let appID = "451C5BEF-443E-42ED-960A-513679A23DAE"
    static let namespace = "com.milowda"

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

    // Touched only from the main thread (launch, the services sink, menu actions). The worst a
    // race could do is a benign double-initialise, so unsafe is fine here.
    private nonisolated(unsafe) static var started = false

    /// Initialise the SDK once — only for non-dev builds, with a real app id, and opt-in.
    static func start() {
        guard shouldSend(isDev: isDevBuild, enabled: enabled),
              !appID.isEmpty, !started else { return }
        started = true
        TelemetryDeck.initialize(config: .init(appID: appID, namespace: namespace))
    }

    /// Send a categorical signal. No-op unless the SDK started and the gate allows it.
    static func signal(_ name: String, parameters: [String: String] = [:]) {
        guard started, shouldSend(isDev: isDevBuild, enabled: enabled) else { return }
        TelemetryDeck.signal(name, parameters: parameters)
    }

    /// Flip the opt-out flag; start the SDK if newly enabled (future sends are suppressed when off).
    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
        if on { start() }
    }
}
