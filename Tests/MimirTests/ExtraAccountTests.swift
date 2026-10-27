import XCTest
@testable import Mimir

/// Second CLI logins (`~/.claude-work`, `~/.codex-work`) become their own cards.
final class ExtraAccountTests: XCTestCase {
    func testFindsSuffixedDirsHoldingTheMarker() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        for dir in [".codex", ".codex-work", ".codex-empty", ".codexfoo"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(dir),
                                                    withIntermediateDirectories: true)
        }
        for dir in [".codex", ".codex-work", ".codexfoo"] {
            FileManager.default.createFile(atPath: home.appendingPathComponent("\(dir)/auth.json").path, contents: Data())
        }

        let found = ExtraAccount.find(base: ".codex", title: "Codex", marker: "auth.json", home: home)
        XCTAssertEqual(found.map(\.name), ["Codex Work"])   // no marker, no dash, main dir: all skipped
        XCTAssertEqual(found.first?.dir.lastPathComponent, ".codex-work")
    }

    func testSecondAccountSitsAfterItsProvider() {
        func card(_ name: String) -> ServiceStatus {
            ServiceStatus(name: name, iconName: "", sessionResetAt: nil, weeklyResetAt: nil,
                          models: [], isAvailable: true, statusNote: nil)
        }
        let sorted = [card("Antigravity"), card("Codex Work"), card("Claude Work"), card("Codex"), card("Claude")]
            .sortedByDisplayOrder().map(\.name)
        XCTAssertEqual(sorted, ["Claude", "Claude Work", "Codex", "Codex Work", "Antigravity"])
    }

    func testSecondAccountReachesTheWidget() {
        let work = ServiceStatus(name: "Codex Work", iconName: "codex", sessionResetAt: nil, weeklyResetAt: nil,
                                 sessionRemainingPercent: 40, models: [], isAvailable: true, statusNote: nil)
        let main = ServiceStatus(name: "Codex", iconName: "codex", sessionResetAt: nil, weeklyResetAt: nil,
                                 sessionRemainingPercent: 80, models: [], isAvailable: true, statusNote: nil)
        let payload = WidgetBridge.makePayload([work, main], generatedAt: Date())
        XCTAssertEqual(payload.providers.flatMap { $0.fiveHour.map(\.label) }, ["Codex", "Codex Work"])
    }

    func testMainClaudeCardSkipsASecondLoginsKeychainItem() {
        let work = LiveUsageDataSource.claudeKeychainService(forConfigDir: "/Users/me/.claude-work")
        XCTAssertTrue(work.hasPrefix("Claude Code-credentials-"))
        XCTAssertEqual(work.count, "Claude Code-credentials-".count + 8)

        let ordered = LiveUsageDataSource.claudeKeychainServicesOrdered([
            ("Claude Code-credentials", Date(timeIntervalSince1970: 1_000)),
            (work, Date(timeIntervalSince1970: 2_000)),   // newer, but it's the other account's
        ], excluding: [work])
        XCTAssertEqual(ordered, ["Claude Code-credentials"])
    }
}
