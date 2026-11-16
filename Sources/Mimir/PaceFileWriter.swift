import Darwin
import Foundation
import MimirShared

/// A small, private snapshot for generated CLI status lines. The app remains the pace authority.
enum PaceFileWriter {
    struct Window: Codable {
        let tone: String
        let idealPercent: Double
        let note: String?
        let resetAt: Double
        /// Present only for a model-scoped window; CLI stdin has no matching percentage.
        var remainingPercent: Int? = nil
    }

    private struct Snapshot: Codable {
        struct StampedWindow: Codable {
            let tone: String
            let idealPercent: Double
            let note: String?
            let resetAt: Double
            let writtenAt: Double
            let remainingPercent: Int?

            init(_ window: Window, now: Date) {
                tone = window.tone
                idealPercent = window.idealPercent
                note = window.note
                resetAt = window.resetAt
                writtenAt = now.timeIntervalSince1970
                remainingPercent = window.remainingPercent
            }
        }
        let windows: [String: StampedWindow]
    }

    static func write(_ windows: [String: Window], to directory: URL, now: Date) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        let data = try JSONEncoder().encode(Snapshot(windows: windows.mapValues { .init($0, now: now) }))
        let target = directory.appendingPathComponent("mimir-pace.json")
        let temporary = directory.appendingPathComponent(".mimir-pace-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        defer { unlink(temporary.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        guard rename(temporary.path, target.path) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    /// Reuse exactly the widget's already computed pace, including its localized red note.
    static func update(services: [ServiceStatus], payload: WidgetPayload, now: Date) {
        for (service, provider) in zip(services.sortedByDisplayOrder(), payload.providers) {
            let directory: URL
            let keys: (String) -> String?
            switch service.providerTitle {
            case "Claude" where service.name != LiveUsageDataSource.claudeDesktopCardName:
                directory = ExtraAccount.claude.first { $0.name == service.name }?.dir
                    ?? URL(fileURLWithPath: MimirStatusLineHook.claudeDir)
                keys = { _ in "seven_day" }
            case "Antigravity":
                directory = AntigravityStatusLineHook().directory
                keys = { label in
                    let name = label.lowercased()
                    if name.contains("argon") { return "argon" }
                    if name.contains("gemini") { return "gemini" }
                    if name.contains("claude") || name.contains("gpt") { return "3p" }
                    return nil
                }
            default: continue
            }
            let windows = windows(service: service, provider: provider, keys: keys, now: now)
            try? write(windows, to: directory, now: now)
        }
    }

    static func windows(service: ServiceStatus, provider: ProviderPayload,
                        keys: (String) -> String?, now: Date) -> [String: Window] {
        var windows: [String: Window] = [:]
        if !service.isStale {
            for metric in provider.fiveHour {
                guard let key = keys(metric.label), let tone = metric.tone,
                      let ideal = metric.idealPercent, let reset = metric.weeklyResetAt else { continue }
                windows[key] = Window(tone: tone.rawValue, idealPercent: ideal,
                                      note: tone == .red ? metric.note : nil,
                                      resetAt: reset.timeIntervalSince1970)
            }
            if service.providerTitle == "Claude",
               let row = service.models.first(where: {
                   $0.name == "Fable" && $0.valueText == nil && $0.groupLabel == nil
               }), let reset = row.resetAt, reset > now {
                let pace = QuotaPace.compute(remaining: row.remainingPercent, resetAt: reset,
                    window: 7 * 86_400, now: now,
                    history: QuotaHistory.shared.readings(
                        QuotaHistory.key(service.name, row.name), resetAt: reset))
                let tone: String = switch pace?.tone {
                case .green: "green"
                case .amber: "amber"
                case .red: "red"
                case .early, nil:
                    row.remainingPercent >= 40 ? "green" : row.remainingPercent >= 10 ? "amber" : "red"
                }
                let ideal = pace?.idealPercent
                    ?? min(100, max(0, 100 * reset.timeIntervalSince(now) / (7 * 86_400)))
                windows["seven_day_fable"] = Window(tone: tone, idealPercent: ideal,
                    note: pace?.tone == .red ? pace?.note : nil,
                    resetAt: reset.timeIntervalSince1970,
                    remainingPercent: row.remainingPercent)
            }
            // The widget's prominent rows omit a weekly-only Antigravity family (Argon).
            // The popover still computes its pace, so include that family here as well.
            if service.providerTitle == "Antigravity" {
                for row in service.models where row.window == .weekly {
                    guard let key = keys(row.name),
                          windows[key] == nil, row.remainingPercent > 0,
                          let reset = row.resetAt,
                          let pace = QuotaPace.compute(remaining: row.remainingPercent, resetAt: reset,
                              window: 7 * 86_400, now: now,
                              history: QuotaHistory.shared.readings(
                                  QuotaHistory.key(service.name, row.name), resetAt: reset)),
                          pace.tone != .early, let ideal = pace.idealPercent else { continue }
                    let tone: String = switch pace.tone {
                    case .green: "green"
                    case .amber: "amber"
                    case .red: "red"
                    case .early: "green"
                    }
                    windows[key] = Window(tone: tone, idealPercent: ideal, note: pace.note,
                                          resetAt: reset.timeIntervalSince1970)
                }
            }
        }
        return windows
    }
}
