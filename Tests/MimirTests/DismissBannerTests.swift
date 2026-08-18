import XCTest
@testable import Mimir

/// The "couldn't fetch" banner can be dismissed per service. The dismissal must survive a relaunch
/// but must NOT outlive the outage — otherwise one click would permanently mute a provider that is
/// genuinely broken, which is the failure mode this test exists to prevent.
@MainActor
final class DismissBannerTests: XCTestCase {
    private let key = "popover.dismissedUnavailable"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    private func service(_ name: String, down: Bool) -> ServiceStatus {
        ServiceStatus(name: name, iconName: name.lowercased(),
                      sessionResetAt: nil, weeklyResetAt: nil,
                      models: [], isAvailable: !down, statusNote: nil,
                      isStale: down, dataUnavailable: down)
    }

    func testDismissIsRememberedAndPersisted() {
        let store = UsageStore()
        store.dismissUnavailable("Antigravity")
        XCTAssertTrue(store.dismissedUnavailable.contains("Antigravity"))
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: key), ["Antigravity"])

        // A fresh store reads it back — the banner stays hidden across a relaunch.
        XCTAssertTrue(UsageStore().dismissedUnavailable.contains("Antigravity"))
    }

    /// The important one: once the service reports data again the dismissal is dropped, so the NEXT
    /// outage is announced instead of being silently swallowed.
    func testDismissalIsForgottenOnceTheServiceRecovers() {
        let store = UsageStore()
        store.dismissUnavailable("Antigravity")

        store.forgetRecoveredDismissals([service("Antigravity", down: false)])
        XCTAssertFalse(store.dismissedUnavailable.contains("Antigravity"))
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: key), [])
    }

    /// While the service is still down the dismissal stands — the banner doesn't pop back on the
    /// next 60-second refresh.
    func testDismissalSurvivesWhileStillDown() {
        let store = UsageStore()
        store.dismissUnavailable("Antigravity")

        store.forgetRecoveredDismissals([service("Antigravity", down: true)])
        XCTAssertTrue(store.dismissedUnavailable.contains("Antigravity"))
    }

    /// Dismissals are per service: silencing one leaves another provider's banner alone.
    func testDismissalIsPerService() {
        let store = UsageStore()
        store.dismissUnavailable("Antigravity")
        store.dismissUnavailable("Codex")

        store.forgetRecoveredDismissals([
            service("Antigravity", down: true), service("Codex", down: false),
        ])
        XCTAssertEqual(store.dismissedUnavailable, ["Antigravity"])
    }
}
