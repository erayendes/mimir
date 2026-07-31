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

    /// Codex since OpenAI's July 2026 5-hour removal: no session reading, only a weekly one. The widget
    /// falls back to the weekly quota as the headline metric (tagged `isWeekly`) instead of dropping the
    /// row, so the "7g" pill and real binding limit still render.
    func testCodexWeeklyFallbackWhenNoFiveHour() {
        let codex = ServiceStatus(
            name: "Codex", iconName: "codex",
            sessionResetAt: nil, weeklyResetAt: now.addingTimeInterval(86_400),
            sessionRemainingPercent: nil, weeklyRemainingPercent: 72,
            models: [], isAvailable: true, statusNote: nil)

        let p = WidgetBridge.makePayload([codex], generatedAt: now).providers.first!
        XCTAssertEqual(p.fiveHour.count, 1)
        let m = p.fiveHour.first!
        XCTAssertTrue(m.isWeekly)                                   // labelled as the weekly window
        XCTAssertEqual(m.percent, 72)                              // headline = weekly percent
        XCTAssertEqual(m.resetAt, now.addingTimeInterval(86_400))  // and the weekly reset
        XCTAssertEqual(m.weeklyPercent, 72)
    }

    /// A service with neither a session nor a weekly reading produces no metric (dropped, not a zero row).
    func testNoWindowsProducesNoMetric() {
        let codex = ServiceStatus(
            name: "Codex", iconName: "codex", sessionResetAt: nil, weeklyResetAt: nil,
            sessionRemainingPercent: nil, weeklyRemainingPercent: nil,
            models: [], isAvailable: true, statusNote: nil)
        let p = WidgetBridge.makePayload([codex], generatedAt: now).providers.first!
        XCTAssertTrue(p.fiveHour.isEmpty)
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

    /// The reload throttle: structural changes (availability/unavailable flip) poke immediately;
    /// %-only drift waits for the throttle so WidgetKit's reload budget isn't burned on every tick.
    func testShouldReloadStructuralBypassesThrottle() {
        let t = WidgetBridge.reloadThrottle
        func prov(_ pct: Int, available: Bool = true, unavailable: Bool = false) -> [ProviderPayload] {
            [ProviderPayload(name: "Claude", iconName: "claude", isAvailable: available,
                             fiveHour: [WindowMetric(label: "Claude", percent: pct, resetAt: now)],
                             unavailable: unavailable)]
        }
        // First poke ever (no lastReload) → reload.
        XCTAssertTrue(WidgetBridge.shouldReload(previous: nil, next: prov(50), lastReload: nil, now: now, throttle: t))
        // %-only change inside the throttle window → wait.
        XCTAssertFalse(WidgetBridge.shouldReload(previous: prov(50), next: prov(49),
                                                 lastReload: now, now: now.addingTimeInterval(60), throttle: t))
        // %-only change after the throttle elapsed → reload.
        XCTAssertTrue(WidgetBridge.shouldReload(previous: prov(50), next: prov(49),
                                                lastReload: now, now: now.addingTimeInterval(t + 1), throttle: t))
        // Availability flip inside the window → reload now (structural).
        XCTAssertTrue(WidgetBridge.shouldReload(previous: prov(50), next: prov(50, available: false),
                                                lastReload: now, now: now.addingTimeInterval(60), throttle: t))
        // Unavailable flip inside the window → reload now (structural).
        XCTAssertTrue(WidgetBridge.shouldReload(previous: prov(50), next: prov(50, unavailable: true),
                                                lastReload: now, now: now.addingTimeInterval(60), throttle: t))
    }
}
