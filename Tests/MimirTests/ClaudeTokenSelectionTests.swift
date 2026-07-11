import XCTest
@testable import Mimir

/// `selectClaudeToken` encodes the prompt-free-first sourcing rules: file → Mimir's own (still-valid)
/// cache → a SILENT keychain read (no dialog; works only once Mimir has been granted) → the one-time
/// GRANT keychain read (may show the dialog, so user-action only). The load-bearing checks are the
/// laziness ones: a prompt-free source short-circuits the rest, and the *prompting* keychain is never
/// reached in the background.
final class ClaudeTokenSelectionTests: XCTestCase {
    private typealias Token = LiveUsageDataSource.ClaudeToken
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func token(_ id: String, expiresInSeconds: TimeInterval?) -> Token {
        Token(accessToken: id, expiresAt: expiresInSeconds.map { now.addingTimeInterval($0) })
    }

    /// The file is the top prompt-free source and wins outright — no other source is invoked.
    func testFileWinsAndShortCircuitsOtherSources() {
        var cacheCalled = false, silentCalled = false, keychainCalled = false
        let result = LiveUsageDataSource.selectClaudeToken(
            file: token("file", expiresInSeconds: 60),
            userInitiated: true, now: now,
            mimirCache: { cacheCalled = true; return self.token("cache", expiresInSeconds: 9_999) },
            silentKeychain: { silentCalled = true; return self.token("silent", expiresInSeconds: 9_999) },
            keychain: { keychainCalled = true; return self.token("kc", expiresInSeconds: 9_999) })
        XCTAssertEqual(result?.accessToken, "file")
        XCTAssertFalse(cacheCalled)
        XCTAssertFalse(silentCalled)
        XCTAssertFalse(keychainCalled)
    }

    /// No file, but Mimir's cached token is comfortably valid → use it, and never reach the keychain.
    func testValidCacheUsedWithoutTouchingKeychain() {
        var silentCalled = false, keychainCalled = false
        let result = LiveUsageDataSource.selectClaudeToken(
            file: nil, userInitiated: true, now: now,
            mimirCache: { self.token("cache", expiresInSeconds: 600) },
            silentKeychain: { silentCalled = true; return nil },
            keychain: { keychainCalled = true; return self.token("kc", expiresInSeconds: 9_999) })
        XCTAssertEqual(result?.accessToken, "cache")
        XCTAssertFalse(silentCalled)
        XCTAssertFalse(keychainCalled)
    }

    /// Once granted, the SILENT read supplies a token even in the background — and the prompting
    /// keychain is never reached, so the live card stays fresh without ever popping the dialog.
    func testBackgroundUsesSilentKeychainAndNeverPrompts() {
        var keychainCalled = false
        let result = LiveUsageDataSource.selectClaudeToken(
            file: nil, userInitiated: false, now: now,
            mimirCache: { nil },
            silentKeychain: { self.token("silent", expiresInSeconds: 9_999) },
            keychain: { keychainCalled = true; return self.token("kc", expiresInSeconds: 9_999) })
        XCTAssertEqual(result?.accessToken, "silent")
        XCTAssertFalse(keychainCalled)
    }

    /// THE prompt guarantee: in the background with no file/cache and no silent grant, we return nil
    /// and never invoke the *prompting* keychain — a background tick can't pop the macOS dialog.
    func testBackgroundWithoutGrantReturnsNilAndNeverPrompts() {
        var keychainCalled = false
        let result = LiveUsageDataSource.selectClaudeToken(
            file: nil, userInitiated: false, now: now,
            mimirCache: { nil },
            silentKeychain: { nil },
            keychain: { keychainCalled = true; return self.token("kc", expiresInSeconds: 9_999) })
        XCTAssertNil(result)
        XCTAssertFalse(keychainCalled)
    }

    /// A cached token within 5 minutes of expiry isn't trustworthy (no refresh token to renew it), so
    /// on a user action with no silent grant we fall through to the prompting keychain.
    func testNearExpiryCacheFallsThroughToKeychainWhenUserInitiated() {
        let result = LiveUsageDataSource.selectClaudeToken(
            file: nil, userInitiated: true, now: now,
            mimirCache: { self.token("cache", expiresInSeconds: 299) },
            silentKeychain: { nil },
            keychain: { self.token("kc", expiresInSeconds: 9_999) })
        XCTAssertEqual(result?.accessToken, "kc")
    }

    /// Exactly 300s left is still "near expiry" (the rule is strictly greater than 5 minutes).
    func testExactlyFiveMinutesIsNotFreshEnough() {
        let result = LiveUsageDataSource.selectClaudeToken(
            file: nil, userInitiated: false, now: now,
            mimirCache: { self.token("cache", expiresInSeconds: 300) },
            silentKeychain: { nil },
            keychain: { self.token("kc", expiresInSeconds: 9_999) })
        XCTAssertNil(result)
    }

    /// A cached token with no expiry metadata can't be trusted (we can't tell if it's alive), so it
    /// is skipped.
    func testCacheWithNoExpiryIsSkipped() {
        let result = LiveUsageDataSource.selectClaudeToken(
            file: nil, userInitiated: false, now: now,
            mimirCache: { self.token("cache", expiresInSeconds: nil) },
            silentKeychain: { nil },
            keychain: { self.token("kc", expiresInSeconds: 9_999) })
        XCTAssertNil(result)
    }

    /// A user action (opening Mimir) with no prompt-free source and no silent grant may read the
    /// prompting keychain as the last resort — the one-time grant.
    func testUserInitiatedReadsGrantKeychainAsLastResort() {
        let result = LiveUsageDataSource.selectClaudeToken(
            file: nil, userInitiated: true, now: now,
            mimirCache: { nil },
            silentKeychain: { nil },
            keychain: { self.token("kc", expiresInSeconds: 9_999) })
        XCTAssertEqual(result?.accessToken, "kc")
    }
}
