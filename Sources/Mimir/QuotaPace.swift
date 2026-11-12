import Foundation

/// One live reading of a long window: when, what was left, and which window (by its reset) it was.
struct QuotaReading: Codable, Equatable {
    let at: Date
    let percent: Int
    let resetAt: Date
}

/// Where a long window is heading at the pace it is being spent. Even use starts the window at 100%
/// and lands on 0% at the reset; the colour says whether this pace makes it there, not how much is left.
struct QuotaPace: Equatable {
    enum Tone { case early, green, amber, red }

    let tone: Tone
    /// What should be left now had the window been spent evenly: 100 at its start, 0 at the reset.
    /// nil early in the window, where it would only sit on the capsule's end.
    let idealPercent: Double?
    /// When the quota runs out at this pace, if that comes before the reset.
    let runsOutAt: Date?
    /// How long the window then sits empty before it resets.
    let emptyFor: TimeInterval?
    /// What is still left at the reset at this pace, when it lasts.
    let leftAtReset: Int?
    /// Early in the window: how long until a pace is given.
    var estimateIn: TimeInterval? = nil

    /// `history` is this window's earlier readings (see `QuotaHistory`); only the last day counts.
    static func compute(remaining: Int, resetAt: Date, window: TimeInterval, now: Date,
                        history: [QuotaReading] = []) -> QuotaPace? {
        let left = resetAt.timeIntervalSince(now)
        guard window > 0, left > 0 else { return nil }
        let elapsed = max(0, window - left)
        let remaining = Double(max(0, min(100, remaining)))
        let ideal = max(0, 100 * (1 - elapsed / window))
        // Too early to call until the window has seen a day and a night, and 5% of a long one.
        guard elapsed >= Self.earlyStretch(window) else {
            return QuotaPace(tone: .early, idealPercent: nil, runsOutAt: nil, emptyFor: nil,
                             leftAtReset: nil, estimateIn: Self.earlyStretch(window) - elapsed)
        }
        let average = (100 - remaining) / elapsed
        // The last day's pace, from the oldest reading in it, once that spans at least three hours.
        let recent = history.filter { now.timeIntervalSince($0.at) <= 86_400 }
            .min { $0.at < $1.at }
            .flatMap { first -> Double? in
                let span = now.timeIntervalSince(first.at)
                return span >= 3 * 3600 ? max(0, Double(first.percent) - remaining) / span : nil
            } ?? 0
        // The worse of the two: a quiet week shouldn't hide today's burst.
        let rate = max(average, recent)
        guard rate > 0 else {
            return QuotaPace(tone: .green, idealPercent: ideal, runsOutAt: nil, emptyFor: nil,
                             leftAtReset: Int(remaining))
        }
        let runsOut = now.addingTimeInterval(remaining / rate)
        if runsOut < resetAt {
            let empty = resetAt.timeIntervalSince(runsOut)
            let tone: Tone = empty < 0.02 * window ? .green : empty <= 0.10 * window ? .amber : .red
            return QuotaPace(tone: tone, idealPercent: ideal, runsOutAt: runsOut, emptyFor: empty,
                             leftAtReset: nil)
        }
        return QuotaPace(tone: .green, idealPercent: ideal, runsOutAt: nil, emptyFor: nil,
                         leftAtReset: Int((remaining - rate * left).rounded()))
    }

    /// A long window spent to 0% gates the session beside it: the popover greys that panel and shows
    /// no pace, and the widget follows. A lone long window (no session) isn't gated; it is the face.
    static func gated(weekly: Int?, session: Int?) -> Bool { weekly == 0 && session != nil }

    /// How long a window runs before its pace is judged: 5% of it, but never under a day.
    static func earlyStretch(_ window: TimeInterval) -> TimeInterval { max(0.05 * window, 86_400) }

    /// The line on the capsule, red only: how long the window sits empty. Amber says enough by its
    /// colour, and what is left over at the reset lives in the bubble.
    var note: String? {
        guard tone == .red, let emptyFor else { return nil }
        let (count, days) = Self.span(emptyFor)
        return String(format: days ? String(localized: "pace.short.days") : String(localized: "pace.short.hours"), count)
    }

    /// The bubble's one line: when it runs out, or what is left at the reset — or, early in the
    /// window, how long until there is a forecast at all.
    var info: String? {
        if let estimateIn {
            let (count, unit) = Self.startsIn(estimateIn)
            let key: String = switch unit {
            case .minute: String(localized: "pace.early.minutes")
            case .hour: String(localized: "pace.early.hours")
            default: String(localized: "pace.early.days")
            }
            return String(format: key, count)
        }
        if let runsOutAt {
            return String(format: String(localized: "pace.runsOut"), Self.dayClock.string(from: runsOutAt))
        }
        return leftAtReset.map { String(format: String(localized: "pace.leftAtReset"), $0) }
    }

    /// A wait in whole minutes under an hour, hours under a day, days past that; never zero. A
    /// duration, not a clock time: Turkish suffixes change with the hour.
    static func startsIn(_ interval: TimeInterval) -> (count: Int, unit: Calendar.Component) {
        if interval < 3600 { return (max(1, Int((interval / 60).rounded())), .minute) }
        if interval < 86_400 { return (max(1, Int((interval / 3600).rounded())), .hour) }
        return (Int((interval / 86_400).rounded()), .day)
    }

    /// Under a day in whole hours (at least one), from there in whole days.
    static func span(_ interval: TimeInterval) -> (count: Int, days: Bool) {
        interval < 86_400 ? (max(1, Int((interval / 3600).rounded())), false)
                          : (Int((interval / 86_400).rounded()), true)
    }

    private static let dayClock: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEE HH:mm"); return f
    }()
}

/// The last day of live readings per long window, kept on disk so a relaunch doesn't forget today's
/// pace. Written only from live reads (see `saveSnapshot(_:live:)`); read by the popover.
final class QuotaHistory: @unchecked Sendable {
    static let shared = QuotaHistory(
        url: LiveUsageDataSource.supportDirectory.appendingPathComponent("quota_history.json"))

    private let url: URL
    private let lock = NSLock()
    private var series: [String: [QuotaReading]]

    init(url: URL) {
        self.url = url
        series = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode([String: [QuotaReading]].self, from: $0) } ?? [:]
    }

    static func key(_ service: String, _ window: String) -> String { "\(service)|\(window)" }

    /// The readings of the window that resets at `resetAt`.
    func readings(_ key: String, resetAt: Date) -> [QuotaReading] {
        lock.lock(); defer { lock.unlock() }
        return (series[key] ?? []).filter { Self.sameWindow($0.resetAt, resetAt) }
    }

    /// Every long window a live card carries: the account's own, and each model's weekly cap. Five-hour
    /// windows, renewal credits, money rows and a plan's extra quota (Luna Reserve) are left out.
    func record(_ status: ServiceStatus, now: Date = Date()) {
        var points: [(key: String, percent: Int, resetAt: Date)] = []
        if let p = status.weeklyRemainingPercent, let r = status.weeklyResetAt {
            points.append((Self.key(status.name, "weekly"), p, r))
        }
        for m in status.models where m.valueText == nil && m.groupLabel == nil && m.window != .session {
            if let r = m.resetAt { points.append((Self.key(status.name, m.name), m.remainingPercent, r)) }
        }
        record(points.filter { $0.resetAt > now }, now: now)
    }

    func record(_ points: [(key: String, percent: Int, resetAt: Date)], now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var changed = false
        for point in points {
            let before = series[point.key]
            var list = (series[point.key] ?? []).filter { Self.sameWindow($0.resetAt, point.resetAt) }
            // One reading per ten minutes is plenty for a day-long pace, and keeps the file small.
            if list.last.map({ now.timeIntervalSince($0.at) >= 600 }) ?? true {
                list.append(QuotaReading(at: now, percent: point.percent, resetAt: point.resetAt))
            }
            series[point.key] = list
            changed = changed || list != before
        }
        guard changed else { return }
        // A day back is all the pace looks at; older readings and windows that have reset go.
        series = series.compactMapValues { list in
            let kept = list.filter { now.timeIntervalSince($0.at) <= 86_400 && $0.resetAt > now }
            return kept.isEmpty ? nil : kept
        }
        guard let data = try? JSONEncoder().encode(series) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Providers report a window's reset with a little jitter between reads; an hour apart is still one window.
    private static func sameWindow(_ a: Date, _ b: Date) -> Bool { abs(a.timeIntervalSince(b)) < 3600 }
}
