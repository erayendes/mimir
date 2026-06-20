import XCTest
@testable import Mimir

/// `menuBarDots` must emit exactly one dot per service the popover shows, so the menu-bar dot
/// count can never drift below the visible card count (the "3 cards, 2 dots" regression). A dot
/// reflects the service's 5-hour (session) reading; when that reading is missing the entry is
/// `nil`, which the menu bar paints grey ("no data yet") rather than dropping the dot.
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

    /// The reported bug: Claude has only a weekly reading (its 5h window reset), Codex and
    /// Antigravity have fresh sessions. All three are visible → all three get an entry; Claude's
    /// is `nil` (grey), not dropped.
    func testWeeklyOnlyServiceShowsAGreyDotNotDropped() {
        let services = [
            service("Claude", session: nil, weekly: 95),
            service("Codex", session: 99, weekly: 99),
            service("Antigravity", models: [
                ModelStatus(name: "Gemini", remainingPercent: 100, resetAt: nil, window: .session),
                ModelStatus(name: "Claude/GPT", remainingPercent: 100, resetAt: nil, window: .session)
            ])
        ]
        // Three entries (count matches the popover), in the popover's order
        // (Antigravity, Claude, Codex); Claude is grey (nil), never the weekly 95.
        XCTAssertEqual(menuBarDots(from: services), [100, nil, 99])
    }

    /// The dot reflects the 5-hour session, never the weekly window, even when both exist.
    func testDotUsesSessionNotWeekly() {
        XCTAssertEqual(menuBarDots(from: [service("Codex", session: 40, weekly: 90)]), [40])
    }

    /// Antigravity takes the most constrained 5h session row; weekly-only rows give grey (nil).
    func testAntigravitySessionMinAndWeeklyOnlyIsGrey() {
        let withSessions = service("Antigravity", models: [
            ModelStatus(name: "Gemini", remainingPercent: 70, resetAt: nil, window: .session),
            ModelStatus(name: "Claude/GPT", remainingPercent: 30, resetAt: nil, window: .session)
        ])
        XCTAssertEqual(menuBarDots(from: [withSessions]), [30])

        let weeklyOnly = service("Antigravity", models: [
            ModelStatus(name: "Gemini", remainingPercent: 30, resetAt: nil, window: .weekly)
        ])
        XCTAssertEqual(menuBarDots(from: [weeklyOnly]), [nil])
    }

    /// A service with no data at all (hidden fallback card) produces no entry, matching the
    /// popover, which also hides it — so we don't show grey dots for tools that aren't in use.
    func testUndetectedServiceIsOmittedEntirely() {
        let dead = service("Claude", session: nil, weekly: nil, isAvailable: false)
        XCTAssertEqual(menuBarDots(from: [dead]), [])
    }

    /// A stale snapshot is shown (dimmed) by the popover, so it keeps its dot too.
    func testStaleServiceStillGetsADot() {
        let stale = service("Codex", session: 50, weekly: 70, isAvailable: false, isStale: true)
        XCTAssertEqual(menuBarDots(from: [stale]), [50])
    }

    /// Fixed top→bottom ordering matches the popover's (Antigravity, Claude, Codex)
    /// regardless of input order, so dot N lines up with card N.
    func testOrderingMatchesPopoverAntigravityClaudeCodex() {
        let services = [
            service("Codex", session: 30),
            service("Antigravity", models: [ModelStatus(name: "Gemini", remainingPercent: 10, resetAt: nil, window: .session)]),
            service("Claude", session: 20)
        ]
        XCTAssertEqual(menuBarDots(from: services), [10, 20, 30])
    }
}
