import AppIntents
import WidgetKit
// MimirShared (WidgetStore/WidgetPayload) compiles into this target — same-module, no import.

/// Configuration for the widget: which model the Small and Medium sizes pin to. Edit via
/// long-press → Edit Widget → Model.
struct SelectMetricIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Mimir"
    static let description = IntentDescription(LocalizedStringResource("widget.config.description"))

    @Parameter(title: LocalizedStringResource("widget.config.model"))
    var model: MetricOption?
}

/// One selectable model/window, identified by its label ("Claude", "Claude Work", "Gemini"). Shown
/// by the provider's own name with the login under it, so two Claude accounts are two clear choices.
struct MetricOption: AppEntity {
    let id: String
    var title: String? = nil
    var subtitle: String? = nil

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Model"
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title ?? id)", subtitle: subtitle.map { "\($0)" })
    }
    static let defaultQuery = MetricOptionQuery()

    /// Every window the live snapshot carries, named as the widget shows it.
    static func all() -> [MetricOption] {
        (WidgetStore.read()?.providers ?? []).filter(\.isAvailable).flatMap { p in
            p.fiveHour.map { m in
                MetricOption(id: m.label, title: p.displayLabel(m),
                             subtitle: [p.plan, p.email].compactMap { $0 }.joined(separator: " · ").nilIfEmpty)
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Dynamic options: the picker lists whatever 5h windows the live App Group snapshot currently
/// carries, so connecting/disconnecting a provider changes the choices.
struct MetricOptionQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [MetricOption] {
        let known = MetricOption.all()
        return identifiers.map { id in known.first { $0.id == id } ?? MetricOption(id: id) }
    }
    func suggestedEntities() async throws -> [MetricOption] {
        MetricOption.all()
    }
}
