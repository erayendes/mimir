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

/// Build numbers decide who is offered what, so the two release tracks are pinned here. A beta
/// must sit above the last stable release and below the final it leads to: that ordering is the
/// whole mechanism by which a beta user walks 3.0.0-beta.1 → beta.2 → 3.0.0 while a 2.24 shipped
/// in the meantime is behind them, and never offered.
final class BuildNumberTests: XCTestCase {
    private func build(_ version: String) throws -> Int {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [root.appendingPathComponent("script/build_number.sh").path, version]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Int(text) ?? -1
    }

    func testTheTwoTracksOrderCorrectly() throws {
        let stableNow = try build("2.23")
        let stableNext = try build("2.24")
        let beta1 = try build("3.0.0-beta.1")
        let beta2 = try build("3.0.0-beta.2")
        let final = try build("3.0.0")

        XCTAssertLessThan(stableNow, stableNext)
        XCTAssertLessThan(stableNext, beta1, "a stable release must never look like an update to a beta install")
        XCTAssertLessThan(beta1, beta2)
        XCTAssertLessThan(beta2, final, "the final has to be an update for everyone on a beta")
    }

    func testEveryNumberClearsTheOldScheme() throws {
        // The previous formula topped out around 2_023_000 for 2.23; Sparkle compares these
        // numerically, so nothing may ever come out below what an installed copy already has.
        XCTAssertGreaterThan(try build("2.23"), 2_023_000)
    }

    func testAPreReleaseNumberOutOfRangeIsRefused() throws {
        XCTAssertEqual(try build("3.0.0-beta.0"), -1)
        XCTAssertEqual(try build("3.0.0-beta.1000"), -1)
        XCTAssertEqual(try build("3.0.0-rc"), -1)
    }
}
