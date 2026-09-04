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
    // actionable "couldn't fetch" state (a message in place of the numbers) instead of stale ones. The
    // `fiveHour` labels are still carried so the rows know what to render.
    public var unavailable: Bool
    // Last-known reading shown while the live source is briefly unusable — e.g. Claude's access token
    // expired and only a user-initiated refresh can renew it (Mimir won't rotate Claude Code's token).
    // The widget dims such rows and makes them tappable so a tap triggers that refresh in the host.
    public var isStale: Bool

    public init(name: String, iconName: String, isAvailable: Bool, fiveHour: [WindowMetric],
                unavailable: Bool = false, isStale: Bool = false) {
        self.name = name
        self.iconName = iconName
        self.isAvailable = isAvailable
        self.fiveHour = fiveHour
        self.unavailable = unavailable
        self.isStale = isStale
    }

    private enum CodingKeys: String, CodingKey { case name, iconName, isAvailable, fiveHour, unavailable, isStale }

    // Custom decode so a payload written by an older app version (no `unavailable`/`isStale` key) still
    // reads — otherwise the widget would fail to decode and blank out during the post-update window.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        iconName = try c.decode(String.self, forKey: .iconName)
        isAvailable = try c.decode(Bool.self, forKey: .isAvailable)
        fiveHour = try c.decode([WindowMetric].self, forKey: .fiveHour)
        unavailable = try c.decodeIfPresent(Bool.self, forKey: .unavailable) ?? false
        isStale = try c.decodeIfPresent(Bool.self, forKey: .isStale) ?? false
    }
}

/// Whole days in a non-session quota window, for labelling it by its REAL length instead of
/// assuming "longer than a session means exactly 7 days". OpenAI's ChatGPT Go plan moved to a
/// ~30-day window in mid-2026, which a hardcoded "7d" badge would misreport.
///
/// Derived from the window's total length, never from how far the reset is — on day 27 of a
/// 30-day window the remaining time is 3 days, but the window is still a 30-day one.
/// Returns nil for session-length (<= 6h) or unknown windows, so callers can omit the badge
/// rather than print a wrong number.
public func quotaWindowDays(_ windowSeconds: TimeInterval?) -> Int? {
    guard let windowSeconds, windowSeconds > 6 * 3600 else { return nil }
    return max(1, Int((windowSeconds / 86_400).rounded()))
}

public struct WindowMetric: Codable, Equatable {
    public var label: String         // row label: "Claude" / "Gemini" / "Claude/GPT" / "Sonnet" …
    public var percent: Int          // remaining %, drives bar width + status colour
    public var resetAt: Date?        // when the window refills — countdown + HH:mm computed per entry
    // The weekly (7-day) quota that gates this same model/account, when known. Lets the widget show
    // the 7g line and grey a model out when its week is spent — a fresh 5h window isn't usable then.
    public var weeklyPercent: Int?
    public var weeklyResetAt: Date?
    // True when `percent`/`resetAt` describe the weekly (7g) window rather than the 5-hour (5s) one —
    // i.e. this service has no active 5h window (Codex since OpenAI's July 2026 removal), so the widget
    // shows its weekly reading as the headline and labels the pill "7g" instead of "5s".
    public var isWeekly: Bool
    // Real length of the window `percent`/`resetAt` describe, when the provider reports one. Lets the
    // widget label it by its actual size (7d vs 30d) instead of assuming weekly. nil = unknown.
    public var windowSeconds: TimeInterval?

    public init(label: String, percent: Int, resetAt: Date?,
                weeklyPercent: Int? = nil, weeklyResetAt: Date? = nil, isWeekly: Bool = false,
                windowSeconds: TimeInterval? = nil) {
        self.label = label
        self.percent = percent
        self.resetAt = resetAt
        self.weeklyPercent = weeklyPercent
        self.weeklyResetAt = weeklyResetAt
        self.isWeekly = isWeekly
        self.windowSeconds = windowSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case label, percent, resetAt, weeklyPercent, weeklyResetAt, isWeekly, windowSeconds
    }

    // Custom decode so a payload written by an older app version (no `isWeekly`/`windowSeconds` key)
    // still reads — otherwise the widget would fail to decode and blank out post-update.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        percent = try c.decode(Int.self, forKey: .percent)
        resetAt = try c.decodeIfPresent(Date.self, forKey: .resetAt)
        weeklyPercent = try c.decodeIfPresent(Int.self, forKey: .weeklyPercent)
        weeklyResetAt = try c.decodeIfPresent(Date.self, forKey: .weeklyResetAt)
        isWeekly = try c.decodeIfPresent(Bool.self, forKey: .isWeekly) ?? false
        windowSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .windowSeconds)
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
