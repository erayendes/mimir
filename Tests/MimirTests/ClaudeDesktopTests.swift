import XCTest
@testable import Mimir

/// The claude.ai desktop-session path: org selection + the cookie-decryption format guards. The AES
/// round-trip itself needs the machine's real Safe Storage key, so it's exercised live in the app, not
/// here; these pin down the pure decision/guard logic that would otherwise fail silently.
final class ClaudeDesktopTests: XCTestCase {
    private let ds = LiveUsageDataSource()

    func testOrgSelectionPrefersChatCapabilityThenFirst() {
        let orgs: [[String: Any]] = [
            ["uuid": "a", "capabilities": ["billing"]],
            ["uuid": "b", "capabilities": ["chat", "claude_pro"]],
        ]
        XCTAssertEqual(LiveUsageDataSource.selectClaudeOrgUUID(orgs), "b")
        // No capability match → first org.
        XCTAssertEqual(LiveUsageDataSource.selectClaudeOrgUUID([["uuid": "x"], ["uuid": "y"]]), "x")
        XCTAssertNil(LiveUsageDataSource.selectClaudeOrgUUID([]))
    }

    func testDecryptRejectsNonChromiumBlobs() {
        // Missing/short → nil, wrong tag → nil (never crashes on junk cookie bytes).
        XCTAssertNil(LiveUsageDataSource.decryptChromiumCookie(Data(), safeStoragePassword: "pw"))
        XCTAssertNil(LiveUsageDataSource.decryptChromiumCookie(Data("v10".utf8), safeStoragePassword: "pw"))
        XCTAssertNil(LiveUsageDataSource.decryptChromiumCookie(Data("xx0abcdefghijklmnop".utf8), safeStoragePassword: "pw"))
        // v10 tag but ciphertext not a whole number of AES blocks → nil, not a crash.
        XCTAssertNil(LiveUsageDataSource.decryptChromiumCookie(Data("v10short".utf8), safeStoragePassword: "pw"))
    }
}
