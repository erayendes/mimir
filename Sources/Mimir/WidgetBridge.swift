import Foundation
import MimirShared
import WidgetKit

/// Maps the app's live `[ServiceStatus]` into the compact `WidgetPayload`, writes it to the App
/// Group container, and nudges WidgetKit to reload. Called from the `store.$services` sink so the
/// widget tracks every refresh. Pure mapping (no AppKit) → unit-testable.
enum WidgetBridge {
    static func update(_ services: [ServiceStatus]) {
        let payload = makePayload(services, generatedAt: Date())
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
                credits: svc.models.first(where: { $0.valueText != nil })?.valueText,
                fiveHour: fiveHourMetrics(svc),
                sevenDay: sevenDayMetrics(svc)
            )
        }
        return WidgetPayload(generatedAt: generatedAt, providers: providers)
    }

    /// The prominent 5-hour windows. Antigravity exposes them as `.session` model rows (Gemini,
    /// Claude/GPT); Claude/Codex carry a single account-level session percent instead.
    private static func fiveHourMetrics(_ svc: ServiceStatus) -> [WindowMetric] {
        let sessionModels = svc.models.filter { $0.window == .session }
        if !sessionModels.isEmpty {
            return sessionModels.map { WindowMetric(label: $0.name, percent: $0.remainingPercent, resetAt: $0.resetAt) }
        }
        if let pct = svc.sessionRemainingPercent {
            return [WindowMetric(label: svc.name, percent: pct, resetAt: svc.sessionResetAt)]
        }
        return []
    }

    /// The 7-day sub-metrics (XL only). Antigravity uses `.weekly` model rows; Claude/Codex use the
    /// account weekly percent, plus any extra weekly-window percentage rows (Claude's "Sonnet",
    /// which carries no `window` tag and isn't a credit/`valueText` row).
    private static func sevenDayMetrics(_ svc: ServiceStatus) -> [WindowMetric] {
        let weeklyModels = svc.models.filter { $0.window == .weekly }
        if !weeklyModels.isEmpty {
            return weeklyModels.map { WindowMetric(label: $0.name, percent: $0.remainingPercent, resetAt: $0.resetAt) }
        }
        var out: [WindowMetric] = []
        if let pct = svc.weeklyRemainingPercent {
            out.append(WindowMetric(label: svc.name, percent: pct, resetAt: svc.weeklyResetAt))
        }
        for m in svc.models where m.window == nil && m.valueText == nil {
            out.append(WindowMetric(label: m.name, percent: m.remainingPercent, resetAt: m.resetAt))
        }
        return out
    }
}
