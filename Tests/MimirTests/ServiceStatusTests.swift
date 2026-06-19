import XCTest
@testable import Mimir

/// The `with*` copy helpers use a double-optional pattern (`.some(nil)` clears, `nil` keeps),
/// which is easy to get subtly wrong — pin the semantics down.
final class ServiceStatusTests: XCTestCase {
    private func base() -> ServiceStatus {
        ServiceStatus(
            name: "Claude",
            iconName: "claude",
            sessionResetAt: nil,
            weeklyResetAt: nil,
            sessionRemainingPercent: 80,
            weeklyRemainingPercent: 60,
            models: [],
            isAvailable: true,
            statusNote: "original",
            infoText: "info",
            cooldownHint: nil
        )
    }

    func testWithStatusNoteOverwrites() {
        let s = base().withStatusNote("changed")
        XCTAssertEqual(s.statusNote, "changed")
        // Unrelated fields preserved.
        XCTAssertEqual(s.name, "Claude")
        XCTAssertEqual(s.sessionRemainingPercent, 80)
        XCTAssertEqual(s.infoText, "info")
    }

    func testWithStatusNoteCanClear() {
        XCTAssertNil(base().withStatusNote(nil).statusNote)
    }

    func testWithInfoTextPreservesStatusNote() {
        let s = base().withStatusNote("kept").withInfoText("newinfo")
        XCTAssertEqual(s.statusNote, "kept")
        XCTAssertEqual(s.infoText, "newinfo")
    }

    func testWithCooldownHint() {
        XCTAssertEqual(base().withCooldownHint(900).cooldownHint, 900)
        XCTAssertEqual(base().withCooldownHint(0).cooldownHint, 0)
        XCTAssertNil(base().withCooldownHint(nil).cooldownHint)
    }
}
