import WidgetKit
import SwiftUI
// MimirShared sources compile into this target — WidgetPayload/WidgetStore are same-module.

struct MimirEntry: TimelineEntry {
    let date: Date
    let payload: WidgetPayload?
    var selectedLabel: String? = nil   // the Small size's chosen window (from the widget config)
}

/// Reads the App Group snapshot the app writes (see `WidgetBridge`). Never touches keychain or
/// network — a widget extension is sandboxed and can only see the shared container. The app pokes
/// `reloadAllTimelines` on every quota refresh, so fresh data appears promptly; the ~15 min policy
/// is just a fallback so the "kalan süre" countdown doesn't go stale if the app is quiet.
struct MimirProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> MimirEntry {
        MimirEntry(date: Date(), payload: .sample)
    }
    func snapshot(for configuration: SelectMetricIntent, in context: Context) async -> MimirEntry {
        let payload = context.isPreview ? .sample : WidgetStore.read()
        return MimirEntry(date: Date(), payload: payload, selectedLabel: configuration.model?.id)
    }
    func timeline(for configuration: SelectMetricIntent, in context: Context) async -> Timeline<MimirEntry> {
        let now = Date()
        let entry = MimirEntry(date: now, payload: WidgetStore.read(), selectedLabel: configuration.model?.id)
        return Timeline(entries: [entry], policy: .after(now.addingTimeInterval(15 * 60)))
    }
}

/// The main, size-adaptive widget — one layout per WidgetKit family. Configurable: the Small size
/// pins to the chosen model (`SelectMetricIntent`); larger sizes show everything and ignore it.
/// `contentMarginsDisabled` so our own paddings are the single source of truth (match the spec).
struct MimirWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "MimirWidget", intent: SelectMetricIntent.self, provider: MimirProvider()) { entry in
            DetailedWidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetBackground() }
        }
        .configurationDisplayName("Mimir")
        .description(String(localized: "widget.detailed.description"))
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

@main
struct MimirWidgetBundle: WidgetBundle {
    var body: some Widget {
        MimirWidget()
    }
}

// Gallery/preview sample mirroring the handoff's reference data so the widget looks right before
// it's added (and when no snapshot exists yet).
extension WidgetPayload {
    static var sample: WidgetPayload {
        let now = Date()
        func at(_ mins: Double) -> Date { now.addingTimeInterval(mins * 60) }
        return WidgetPayload(generatedAt: now, providers: [
            ProviderPayload(name: "Claude", iconName: "claude", isAvailable: true, credits: "4.500",
                            fiveHour: [WindowMetric(label: "Claude", percent: 9, resetAt: at(18))],
                            sevenDay: [WindowMetric(label: "Claude", percent: 11, resetAt: at(8_460)),
                                       WindowMetric(label: "Sonnet", percent: 82, resetAt: at(8_460))]),
            ProviderPayload(name: "Codex", iconName: "codex", isAvailable: true, credits: "1.180",
                            fiveHour: [WindowMetric(label: "Codex", percent: 99, resetAt: at(283))],
                            sevenDay: [WindowMetric(label: "Codex", percent: 71, resetAt: at(3_124))]),
            ProviderPayload(name: "Antigravity", iconName: "antigravity", isAvailable: true, credits: "920",
                            fiveHour: [WindowMetric(label: "Gemini", percent: 100, resetAt: at(178)),
                                       WindowMetric(label: "Claude/GPT", percent: 44, resetAt: at(132))],
                            sevenDay: [WindowMetric(label: "Gemini", percent: 88, resetAt: at(3_978)),
                                       WindowMetric(label: "Claude/GPT", percent: 41, resetAt: at(9_983))]),
        ])
    }
}
