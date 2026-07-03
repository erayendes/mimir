import Foundation
import MimirShared
import WidgetKit

/// Maps the app's live `[ServiceStatus]` into the compact `WidgetPayload`, writes it to the App
/// Group container, and nudges WidgetKit to reload. Called from the `store.$services` sink so the
/// widget tracks every refresh. Pure mapping (no AppKit) → unit-testable.
enum WidgetBridge {
    /// Dedup + throttle state for widget reloads. Both statics are only ever touched from the
    /// main-thread `store.$services` sink (single writer), so `nonisolated(unsafe)` is accurate and
    /// avoids forcing `update` onto @MainActor (which the Combine sink call site isn't). `lastProviders`
    /// skips no-op writes; `lastReload` rate-limits the reload poke.
    nonisolated(unsafe) private static var lastProviders: [ProviderPayload]?
    nonisolated(unsafe) private static var lastReload: Date?
    /// Minimum spacing between reload pokes for routine %-drift (structural changes bypass it).
    static let reloadThrottle: TimeInterval = 10 * 60

    static func update(_ services: [ServiceStatus]) {
        let now = Date()
        let payload = makePayload(services, generatedAt: now)
        // Always persist fresh data when it changes (cheap, no budget) so any later refresh reads
        // current numbers. The reload POKE is the scarce resource: WidgetKit budgets ~dozens/day, and
        // firing one on every 60s % tick burns it — after which even the widget's 15-min timeline
        // policy gets throttled and the widget sticks on a stale entry for long stretches (the bug
        // users hit). So poke now only on a structural change; rate-limit routine %-drift and let the
        // timeline policy carry the rest.
        guard payload.providers != lastProviders else { return }
        let previous = lastProviders
        lastProviders = payload.providers
        WidgetStore.write(payload)
        if shouldReload(previous: previous, next: payload.providers, lastReload: lastReload,
                        now: now, throttle: reloadThrottle) {
            lastReload = now
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Reload decision (pure, testable). A *structural* change — a provider appears/disappears or
    /// flips available↔unavailable (layout-changing, e.g. the data-unavailable empty state) — reloads
    /// immediately; a %-only change waits until `throttle` has elapsed since the last reload.
    static func shouldReload(previous: [ProviderPayload]?, next: [ProviderPayload],
                             lastReload: Date?, now: Date, throttle: TimeInterval) -> Bool {
        if structuralSignature(next) != structuralSignature(previous) { return true }
        return lastReload.map { now.timeIntervalSince($0) >= throttle } ?? true
    }

    private static func structuralSignature(_ providers: [ProviderPayload]?) -> [String] {
        (providers ?? []).map { "\($0.name)|\($0.isAvailable)|\($0.unavailable)" }
    }

    /// Built in `serviceDisplayOrder` so the widget rows match the popover and menu bar.
    static func makePayload(_ services: [ServiceStatus], generatedAt: Date) -> WidgetPayload {
        let providers = serviceDisplayOrder.compactMap { name -> ProviderPayload? in
            guard let svc = services.first(where: { $0.name == name }) else { return nil }
            return ProviderPayload(
                name: svc.name,
                iconName: svc.iconName,
                isAvailable: svc.isAvailable || svc.isStale,
                fiveHour: fiveHourMetrics(svc),
                unavailable: svc.dataUnavailable
            )
        }
        return WidgetPayload(generatedAt: generatedAt, providers: providers)
    }

    /// The prominent 5-hour windows, each paired with the weekly (7g) quota that gates it. Reuses the
    /// shared `ServiceStatus.sessionWindows` pairing (Antigravity per `.session` model matched to its
    /// weekly by name; Claude/Codex the account session) and drops windows with no 5h reading — the
    /// widget has no number to render for those (the menu bar keeps them as placeholder dots).
    private static func fiveHourMetrics(_ svc: ServiceStatus) -> [WindowMetric] {
        svc.sessionWindows.compactMap { w in
            w.sessionPercent.map { pct in
                WindowMetric(label: w.label, percent: pct, resetAt: w.sessionResetAt,
                             weeklyPercent: w.weeklyPercent, weeklyResetAt: w.weeklyResetAt)
            }
        }
    }
}
