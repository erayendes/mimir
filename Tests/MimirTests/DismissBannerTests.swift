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

/// Dismissing the banner must hide the service's menu-bar dots too. A grey dot with no notice
/// explaining it is indistinguishable from a bug.
extension DismissBannerTests {
    private func downService(_ name: String) -> ServiceStatus {
        ServiceStatus(name: name, iconName: name.lowercased(),
                      sessionResetAt: nil, weeklyResetAt: nil,
                      sessionRemainingPercent: 40, weeklyRemainingPercent: 50,
                      models: [], isAvailable: false, statusNote: nil,
                      isStale: true, dataUnavailable: true)
    }

    func testDismissedServiceLosesItsMenuBarDots() {
        let services = [downService("Antigravity"), service("Codex", down: false)]
        XCTAssertEqual(menuBarDots(from: services).count, 2)                       // both dotted
        let kept = menuBarDots(from: services, dismissed: ["Antigravity"])
        XCTAssertEqual(kept.count, 1)                                             // Antigravity gone
    }

    /// A dismissal only hides a service that is actually down — it can't blank a healthy one.
    func testDismissalDoesNotHideAHealthyService() {
        let services = [service("Codex", down: false)]
        XCTAssertEqual(menuBarDots(from: services, dismissed: ["Codex"]).count, 1)
    }
}
