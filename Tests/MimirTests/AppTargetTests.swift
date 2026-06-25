import XCTest
@testable import Mimir

/// `AppTarget` gates which providers can get the "data unavailable — open it" empty state (and a
/// tap target): only those mapping to an openable GUI app. Claude Code and Codex are CLIs / remote
/// APIs with nothing to "open", so they map to nil and `loadSnapshot` never gives them that state —
/// they fall through to the existing last-known/stale behaviour instead.
final class AppTargetTests: XCTestCase {
    func testOnlyGuiAppsMap() {
        XCTAssertNotNil(AppTarget.bundleID(for: "Antigravity"))
        XCTAssertNil(AppTarget.bundleID(for: "Claude"))
        XCTAssertNil(AppTarget.bundleID(for: "Codex"))
        XCTAssertNil(AppTarget.bundleID(for: "Nonexistent"))
    }
}
