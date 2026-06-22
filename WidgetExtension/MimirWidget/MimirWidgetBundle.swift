import WidgetKit
import SwiftUI
// Note: MimirShared's sources (AppGroup.swift) are compiled directly into this extension target
// (see project.yml `sources`), so its symbols are same-module here — no `import MimirShared`.

// P0 spike widget — proves the App Group bridge end to end: the app writes an Int into the shared
// container, this widget reads it. Replaced by the real designs once the signing/container chain
// is verified. Intentionally minimal: no design tokens, no payload, just `WidgetSpike.read()`.

struct SpikeEntry: TimelineEntry {
    let date: Date
    let n: Int?
    let diag: String
}

/// Diagnostic read for P0: surfaces exactly what the SANDBOXED widget resolves — the container
/// path (or NIL), and whether the file read succeeds — both to the log and onto the widget face.
func spikeDiag() -> (Int?, String) {
    let id = MimirAppGroup.identifier
    let gc = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    var w = "no-gc"
    if let gc {
        do { try Data("hi".utf8).write(to: gc.appendingPathComponent("widget_marker.txt")); w = "write-OK" }
        catch { w = "write-FAIL" }
    }
    let n = WidgetSpike.read()
    let report = "id=\(id)\ngc=\(gc?.path ?? "nil")\nwidgetWrite=\(w)\nread=\(n.map(String.init) ?? "nil")"
    try? report.write(toFile: NSHomeDirectory() + "/wdiag.txt", atomically: true, encoding: .utf8)
    return (n, "\(w)\nread=\(n.map(String.init) ?? "nil")")
}

struct SpikeProvider: TimelineProvider {
    func placeholder(in context: Context) -> SpikeEntry {
        SpikeEntry(date: Date(), n: nil, diag: "placeholder")
    }
    func getSnapshot(in context: Context, completion: @escaping (SpikeEntry) -> Void) {
        let (n, diag) = spikeDiag()
        completion(SpikeEntry(date: Date(), n: n, diag: diag))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SpikeEntry>) -> Void) {
        let (n, diag) = spikeDiag()
        let entry = SpikeEntry(date: Date(), n: n, diag: diag)
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60))))
    }
}

struct SpikeView: View {
    let entry: SpikeEntry
    var body: some View {
        VStack(spacing: 5) {
            Text("Mimir spike v2")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.6))
            Text(entry.n.map { "n = \($0)" } ?? "no data")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(entry.n == nil ? .red : .green)
            Text(entry.diag)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 6)
        }
        .containerBackground(.black, for: .widget)
    }
}

struct MimirSpikeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MimirSpikeWidget", provider: SpikeProvider()) { entry in
            SpikeView(entry: entry)
        }
        .configurationDisplayName("Mimir Spike")
        .description("P0 App Group spike")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct MimirWidgetBundle: WidgetBundle {
    var body: some Widget {
        MimirSpikeWidget()
    }
}
