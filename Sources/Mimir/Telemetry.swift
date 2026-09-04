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

    /// The providers in use (available, or showing stale data) — names only, never a value.
    ///
    /// One `provider.active` signal is sent per name rather than a single signal carrying a flag
    /// per provider, so `service` is one dimension the dashboard can slice into a share chart. A
    /// provider added later becomes another value of that dimension: neither this function nor any
    /// saved query has to change.
    static func activeProviderNames(from services: [ServiceStatus]) -> [String] {
        services.filter { $0.isAvailable || $0.isStale }.map(\.name)
    }

    /// Count of placed widgets for the one supported family (from WidgetCenter family raw names).
    static func widgetParameters(families: [String]) -> [String: String] {
        ["small": String(families.filter { $0 == "systemSmall" }.count)]
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
