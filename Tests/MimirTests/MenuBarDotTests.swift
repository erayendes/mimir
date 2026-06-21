import XCTest
@testable import Mimir

/// `menuBarDots` emits one dot per **5-hour session window** the popover shows, in popover order
/// (Claude, Codex, then each Antigravity family). A multi-family service like Antigravity expands
/// to one dot per family instead of collapsing to the worst — so Gemini and Claude/GPT show
/// separately. A missing 5h reading is `nil` (painted grey), never a dropped dot.
/// `menuBarColumnCount` is the grid rule: 1 column up to 3 dots, 2 columns from 4 on.
final class MenuBarDotTests: XCTestCase {
    private func service(
        _ name: String,
        session: Int? = nil,
        weekly: Int? = nil,
        models: [ModelStatus] = [],
        isAvailable: Bool = true,
        isStale: Bool = false
    ) -> ServiceStatus {
        ServiceStatus(
            name: name, iconName: name.lowercased(),
            sessionResetAt: nil, weeklyResetAt: nil,
            sessionRemainingPercent: session, weeklyRemainingPercent: weekly,
            models: models, isAvailable: isAvailable, statusNote: nil, isStale: isStale)
    }

    private func agSession(_ name: String, _ pct: Int) -> ModelStatus {
        ModelStatus(name: name, remainingPercent: pct, resetAt: nil, window: .session)
    }

    /// THE point of this change: Antigravity's two 5h families become two separate dots
    /// (Gemini fine, Claude/GPT exhausted), not one collapsed "worst" dot.
    func testAntigravityExpandsToOneDotPerSessionFamily() {
        let services = [
            service("Claude", session: 88),
            service("Codex", session: 99),
            service("Antigravity", models: [agSession("Gemini", 100), agSession("Claude/GPT", 0)])
        ]
        // Claude, Codex, then Gemini, Claude/GPT — four dots, in popover order.
        XCTAssertEqual(menuBarDots(from: services), [88, 99, 100, 0])
    }

    /// Family order within Antigravity is preserved (model order = popover order).
    func testAntigravityFamilyOrderPreserved() {
        let ag = service("Antigravity", models: [agSession("Gemini", 30), agSession("Claude/GPT", 70)])
        XCTAssertEqual(menuBarDots(from: [ag]), [30, 70])
    }

    /// Antigravity visible but with no 5h session rows (only weekly) → a single grey placeholder.
    func testAntigravityWithNoSessionIsOneGreyDot() {
        let ag = service("Antigravity", models: [
            ModelStatus(name: "Gemini", remainingPercent: 30, resetAt: nil, window: .weekly)
        ])
        XCTAssertEqual(menuBarDots(from: [ag]), [nil])
    }

    /// Claude/Codex carry a single account-level session → one dot each, using session not weekly.
    func testSingleSessionServicesAreOneDotEach() {
        XCTAssertEqual(menuBarDots(from: [service("Codex", session: 40, weekly: 90)]), [40])
    }

    /// Claude with only a weekly reading (5h reset) → one grey dot, not dropped.
    func testWeeklyOnlyServiceIsOneGreyDot() {
        XCTAssertEqual(menuBarDots(from: [service("Claude", session: nil, weekly: 95)]), [nil])
    }

    /// A service with no data at all (hidden fallback card) produces no dot, matching the popover.
    func testUndetectedServiceIsOmittedEntirely() {
        XCTAssertEqual(menuBarDots(from: [service("Claude", session: nil, weekly: nil, isAvailable: false)]), [])
    }

    /// A stale snapshot is shown (dimmed) by the popover, so it keeps its dot too.
    func testStaleServiceStillGetsADot() {
        let stale = service("Codex", session: 50, weekly: 70, isAvailable: false, isStale: true)
        XCTAssertEqual(menuBarDots(from: [stale]), [50])
    }

    /// Order matches the popover (Claude, Codex, Antigravity) regardless of input order.
    func testOrderingMatchesPopover() {
        let services = [
            service("Codex", session: 30),
            service("Antigravity", models: [agSession("Gemini", 10)]),
            service("Claude", session: 20)
        ]
        XCTAssertEqual(menuBarDots(from: services), [20, 30, 10])
    }

    /// The grid rule the user specified: 1·2·3 dots stay a single column, 4 becomes 2×2, and
    /// 2 columns keep filling beyond that.
    func testColumnCountRule() {
        XCTAssertEqual(menuBarColumnCount(for: 1), 1)
        XCTAssertEqual(menuBarColumnCount(for: 2), 1)
        XCTAssertEqual(menuBarColumnCount(for: 3), 1)
        XCTAssertEqual(menuBarColumnCount(for: 4), 2)
        XCTAssertEqual(menuBarColumnCount(for: 5), 2)
        XCTAssertEqual(menuBarColumnCount(for: 6), 2)
    }
}
