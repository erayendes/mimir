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

    func testProviderParametersAreCategoricalOnly() {
        let svcs = [
            ServiceStatus(name: "Claude", iconName: "claude", sessionResetAt: nil, weeklyResetAt: nil,
                          sessionRemainingPercent: 9, weeklyRemainingPercent: 11, models: [],
                          isAvailable: true, statusNote: nil),
            ServiceStatus(name: "Codex", iconName: "codex", sessionResetAt: nil, weeklyResetAt: nil,
                          models: [], isAvailable: false, statusNote: nil, isStale: true),
            ServiceStatus(name: "Antigravity", iconName: "antigravity", sessionResetAt: nil,
                          weeklyResetAt: nil, models: [], isAvailable: false, statusNote: nil),
        ]
        let p = Telemetry.providerParameters(from: svcs)
        XCTAssertEqual(p["claude"], "true")
        XCTAssertEqual(p["codex"], "true")          // stale still counts as in-use
        XCTAssertEqual(p["antigravity"], "false")
        // No quota value may leak into the payload.
        XCTAssertFalse(p.values.contains("9"))
        XCTAssertFalse(p.values.contains("11"))
    }

    func testWidgetParametersCountFamilies() {
        let p = Telemetry.widgetParameters(families: ["systemSmall", "systemSmall", "systemLarge"])
        XCTAssertEqual(p["small"], "2")
        XCTAssertEqual(p["large"], "1")
        XCTAssertEqual(p["medium"], "0")
        XCTAssertEqual(p["extraLarge"], "0")
    }
}
