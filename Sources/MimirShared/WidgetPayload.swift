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

public struct ProviderPayload: Codable, Equatable {
    public var name: String          // "Claude" / "Codex" / "Antigravity"
    public var iconName: String      // brand asset stem: "claude" / "codex" / "antigravity"
    public var isAvailable: Bool
    public var fiveHour: [WindowMetric]   // the prominent 5h windows (1 for Claude/Codex, 2 for AG)
    // The live source has been unreachable too long to trust the last reading: the widget renders an
    // actionable "couldn't fetch" state (small message / medium "—") instead of stale numbers. The
    // `fiveHour` labels are still carried so the rows know what to render.
    public var unavailable: Bool

    public init(name: String, iconName: String, isAvailable: Bool, fiveHour: [WindowMetric],
                unavailable: Bool = false) {
        self.name = name
        self.iconName = iconName
        self.isAvailable = isAvailable
        self.fiveHour = fiveHour
        self.unavailable = unavailable
    }
}

public struct WindowMetric: Codable, Equatable {
    public var label: String         // row label: "Claude" / "Gemini" / "Claude/GPT" / "Sonnet" …
    public var percent: Int          // remaining %, drives bar width + status colour
    public var resetAt: Date?        // when the window refills — countdown + HH:mm computed per entry
    // The weekly (7-day) quota that gates this same model/account, when known. Lets the widget show
    // the 7g line and grey a model out when its week is spent — a fresh 5h window isn't usable then.
    public var weeklyPercent: Int?
    public var weeklyResetAt: Date?

    public init(label: String, percent: Int, resetAt: Date?,
                weeklyPercent: Int? = nil, weeklyResetAt: Date? = nil) {
        self.label = label
        self.percent = percent
        self.resetAt = resetAt
        self.weeklyPercent = weeklyPercent
        self.weeklyResetAt = weeklyResetAt
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
