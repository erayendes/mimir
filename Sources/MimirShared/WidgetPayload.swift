import Foundation
import SwiftUI

// The app→widget contract. The menu-bar app maps its live `[ServiceStatus]` into this compact,
// Codable snapshot (see `WidgetBridge`) and writes it to the App Group container; the widget
// extension (sandboxed, no keychain/network) only ever decodes this file. `resetAt` stays a
// `Date` — never a pre-rendered string — so each timeline entry recomputes the countdown and
// reset clock live as time passes between WidgetKit's throttled reloads.

public struct WidgetPayload: Codable {
    public var generatedAt: Date
    public var providers: [ProviderPayload]

    public init(generatedAt: Date, providers: [ProviderPayload]) {
        self.generatedAt = generatedAt
        self.providers = providers
    }
}

public struct ProviderPayload: Codable {
    public var name: String          // "Claude" / "Codex" / "Antigravity"
    public var iconName: String      // brand asset stem: "claude" / "codex" / "antigravity"
    public var isAvailable: Bool
    public var credits: String?      // remaining credit balance, e.g. "920" (XL only)
    public var fiveHour: [WindowMetric]   // the prominent 5h windows (1 for Claude/Codex, 2 for AG)
    public var sevenDay: [WindowMetric]   // 7-day sub-metrics (XL only)

    public init(name: String, iconName: String, isAvailable: Bool, credits: String?,
                fiveHour: [WindowMetric], sevenDay: [WindowMetric]) {
        self.name = name
        self.iconName = iconName
        self.isAvailable = isAvailable
        self.credits = credits
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }
}

public struct WindowMetric: Codable {
    public var label: String         // row label: "Claude" / "Gemini" / "Claude/GPT" / "Sonnet" …
    public var percent: Int          // remaining %, drives bar width + status colour
    public var resetAt: Date?        // when the window refills — countdown + HH:mm computed per entry

    public init(label: String, percent: Int, resetAt: Date?) {
        self.label = label
        self.percent = percent
        self.resetAt = resetAt
    }
}

/// Reads/writes the single `widget_payload.json` in the App Group container. Atomic write avoids a
/// half-written file racing a widget read; a missing/corrupt file decodes to `nil` (widget shows
/// its placeholder). Replaces the P0 `WidgetSpike`.
public enum WidgetStore {
    private static var url: URL? {
        MimirAppGroup.containerURL?.appendingPathComponent("widget_payload.json")
    }

    public static func write(_ payload: WidgetPayload) {
        guard let url, let data = try? JSONEncoder.widget.encode(payload) else { return }
        // The non-sandboxed app may be the first to touch the container; create it if absent.
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public static func read() -> WidgetPayload? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.widget.decode(WidgetPayload.self, from: data)
    }
}

extension JSONEncoder {
    static var widget: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var widget: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
