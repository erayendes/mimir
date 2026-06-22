import AppIntents
import WidgetKit
// MimirShared (WidgetStore/WidgetPayload) compiles into this target — same-module, no import.

/// Configuration for the widget: which 5-hour window the **Small** size pins to. Other sizes show
/// every window regardless, so they ignore this. Edit via long-press → Edit Widget → Model.
struct SelectMetricIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Mimir"
    static let description = IntentDescription(LocalizedStringResource("widget.config.description"))

    @Parameter(title: LocalizedStringResource("widget.config.model"))
    var model: MetricOption?
}

/// One selectable model/window, identified by its label ("Claude", "Codex", "Gemini", "Claude/GPT").
struct MetricOption: AppEntity {
    let id: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Model"
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
    static let defaultQuery = MetricOptionQuery()
}

/// Dynamic options: the picker lists whatever 5h windows the live App Group snapshot currently
/// carries, so connecting/disconnecting a provider changes the choices.
struct MetricOptionQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [MetricOption] {
        identifiers.map { MetricOption(id: $0) }
    }
    func suggestedEntities() async throws -> [MetricOption] {
        let labels = WidgetStore.read()?.providers
            .filter(\.isAvailable)
            .flatMap { $0.fiveHour.map(\.label) } ?? []
        return labels.map { MetricOption(id: $0) }
    }
}
