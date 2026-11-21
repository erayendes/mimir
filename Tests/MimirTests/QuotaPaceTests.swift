import XCTest
@testable import Mimir

/// The pace of a long window: whether this rate lasts to the reset, and by how much it falls short.
final class QuotaPaceTests: XCTestCase {
    let week: TimeInterval = 7 * 86_400
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    /// Halfway through a week with `used` spent, no history: the average pace alone.
    private func halfway(_ used: Int, window: TimeInterval? = nil, history: [QuotaReading] = []) -> QuotaPace {
        let window = window ?? week
        return QuotaPace.compute(remaining: 100 - used, resetAt: now.addingTimeInterval(window / 2),
                                 window: window, now: now, history: history)!
    }

    func testEmptyTimeDecidesTheTone() {
        // Halfway, empty time = half × (2u − 100) / u: 51 → 3.3h (under 2% of a week), 52 → 6.5h.
        XCTAssertEqual(halfway(51).tone, .green)
        XCTAssertNotNil(halfway(51).lastsFor)
        XCTAssertNil(halfway(51).note)
        XCTAssertEqual(halfway(52).tone, .amber)
        XCTAssertEqual(halfway(55).tone, .amber)   // 15.3h, under 10% (16.8h)
        XCTAssertEqual(halfway(56).tone, .red)     // 18h
        // Only red says it in words; amber is the colour alone.
        XCTAssertNil(halfway(55).note)
        XCTAssertNotNil(halfway(56).note)
        XCTAssertEqual(halfway(60).emptyFor!, 3.5 * 86_400 / 3, accuracy: 1)
    }

    func testThirtyDayWindowScales() {
        let month: TimeInterval = 30 * 86_400
        XCTAssertEqual(halfway(51, window: month).tone, .green)   // 14h, under 2% (14.4h)
        XCTAssertEqual(halfway(52, window: month).tone, .amber)   // 27.7h
        XCTAssertEqual(halfway(60, window: month).tone, .red)     // 5d
        // The early stretch is 5% of the window: a day and a half of thirty.
        let early = QuotaPace.compute(remaining: 50, resetAt: now.addingTimeInterval(month - 86_400),
                                      window: month, now: now)!
        XCTAssertEqual(early.tone, .early)
        XCTAssertNil(early.note)
    }

    func testEarlyInTheWindowNoEstimate() {
        let pace = QuotaPace.compute(remaining: 40, resetAt: now.addingTimeInterval(week - 7 * 3600),
                                     window: week, now: now)!
        XCTAssertEqual(pace.tone, .early)
        XCTAssertNil(pace.lastsFor)
        // No ideal line yet: it would only sit on the capsule's end.
        XCTAssertNil(pace.idealPercent)
        // But the bubble says when the forecast starts: 17h after 7h of a week.
        XCTAssertEqual(pace.estimateIn!, 17 * 3600, accuracy: 1)
        XCTAssertNotNil(pace.info)
    }

    func testForecastStartsInMinutesHoursOrDays() {
        XCTAssertTrue(QuotaPace.startsIn(40 * 60) == (40, .minute))
        XCTAssertTrue(QuotaPace.startsIn(10) == (1, .minute))
        XCTAssertTrue(QuotaPace.startsIn(14.3 * 3600) == (14, .hour))
        XCTAssertTrue(QuotaPace.startsIn(2.2 * 86_400) == (2, .day))
        // Past the early stretch there's a forecast instead, and one line of it.
        XCTAssertNil(halfway(30).estimateIn)
        XCTAssertFalse(halfway(30).info!.contains("\n"))
        // Running out: how long it lasts, then how long it sits empty — 60 used halfway lasts 2.3 days of 3.5.
        let lines = halfway(60).info!.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(halfway(60).lastsFor!, 3.5 * 86_400 * 2 / 3, accuracy: 1)
    }

    /// The early stretch is the longer of a day and 5% of the window.
    func testEarlyStretchIsADayOrFivePercent() {
        func tone(elapsed hours: Double, window: TimeInterval) -> QuotaPace.Tone {
            QuotaPace.compute(remaining: 50, resetAt: now.addingTimeInterval(window - hours * 3600),
                              window: window, now: now)!.tone
        }
        let month: TimeInterval = 30 * 86_400
        XCTAssertEqual(QuotaPace.earlyStretch(week), 86_400)
        XCTAssertEqual(QuotaPace.earlyStretch(month), 36 * 3600)
        XCTAssertEqual(tone(elapsed: 23, window: week), .early)
        XCTAssertNotEqual(tone(elapsed: 25, window: week), .early)
        XCTAssertEqual(tone(elapsed: 35, window: month), .early)
        XCTAssertNotEqual(tone(elapsed: 37, window: month), .early)
        XCTAssertNotNil(QuotaPace.compute(remaining: 50, resetAt: now.addingTimeInterval(week - 25 * 3600),
                                          window: week, now: now)!.idealPercent)
    }

    func testLeftOverAtReset() {
        // 30 used in 3.5 days: 70 left, 30 more at this rate, 40 to spare.
        let pace = halfway(30)
        XCTAssertEqual(pace.tone, .green)
        XCTAssertEqual(pace.leftAtReset, 40)
        // What's left over is the bubble's, not the capsule's.
        XCTAssertNil(pace.note)
        XCTAssertEqual(pace.idealPercent ?? -1, 50, accuracy: 0.01)
        XCTAssertEqual(halfway(45).leftAtReset, 10)
    }

    func testNothingSpentKeepsItAll() {
        let pace = halfway(0)
        XCTAssertEqual(pace.tone, .green)
        XCTAssertEqual(pace.leftAtReset, 100)
        XCTAssertNil(pace.lastsFor)
    }

    func testTheLastDaysPaceWinsWhenFaster() {
        // The same 30 used, but all of it today: 30 a day runs 70 out in 2.3 days, 1.2 days early.
        let today = [QuotaReading(at: now.addingTimeInterval(-86_400), percent: 100,
                                  resetAt: now.addingTimeInterval(3.5 * 86_400))]
        let pace = halfway(30, history: today)
        XCTAssertEqual(pace.tone, .red)
        XCTAssertEqual(pace.emptyFor!, 3.5 * 86_400 - 70.0 / 30 * 86_400, accuracy: 1)
    }

    func testTheLastDaysPaceNeedsThreeHoursAndOnlyADay() {
        let reset = now.addingTimeInterval(3.5 * 86_400)
        let tooShort = [QuotaReading(at: now.addingTimeInterval(-2 * 3600), percent: 100, resetAt: reset)]
        XCTAssertEqual(halfway(30, history: tooShort).leftAtReset, 40)
        let tooOld = [QuotaReading(at: now.addingTimeInterval(-31 * 3600), percent: 100, resetAt: reset)]
        XCTAssertEqual(halfway(30, history: tooOld).leftAtReset, 40)
        // A slower few hours don't soften the average…
        let slowHours = [QuotaReading(at: now.addingTimeInterval(-10 * 3600), percent: 71, resetAt: reset)]
        XCTAssertEqual(halfway(30, history: slowHours).leftAtReset, 40)
    }

    /// With a full day of readings the pace is that day's, slower or faster than the week so far.
    func testAFullDaySetsThePaceEitherWay() {
        let reset = now.addingTimeInterval(3.5 * 86_400)
        // 30 used, but only 2 of it in the last day: 2 a day leaves 63 of 70 at the reset.
        let slow = [QuotaReading(at: now.addingTimeInterval(-86_400), percent: 72, resetAt: reset)]
        XCTAssertEqual(halfway(30, history: slow).leftAtReset, 63)
        // Nothing spent today: it all lasts.
        let idle = [QuotaReading(at: now.addingTimeInterval(-21 * 3600), percent: 70, resetAt: reset)]
        XCTAssertEqual(halfway(30, history: idle).leftAtReset, 70)
        // A night with the Mac off: the reading just past a day back still anchors it, not this morning's.
        let night = [QuotaReading(at: now.addingTimeInterval(-24.5 * 3600), percent: 72, resetAt: reset),
                     QuotaReading(at: now.addingTimeInterval(-15 * 3600), percent: 72, resetAt: reset)]
        XCTAssertEqual(halfway(30, history: night).leftAtReset, 63)
        // A day short of 20 hours is not a full day yet.
        let partial = [QuotaReading(at: now.addingTimeInterval(-19 * 3600), percent: 70, resetAt: reset)]
        XCTAssertEqual(halfway(30, history: partial).leftAtReset, 40)
    }

    func testSpanRoundsToHoursThenDays() {
        XCTAssertEqual(QuotaPace.span(20 * 60).count, 1)
        XCTAssertEqual(QuotaPace.span(8.4 * 3600).count, 8)
        XCTAssertFalse(QuotaPace.span(23 * 3600).days)
        XCTAssertEqual(QuotaPace.span(2.4 * 86_400).count, 2)
        XCTAssertTrue(QuotaPace.span(30 * 3600).days)
    }

    func testHistoryKeepsOneWindowForADay() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pace-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let reset = now.addingTimeInterval(3 * 86_400)
        let history = QuotaHistory(url: url)
        history.record([("Codex|weekly", 80, reset)], now: now)
        history.record([("Codex|weekly", 79, reset)], now: now.addingTimeInterval(300))   // within 10 min
        history.record([("Codex|weekly", 75, reset.addingTimeInterval(60))], now: now.addingTimeInterval(900))
        XCTAssertEqual(history.readings("Codex|weekly", resetAt: reset).map(\.percent), [80, 75])
        // It survives a relaunch.
        XCTAssertEqual(QuotaHistory(url: url).readings("Codex|weekly", resetAt: reset).count, 2)
        // A new window drops the old one's readings; a day on, so does age.
        history.record([("Codex|weekly", 100, reset.addingTimeInterval(week))], now: now.addingTimeInterval(1800))
        XCTAssertEqual(history.readings("Codex|weekly", resetAt: reset), [])
        history.record([("Other|weekly", 50, reset)], now: now.addingTimeInterval(2 * 86_400))
        XCTAssertEqual(history.readings("Codex|weekly", resetAt: reset.addingTimeInterval(week)), [])
    }

    /// Only long windows are kept: no five-hour session, no renewal credit, no extra quota.
    func testHistoryRecordsOnlyLongWindows() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pace-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let reset = now.addingTimeInterval(86_400)
        let status = ServiceStatus(
            name: "Claude", iconName: "claude", sessionResetAt: reset, weeklyResetAt: reset,
            sessionRemainingPercent: 30, weeklyRemainingPercent: 60,
            models: [ModelStatus(name: "Fable", remainingPercent: 70, resetAt: reset),
                     ModelStatus(name: "Gemini", remainingPercent: 20, resetAt: reset, window: .session),
                     ModelStatus(name: "Luna", remainingPercent: 50, resetAt: reset, window: .weekly,
                                 groupLabel: LiveUsageDataSource.codexExtraLimitGroup)],
            isAvailable: true, statusNote: nil)
        let history = QuotaHistory(url: url)
        history.record(status, now: now)
        XCTAssertEqual(history.readings("Claude|weekly", resetAt: reset).map(\.percent), [60])
        XCTAssertEqual(history.readings("Claude|Fable", resetAt: reset).map(\.percent), [70])
        XCTAssertEqual(history.readings("Claude|Gemini", resetAt: reset), [])
        XCTAssertEqual(history.readings("Claude|Luna", resetAt: reset), [])
    }
}
