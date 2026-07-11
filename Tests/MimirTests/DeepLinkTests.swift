import XCTest
@testable import Mimir

/// `DeepLink.action` decides what a tapped `mimir://open?app=<provider>` widget link does: launch a
/// provider that has an openable GUI app (Antigravity), or bring Mimir up for a user-initiated
/// refresh for CLIs/APIs with nothing to open (Claude, Codex) — the only way to renew their token.
final class DeepLinkTests: XCTestCase {
    func testProviderWithAppOpensThatApp() {
        XCTAssertEqual(DeepLink.action(forApp: "Antigravity"), .openProvider("Antigravity"))
    }

    func testCLIProvidersRefreshSelf() {
        XCTAssertEqual(DeepLink.action(forApp: "Claude"), .openSelfAndRefresh)
        XCTAssertEqual(DeepLink.action(forApp: "Codex"), .openSelfAndRefresh)
    }

    func testUnknownProviderDefaultsToRefreshSelf() {
        XCTAssertEqual(DeepLink.action(forApp: "Nope"), .openSelfAndRefresh)
    }
}
