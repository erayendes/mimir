import Foundation

struct ServiceStatus: Identifiable {
    let id = UUID()
    let name: String
    let iconName: String
    let sessionResetAt: Date?
    let weeklyResetAt: Date?
    let sessionRemainingPercent: Int?
    let weeklyRemainingPercent: Int?
    let models: [ModelStatus]
    let isAvailable: Bool
    let statusNote: String?
    /// Last-known data shown because the live source is gone (e.g. Antigravity IDE closed).
    /// Not "available", but must survive the popover's unavailable-service filter so the
    /// user still sees the snapshot instead of the service silently vanishing.
    let isStale: Bool
    /// Optional explainer surfaced behind an (i) icon on the card — e.g. how the data is
    /// sourced and what the user must do to refresh it.
    let infoText: String?
    /// Transient signal (not displayed) telling `UsageStore` how to update this service's
    /// fetch cooldown: `nil` = leave cooldown unchanged, `0` = clear it (live success),
    /// `> 0` = back off for that many seconds (e.g. an HTTP 429 `Retry-After`).
    let cooldownHint: TimeInterval?

    init(
        name: String,
        iconName: String,
        sessionResetAt: Date?,
        weeklyResetAt: Date?,
        sessionRemainingPercent: Int? = nil,
        weeklyRemainingPercent: Int? = nil,
        models: [ModelStatus],
        isAvailable: Bool,
        statusNote: String?,
        isStale: Bool = false,
        infoText: String? = nil,
        cooldownHint: TimeInterval? = nil
    ) {
        self.name = name
        self.iconName = iconName
        self.sessionResetAt = sessionResetAt
        self.weeklyResetAt = weeklyResetAt
        self.sessionRemainingPercent = sessionRemainingPercent
        self.weeklyRemainingPercent = weeklyRemainingPercent
        self.models = models
        self.isAvailable = isAvailable
        self.statusNote = statusNote
        self.isStale = isStale
        self.infoText = infoText
        self.cooldownHint = cooldownHint
    }

    /// Return a copy with `infoText` attached. Lets the data layer set the explainer once
    /// at a single chokepoint rather than threading it through every construction site.
    func withInfoText(_ text: String?) -> ServiceStatus {
        copy(infoText: .some(text))
    }

    /// Return a copy with a different `statusNote` — used to stamp an actionable reason
    /// (e.g. "token expired — open Claude Code") onto a loaded snapshot without rebuilding it.
    func withStatusNote(_ note: String?) -> ServiceStatus {
        copy(statusNote: .some(note))
    }

    /// Return a copy carrying a cooldown signal for `UsageStore` (see `cooldownHint`).
    func withCooldownHint(_ hint: TimeInterval?) -> ServiceStatus {
        copy(cooldownHint: .some(hint))
    }

    /// One-field copy. Each parameter is a double optional: `nil` keeps the current value,
    /// `.some(x)` overwrites it (so passing `.some(nil)` can clear an optional field).
    private func copy(
        statusNote: String?? = nil,
        infoText: String?? = nil,
        cooldownHint: TimeInterval?? = nil
    ) -> ServiceStatus {
        ServiceStatus(
            name: name,
            iconName: iconName,
            sessionResetAt: sessionResetAt,
            weeklyResetAt: weeklyResetAt,
            sessionRemainingPercent: sessionRemainingPercent,
            weeklyRemainingPercent: weeklyRemainingPercent,
            models: models,
            isAvailable: isAvailable,
            statusNote: statusNote ?? self.statusNote,
            isStale: isStale,
            infoText: infoText ?? self.infoText,
            cooldownHint: cooldownHint ?? self.cooldownHint
        )
    }
}

/// Which quota window a model row belongs to. Lets the UI place a row in the weekly
/// summary vs the prominent session block without parsing (localized) labels.
enum ModelWindow {
    case weekly
    case session
}

/// The menu-bar status dots, one per service the popover shows, ordered top→bottom to match
/// the popover's card order (services are name-sorted, so: Antigravity, Claude, Codex) — dot N
/// then lines up with card N. A service is included on the *same* rule the popover uses
/// (`isAvailable || isStale`), so the dot count always matches the visible card count —
/// the source of the "3 cards, 2 dots" bug was the menu bar instead *dropping* a service
/// that had no 5-hour reading. Each value is the service's **5-hour (session)** remaining
/// percent, or `nil` when there is no current session reading (its 5h window reset, or live
/// data couldn't be fetched yet). The menu bar renders `nil` as a neutral grey "no data" dot
/// and recolours it once the 5h number arrives, so a visible service is never silently
/// dotless. Pure (no AppKit) so the selection logic is unit-testable.
func menuBarDots(from services: [ServiceStatus]) -> [Int?] {
    var dots: [Int?] = []
    for name in ["Antigravity", "Claude", "Codex"] {
        guard let svc = services.first(where: { $0.name == name }),
              svc.isAvailable || svc.isStale else { continue }
        if name == "Antigravity" {
            // Two grouped families (Gemini, Claude/GPT); take the most constrained 5h session
            // row. `.min()` over no session rows is nil → grey, same as Claude/Codex below.
            dots.append(svc.models.filter { $0.window == .session }.map(\.remainingPercent).min())
        } else {
            dots.append(svc.sessionRemainingPercent)
        }
    }
    return dots
}

struct ModelStatus: Identifiable {
    let id = UUID()
    let name: String
    let remainingPercent: Int
    let resetAt: Date?
    let valueText: String?
    /// For a `valueText` row (e.g. a credit balance) whose level isn't a 0–100 percent: set true
    /// when it's below its threshold, so the menu-bar low-quota badge can trigger on it. Percentage
    /// rows leave this false and are judged by `remainingPercent` instead.
    let isLow: Bool
    /// Weekly vs session window (Antigravity's grouped rows). `nil` for credit rows.
    let window: ModelWindow?

    init(name: String, remainingPercent: Int, resetAt: Date?, valueText: String? = nil, isLow: Bool = false, window: ModelWindow? = nil) {
        self.name = name
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
        self.valueText = valueText
        self.isLow = isLow
        self.window = window
    }
}

enum TimeFormatter {
    /// Localised single-letter unit suffixes — en: d/h/m, tr: g/s/d.
    static var dayUnit: String { String(localized: "duration.unit.day") }
    static var hourUnit: String { String(localized: "duration.unit.hour") }
    static var minuteUnit: String { String(localized: "duration.unit.minute") }

    static func duration(from interval: TimeInterval) -> String {
        duration(from: interval, day: dayUnit, hour: hourUnit, minute: minuteUnit)
    }

    /// Unit-injectable core so the numeric breakdown can be unit-tested without a locale,
    /// and so the localised suffixes are applied in exactly one place.
    static func duration(from interval: TimeInterval, day: String, hour: String, minute: String) -> String {
        let clamped = max(0, Int(interval.rounded(.down)))
        let days = clamped / 86_400
        let hours = (clamped % 86_400) / 3_600
        let minutes = (clamped % 3_600) / 60

        if days > 0 {
            if hours > 0 { return "\(days)\(day) \(hours)\(hour)" }
            return "\(days)\(day)"
        }

        if hours > 0 {
            if minutes > 0 { return "\(hours)\(hour) \(minutes)\(minute)" }
            return "\(hours)\(hour)"
        }

        return "\(max(minutes, 1))\(minute)"
    }
}
