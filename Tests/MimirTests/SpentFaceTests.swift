import XCTest
@testable import Mimir
import MimirShared

/// The plain faces: a spent window shows its countdown and reset instead of a gauge, a lost login
/// shows what to run instead of numbers.
final class SpentFaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testCountdownIsHoursAndMinutesThenDaysInFront() {
        XCTAssertEqual(SpentFace.countdown(4 * 3600 + 12 * 60, dayUnit: "g"), "04:12")
        XCTAssertEqual(SpentFace.countdown(3 * 86_400 + 23 * 3600 + 12 * 60, dayUnit: "g"), "3g 23:12")
        // Rounded up: a few seconds left must not read as already refilled.
        XCTAssertEqual(SpentFace.countdown(20, dayUnit: "g"), "00:01")
    }

    func testLongWindowWinsOverSession() {
        let week = now.addingTimeInterval(3 * 86_400), hours = now.addingTimeInterval(3600)
        XCTAssertEqual(SpentFace.reset(session: (0, hours), long: (0, week), now: now), week)
        XCTAssertEqual(SpentFace.reset(session: (0, hours), long: (40, week), now: now), hours)
        XCTAssertNil(SpentFace.reset(session: (5, hours), long: (40, week), now: now))
        // A spent window whose reset is past or unknown has nothing to count down to.
        XCTAssertNil(SpentFace.reset(session: (0, now.addingTimeInterval(-60)), long: (0, nil), now: now))
    }

    func testLostLoginReachesTheWidget() {
        let card = ServiceStatus(name: "Claude", iconName: "claude", sessionResetAt: nil, weeklyResetAt: nil,
                                 sessionRemainingPercent: 50, models: [], isAvailable: true, statusNote: nil)
        let lost = card.markedNeedsLogin("run /login")
        XCTAssertTrue(lost.isStale)
        XCTAssertEqual(WidgetBridge.makePayload([lost], generatedAt: now).providers.first?.loginNote, "run /login")
        XCTAssertNil(WidgetBridge.makePayload([card.markedStale("out of date")], generatedAt: now)
            .providers.first?.loginNote)
    }

    /// The line names the spent window: the session, the week, or a long window by its days.
    func testTheTitleNamesTheSpentWindow() {
        let reset = now.addingTimeInterval(3600)
        XCTAssertTrue(SpentFace.longIsSpent((0, reset), now: now))
        XCTAssertFalse(SpentFace.longIsSpent((40, reset), now: now))
        XCTAssertFalse(SpentFace.longIsSpent((0, now.addingTimeInterval(-60)), now: now))
        XCTAssertEqual(SpentFace.title(long: false, days: nil), String(localized: "spent.session"))
        XCTAssertEqual(SpentFace.title(long: true, days: 7), String(localized: "spent.weekly"))
        XCTAssertEqual(SpentFace.title(long: true, days: 30), String(format: String(localized: "spent.days"), 30))
    }
}
