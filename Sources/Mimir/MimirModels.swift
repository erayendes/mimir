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

    init(
        name: String,
        iconName: String,
        sessionResetAt: Date?,
        weeklyResetAt: Date?,
        sessionRemainingPercent: Int? = nil,
        weeklyRemainingPercent: Int? = nil,
        models: [ModelStatus],
        isAvailable: Bool,
        statusNote: String?
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
