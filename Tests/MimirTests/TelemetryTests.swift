import XCTest
@testable import Mimir

/// Telemetry is privacy-first: the pure `shouldSend` gate decides whether anything is ever
/// transmitted (dev builds and opted-out users never send), and the parameter producers must
/// emit categorical values only — never a quota percentage, credit, or any other raw value.
final class TelemetryTests: XCTestCase {
    func testShouldSendOnlyWhenEnabledAndNotDev() {
        XCTAssertTrue(Telemetry.shouldSend(isDev: false, enabled: true))
        XCTAssertFalse(Telemetry.shouldSend(isDev: true, enabled: true))    // dev never sends
        XCTAssertFalse(Telemetry.shouldSend(isDev: false, enabled: false))  // opt-out
        XCTAssertFalse(Telemetry.shouldSend(isDev: true, enabled: false))
    }
}
