import XCTest
@testable import Mimir

/// Tests the unit-injectable core so the numeric breakdown is verified without depending
/// on the app's localized bundle (which isn't loaded in the test runner).
final class TimeFormatterTests: XCTestCase {
    private func fmt(_ seconds: TimeInterval) -> String {
        TimeFormatter.duration(from: seconds, day: "d", hour: "h", minute: "m")
    }

    func testSubMinuteFloorsToOneMinute() {
        XCTAssertEqual(fmt(0), "1m")
        XCTAssertEqual(fmt(59), "1m")
        XCTAssertEqual(fmt(-100), "1m")   // negatives clamp to 0 → "1m"
    }

    func testMinutes() {
        XCTAssertEqual(fmt(60), "1m")
        XCTAssertEqual(fmt(125), "2m")
    }

    func testHours() {
        XCTAssertEqual(fmt(3600), "1h")
        XCTAssertEqual(fmt(3660), "1h 1m")
        XCTAssertEqual(fmt(7380), "2h 3m")
    }

    func testDays() {
        XCTAssertEqual(fmt(86_400), "1d")
        XCTAssertEqual(fmt(90_000), "1d 1h")          // 25h
        XCTAssertEqual(fmt(88_200), "1d")             // 1d 0h 30m → minutes dropped when days>0
        XCTAssertEqual(fmt(180_000), "2d 2h")
    }

    func testCustomUnitsAreApplied() {
        XCTAssertEqual(TimeFormatter.duration(from: 90_000, day: "g", hour: "s", minute: "d"), "1g 1s")
    }
}
