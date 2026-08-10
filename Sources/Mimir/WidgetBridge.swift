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
    /// One-shot: a widget tap asks the next payload update to reload immediately (see below).
    nonisolated(unsafe) private static var pendingForceReload = false
    /// Minimum spacing between reload pokes for routine %-drift (structural changes bypass it). Kept
    /// short enough (aligned to the 60s refresh) that the widget tracks the popover instead of
    /// trailing it by 10+ minutes, but still coalesced so WidgetKit's daily reload budget isn't burnt
    /// by pokes on unchanged data (we only poke when `providers` actually changed).
    static let reloadThrottle: TimeInterval = 75

    /// A tapped widget must visibly refresh right away, even if the numbers didn't change (e.g. the
    /// user-initiated refresh it kicked off failed) — so the deep-link handler sets this and the next
    /// `update` reloads immediately, bypassing the %-drift throttle.
    static func forceReloadOnNextUpdate() { pendingForceReload = true }

    static func update(_ services: [ServiceStatus]) {
        let now = Date()
        let payload = makePayload(services, generatedAt: now)
        let forced = pendingForceReload
        pendingForceReload = false

        // Persist fresh data whenever it changes (cheap, no budget) so any later refresh reads current
        // numbers. The reload POKE is the scarce resource: WidgetKit budgets ~dozens/day. A no-op tick
        // with unchanged data and no pending tap short-circuits so we never spend budget for nothing.
        let changed = payload.providers != lastProviders
        guard changed || forced else { return }
        let previous = lastProviders
        if changed {
            lastProviders = payload.providers
            WidgetStore.write(payload)
        }
        // Reload on a structural change or once the throttle window elapses (routine %-drift), or
        // immediately when a widget tap forced it.
        if forced || shouldReload(previous: previous, next: payload.providers, lastReload: lastReload,
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
        (providers ?? []).map { "\($0.name)|\($0.isAvailable)|\($0.unavailable)|\($0.isStale)" }
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
                unavailable: svc.dataUnavailable,
                isStale: svc.isStale
            )
        }
        return WidgetPayload(generatedAt: generatedAt, providers: providers)
    }

    /// The prominent window per session, each paired with the weekly (7g) quota that gates it. Reuses
    /// the shared `ServiceStatus.sessionWindows` pairing (Antigravity per `.session` model matched to its
    /// weekly by name; Claude/Codex the account session). Prefers the 5-hour reading; when a service has
    /// no active 5h window (Codex since OpenAI's July 2026 removal) it falls back to the weekly reading
    /// tagged `isWeekly` so the widget shows the real binding limit with a "7g" pill instead of dropping
    /// the row. Only windows with neither reading are dropped.
    private static func fiveHourMetrics(_ svc: ServiceStatus) -> [WindowMetric] {
        svc.sessionWindows.compactMap { w in
            if let pct = w.sessionPercent {
                return WindowMetric(label: w.label, percent: pct, resetAt: w.sessionResetAt,
                                    weeklyPercent: w.weeklyPercent, weeklyResetAt: w.weeklyResetAt,
                                    isWeekly: false)
            }
            if let weeklyPct = w.weeklyPercent {
                return WindowMetric(label: w.label, percent: weeklyPct, resetAt: w.weeklyResetAt,
                                    weeklyPercent: w.weeklyPercent, weeklyResetAt: w.weeklyResetAt,
                                    isWeekly: true, windowSeconds: w.weeklyWindowSeconds)
            }
            return nil
        }
    }
}
