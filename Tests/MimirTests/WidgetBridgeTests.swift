import XCTest
@testable import Mimir
import MimirShared

/// `WidgetBridge.makePayload` flattens the app's `[ServiceStatus]` into the widget DTO's 5-hour
/// windows: Antigravity tags its model rows with `.session`, while Claude/Codex carry the
/// account-level session percent. These tests pin that mapping.
final class WidgetBridgeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testClaudeFiveHourFromAccountSession() {
        let claude = ServiceStatus(
            name: "Claude", iconName: "claude",
            sessionResetAt: now.addingTimeInterval(600), weeklyResetAt: now.addingTimeInterval(86_400),
            sessionRemainingPercent: 9, weeklyRemainingPercent: 11,
            models: [ModelStatus(name: "Sonnet", remainingPercent: 82, resetAt: now, window: nil)],
            isAvailable: true, statusNote: nil)

        let p = WidgetBridge.makePayload([claude], generatedAt: now).providers.first!
        // 5h is the account session percent; non-session models (Sonnet) don't pollute it.
        XCTAssertEqual(p.fiveHour.map(\.label), ["Claude"])
        XCTAssertEqual(p.fiveHour.first?.percent, 9)
        // The account weekly is carried alongside the session, gating the lockout/7g line.
        XCTAssertEqual(p.fiveHour.first?.weeklyPercent, 11)
        XCTAssertEqual(p.fiveHour.first?.weeklyResetAt, now.addingTimeInterval(86_400))
    }

    func testAntigravityFiveHourFromSessionModels() {
        let ag = ServiceStatus(
            name: "Antigravity", iconName: "antigravity",
            sessionResetAt: now, weeklyResetAt: nil,
            sessionRemainingPercent: nil, weeklyRemainingPercent: nil,
            models: [ModelStatus(name: "Gemini", remainingPercent: 100, resetAt: now, window: .session),
                     ModelStatus(name: "Claude/GPT", remainingPercent: 44, resetAt: now, window: .session),
                     ModelStatus(name: "Gemini", remainingPercent: 88, resetAt: now, window: .weekly)],
            isAvailable: true, statusNote: nil)

        let p = WidgetBridge.makePayload([ag], generatedAt: now).providers.first!
        // Only `.session` rows become 5h windows; `.weekly` rows are excluded.
        XCTAssertEqual(p.fiveHour.map(\.label), ["Gemini", "Claude/GPT"])
        XCTAssertEqual(p.fiveHour.map(\.percent), [100, 44])
        // Each session is paired to its own weekly by name: Gemini → 88; Claude/GPT has no weekly → nil.
        XCTAssertEqual(p.fiveHour.map(\.weeklyPercent), [88, nil])
    }

    func testOrderFollowsServiceDisplayOrderAndStaleCounts() {
        let codex = ServiceStatus(name: "Codex", iconName: "codex", sessionResetAt: now, weeklyResetAt: now,
                                  sessionRemainingPercent: 99, weeklyRemainingPercent: 71, models: [],
                                  isAvailable: true, statusNote: nil)
        let claude = ServiceStatus(name: "Claude", iconName: "claude", sessionResetAt: now, weeklyResetAt: now,
                                   sessionRemainingPercent: 9, weeklyRemainingPercent: 11, models: [],
                                   isAvailable: false, statusNote: nil, isStale: true)
        // Passed Codex-first, but display order is Claude, Codex, Antigravity.
        let providers = WidgetBridge.makePayload([codex, claude], generatedAt: now).providers
        XCTAssertEqual(providers.map(\.name), ["Claude", "Codex"])
        XCTAssertTrue(providers[0].isAvailable)   // stale still surfaces (matches popover/menu-bar rule)
    }

    /// The reload guard skips work when nothing moved: identical services yield Equatable-equal
    /// `providers` (despite a different generatedAt), and a percent change breaks that equality.
    func testProvidersEqualityDrivesReloadGuard() {
        let svc = { (pct: Int) in
            ServiceStatus(name: "Claude", iconName: "claude", sessionResetAt: self.now, weeklyResetAt: self.now,
                          sessionRemainingPercent: pct, weeklyRemainingPercent: 50, models: [],
                          isAvailable: true, statusNote: nil)
        }
        let a = WidgetBridge.makePayload([svc(40)], generatedAt: now).providers
        let b = WidgetBridge.makePayload([svc(40)], generatedAt: now.addingTimeInterval(60)).providers
        let c = WidgetBridge.makePayload([svc(41)], generatedAt: now).providers
        XCTAssertEqual(a, b)      // same data, later timestamp → no reload
        XCTAssertNotEqual(a, c)   // percent moved → reload
    }
}
