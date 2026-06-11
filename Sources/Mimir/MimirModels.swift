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
        infoText: String? = nil
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
    }

    /// Return a copy with `infoText` attached. Lets the data layer set the explainer once
    /// at a single chokepoint rather than threading it through every construction site.
    func withInfoText(_ text: String?) -> ServiceStatus {
        ServiceStatus(
            name: name,
            iconName: iconName,
            sessionResetAt: sessionResetAt,
            weeklyResetAt: weeklyResetAt,
            sessionRemainingPercent: sessionRemainingPercent,
            weeklyRemainingPercent: weeklyRemainingPercent,
            models: models,
            isAvailable: isAvailable,
            statusNote: statusNote,
            isStale: isStale,
            infoText: text
        )
    }
}

struct ModelStatus: Identifiable {
    let id = UUID()
    let name: String
    let remainingPercent: Int
    let resetAt: Date?
    let valueText: String?

    init(name: String, remainingPercent: Int, resetAt: Date?, valueText: String? = nil) {
        self.name = name
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
        self.valueText = valueText
    }
}

struct AvailableUpdate: Equatable {
    let version: String   // e.g. "1.2.3" (without the leading "v")
    let url: URL          // GitHub release page
}

enum VersionCompare {
    /// Parse "v1.2.3" / "1.2.3" into numeric components, ignoring any pre-release suffix.
    static func components(_ raw: String) -> [Int] {
        let trimmed = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        let core = trimmed.split(separator: "-").first.map(String.init) ?? trimmed
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// True when `latest` is a strictly higher version than `current`.
    static func isNewer(_ latest: String, than current: String) -> Bool {
        let l = components(latest)
        let c = components(current)
        for i in 0 ..< max(l.count, c.count) {
            let lv = i < l.count ? l[i] : 0
            let cv = i < c.count ? c[i] : 0
            if lv != cv { return lv > cv }
        }
        return false
    }
}

enum TimeFormatter {
    static func duration(from interval: TimeInterval) -> String {
        let clamped = max(0, Int(interval.rounded(.down)))
        let days = clamped / 86_400
        let hours = (clamped % 86_400) / 3_600
        let minutes = (clamped % 3_600) / 60

        if days > 0 {
            if hours > 0 { return "\(days)d \(hours)h" }
            return "\(days)d"
        }

        if hours > 0 {
            if minutes > 0 { return "\(hours)h \(minutes)m" }
            return "\(hours)h"
        }

        return "\(max(minutes, 1))m"
    }
}
