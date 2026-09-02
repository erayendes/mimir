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

    func testActiveProviderNamesCoverInUseProvidersOnly() {
        let svcs = [
            ServiceStatus(name: "Claude", iconName: "claude", sessionResetAt: nil, weeklyResetAt: nil,
                          sessionRemainingPercent: 9, weeklyRemainingPercent: 11, models: [],
                          isAvailable: true, statusNote: nil),
            ServiceStatus(name: "Codex", iconName: "codex", sessionResetAt: nil, weeklyResetAt: nil,
                          models: [], isAvailable: false, statusNote: nil, isStale: true),
            ServiceStatus(name: "Antigravity", iconName: "antigravity", sessionResetAt: nil,
                          weeklyResetAt: nil, models: [], isAvailable: false, statusNote: nil),
        ]
        let names = Telemetry.activeProviderNames(from: svcs)
        XCTAssertEqual(names, ["Claude", "Codex"])  // stale still counts as in-use
        XCTAssertFalse(names.contains("Antigravity"))
        // No quota value may leak into the payload.
        XCTAssertFalse(names.contains("9"))
        XCTAssertFalse(names.contains("11"))
    }

    func testWidgetParametersCountFamilies() {
        // Only the supported families (small, medium) are reported; others are ignored.
        let p = Telemetry.widgetParameters(families: ["systemSmall", "systemSmall", "systemMedium", "systemLarge"])
        XCTAssertEqual(p["small"], "2")
        XCTAssertEqual(p["medium"], "1")
        XCTAssertNil(p["large"])
        XCTAssertNil(p["extraLarge"])
    }
}
