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

/// The single top→bottom display order for the three services, read by BOTH the popover cards
/// (`PopoverView.contentView`) and the menu-bar dots (`menuBarDots`). Keeping it in one place is
/// load-bearing: when the two defined the order independently they drifted, and a yellow dot lined
/// up with the wrong card. Change the order here and both move together.
let serviceDisplayOrder = ["Claude", "Codex", "Antigravity"]

/// One 5-hour session window a service exposes, paired with the weekly (7g) quota that gates it.
/// Antigravity expands to one window per `.session` model (its weekly matched by name); Claude/Codex
/// carry a single account-level session. This is the one source of truth for "what gates a 5h window"
/// — shared by the menu-bar dots and the widget bridge so they can never drift apart.
struct SessionWindow: Equatable {
    let label: String
    let sessionPercent: Int?      // nil = no current reading
    let sessionResetAt: Date?
    let weeklyPercent: Int?
    let weeklyResetAt: Date?
}

extension ServiceStatus {
    var sessionWindows: [SessionWindow] {
        let sessionModels = models.filter { $0.window == .session }
        if !sessionModels.isEmpty {
            return sessionModels.map { m in
                let weekly = models.first { $0.window == .weekly && $0.name == m.name }
                return SessionWindow(label: m.name, sessionPercent: m.remainingPercent, sessionResetAt: m.resetAt,
                                     weeklyPercent: weekly?.remainingPercent, weeklyResetAt: weekly?.resetAt)
            }
        }
        // No per-model sessions → the account-level session (Claude/Codex). `sessionPercent` may be
        // nil (a service visible only on its weekly reading): kept as one window so the menu bar still
        // shows a placeholder dot, while the widget drops it (no 5h number to render).
        return [SessionWindow(label: name, sessionPercent: sessionRemainingPercent, sessionResetAt: sessionResetAt,
                              weeklyPercent: weeklyRemainingPercent, weeklyResetAt: weeklyResetAt)]
    }
}

/// One menu-bar status dot per 5-hour session window: its remaining percent (nil = no reading yet →
/// grey placeholder) and whether the weekly (7g) quota is spent (→ grey lockout, matching the widget/
/// popover, since a full session can't be used while the week is gone).
struct MenuBarDot: Equatable {
    let sessionPercent: Int?
    var weeklyExhausted: Bool = false
}

/// The menu-bar dots, ordered to match the popover: `serviceDisplayOrder`, then each service's
/// families in row order (Antigravity shows one dot per family, not a collapsed worst). A service is
/// included on the popover's own rule (`isAvailable || isStale`), so a visible one is never silently
/// dotless. Pure (no AppKit) → unit-testable.
func menuBarDots(from services: [ServiceStatus]) -> [MenuBarDot] {
    var dots: [MenuBarDot] = []
    for name in serviceDisplayOrder {
        guard let svc = services.first(where: { $0.name == name }),
              svc.isAvailable || svc.isStale else { continue }
        dots.append(contentsOf: svc.sessionWindows.map {
            MenuBarDot(sessionPercent: $0.sessionPercent, weeklyExhausted: $0.weeklyPercent == 0)
        })
    }
    return dots
}

/// How many columns the menu-bar dot grid uses for `n` dots: a single vertical column up to 3
/// dots (the familiar look), then 2 columns from 4 on (so 4 lands as a 2×2). Beyond 4 the 2
/// columns keep filling row-major and the stack grows taller. Pure → unit-testable.
func menuBarColumnCount(for n: Int) -> Int {
    n <= 3 ? 1 : 2
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
