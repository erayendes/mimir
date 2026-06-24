import Foundation
import MimirShared
import WidgetKit

/// Maps the app's live `[ServiceStatus]` into the compact `WidgetPayload`, writes it to the App
/// Group container, and nudges WidgetKit to reload. Called from the `store.$services` sink so the
/// widget tracks every refresh. Pure mapping (no AppKit) → unit-testable.
enum WidgetBridge {
    /// Last providers we wrote, to skip no-op refreshes. ponytail: only ever touched from the
    /// main-thread `store.$services` sink (single writer), so `nonisolated(unsafe)` is accurate
    /// and avoids forcing `update` onto @MainActor (which the Combine sink call site isn't).
    nonisolated(unsafe) private static var lastProviders: [ProviderPayload]?

    static func update(_ services: [ServiceStatus]) {
        let payload = makePayload(services, generatedAt: Date())
        // Only write + reload when the data actually changed. WidgetKit budgets timeline reloads;
        // firing one on every 60s refresh (even when nothing moved) burns that budget and leaves
        // the widget showing stale data. The provider data — not the generatedAt stamp — is what
        // matters; the widget's own ~15-min timeline policy keeps the countdown text live.
        guard payload.providers != lastProviders else { return }
        lastProviders = payload.providers
        WidgetStore.write(payload)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Built in `serviceDisplayOrder` so the widget rows match the popover and menu bar.
    static func makePayload(_ services: [ServiceStatus], generatedAt: Date) -> WidgetPayload {
        let providers = serviceDisplayOrder.compactMap { name -> ProviderPayload? in
            guard let svc = services.first(where: { $0.name == name }) else { return nil }
            return ProviderPayload(
                name: svc.name,
                iconName: svc.iconName,
                isAvailable: svc.isAvailable || svc.isStale,
                fiveHour: fiveHourMetrics(svc)
            )
        }
        return WidgetPayload(generatedAt: generatedAt, providers: providers)
    }

    /// The prominent 5-hour windows, each paired with the weekly (7g) quota that gates it. Antigravity
    /// exposes sessions as `.session` model rows (Gemini, Claude/GPT), each matched to its own `.weekly`
    /// row by name; Claude/Codex carry a single account-level session gated by the account weekly.
    private static func fiveHourMetrics(_ svc: ServiceStatus) -> [WindowMetric] {
        let sessionModels = svc.models.filter { $0.window == .session }
        if !sessionModels.isEmpty {
            return sessionModels.map { m in
                let weekly = svc.models.first { $0.window == .weekly && $0.name == m.name }
                return WindowMetric(label: m.name, percent: m.remainingPercent, resetAt: m.resetAt,
                                    weeklyPercent: weekly?.remainingPercent, weeklyResetAt: weekly?.resetAt)
            }
        }
        if let pct = svc.sessionRemainingPercent {
            return [WindowMetric(label: svc.name, percent: pct, resetAt: svc.sessionResetAt,
                                 weeklyPercent: svc.weeklyRemainingPercent, weeklyResetAt: svc.weeklyResetAt)]
        }
        return []
    }
}
