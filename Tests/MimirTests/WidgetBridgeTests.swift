import XCTest
@testable import Mimir
import MimirShared

/// `WidgetBridge.makePayload` flattens the app's `[ServiceStatus]` into the widget DTO. The tricky
/// part is that 5h/7d windows are encoded differently per provider: Antigravity tags each model row
/// with `.session`/`.weekly`, while Claude/Codex carry the account-level percents and keep `models`
/// for extra 7-day rows (Claude's "Sonnet", window `nil`). These tests pin that mapping.
final class WidgetBridgeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testClaudeMapsAccountWindowsPlusExtraWeeklyRow() {
        let claude = ServiceStatus(
            name: "Claude", iconName: "claude",
            sessionResetAt: now.addingTimeInterval(600), weeklyResetAt: now.addingTimeInterval(86_400),
            sessionRemainingPercent: 9, weeklyRemainingPercent: 11,
            models: [ModelStatus(name: "Sonnet", remainingPercent: 82, resetAt: now, window: nil),
                     ModelStatus(name: "Billing", remainingPercent: 0, resetAt: nil, valueText: "4.500")],
            isAvailable: true, statusNote: nil)

        let p = WidgetBridge.makePayload([claude], generatedAt: now).providers.first!
        XCTAssertEqual(p.fiveHour.map(\.label), ["Claude"])
        XCTAssertEqual(p.fiveHour.first?.percent, 9)
        // 7d = account weekly ("Claude") + the non-credit weekly model ("Sonnet"); Billing is excluded.
        XCTAssertEqual(p.sevenDay.map(\.label), ["Claude", "Sonnet"])
        XCTAssertEqual(p.sevenDay.map(\.percent), [11, 82])
        XCTAssertEqual(p.credits, "4.500")   // pulled from the valueText row
    }

    func testAntigravitySplitsSessionAndWeeklyModels() {
        let ag = ServiceStatus(
            name: "Antigravity", iconName: "antigravity",
            sessionResetAt: now, weeklyResetAt: nil,
            sessionRemainingPercent: nil, weeklyRemainingPercent: nil,
            models: [ModelStatus(name: "Gemini", remainingPercent: 100, resetAt: now, window: .session),
                     ModelStatus(name: "Claude/GPT", remainingPercent: 44, resetAt: now, window: .session),
                     ModelStatus(name: "Gemini", remainingPercent: 88, resetAt: now, window: .weekly),
                     ModelStatus(name: "Claude/GPT", remainingPercent: 41, resetAt: now, window: .weekly),
                     ModelStatus(name: "Google One credits", remainingPercent: 0, resetAt: nil, valueText: "920")],
            isAvailable: true, statusNote: nil)

        let p = WidgetBridge.makePayload([ag], generatedAt: now).providers.first!
        XCTAssertEqual(p.fiveHour.map(\.label), ["Gemini", "Claude/GPT"])
        XCTAssertEqual(p.sevenDay.map(\.label), ["Gemini", "Claude/GPT"])
        XCTAssertEqual(p.sevenDay.map(\.percent), [88, 41])
        XCTAssertEqual(p.credits, "920")
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
}
