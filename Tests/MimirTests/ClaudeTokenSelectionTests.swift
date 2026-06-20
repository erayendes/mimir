import XCTest
@testable import Mimir

/// `selectClaudeToken` encodes the prompt-free-first sourcing rules behind the background keychain
/// fix: file → Mimir's own (still-valid) cache → Claude Code's keychain (user action only). The
/// laziness checks are the load-bearing ones — they prove the prompting source (the keychain) is
/// never reached when a prompt-free source already has a usable token.
final class ClaudeTokenSelectionTests: XCTestCase {
    private typealias Token = LiveUsageDataSource.ClaudeToken
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func token(_ id: String, expiresInSeconds: TimeInterval?) -> Token {
        Token(accessToken: id, expiresAt: expiresInSeconds.map { now.addingTimeInterval($0) })
    }

    /// The file is the top prompt-free source and wins outright — and neither the cache nor the
    /// keychain closure is even invoked (so a file-backed login never touches the keychain).
    func testFileWinsAndShortCircuitsOtherSources() {
        var cacheCalled = false, keychainCalled = false
        let result = LiveUsageDataSource.selectClaudeToken(
            file: token("file", expiresInSeconds: 60),
            userInitiated: true, now: now,
            mimirCache: { cacheCalled = true; return self.token("cache", expiresInSeconds: 9_999) },
            keychain: { keychainCalled = true; return self.token("kc", expiresInSeconds: 9_999) })
        XCTAssertEqual(result?.accessToken, "file")
        XCTAssertFalse(cacheCalled)
        XCTAssertFalse(keychainCalled)
    }

    /// No file, but Mimir's cached token is comfortably valid → use it, and never reach the keychain.
    func testValidCacheUsedWithoutTouchingKeychain() {
        var keychainCalled = false
        let result = LiveUsageDataSource.selectClaudeToken(
            file: nil, userInitiated: true, now: now,
            mimirCache: { self.token("cache", expiresInSeconds: 600) },
            keychain: { keychainCalled = true; return self.token("kc", expiresInSeconds: 9_999) })
        XCTAssertEqual(result?.accessToken, "cache")
        XCTAssertFalse(keychainCalled)
    }

    /// A cached token within 5 minutes of expiry is not trustworthy (no refresh token to renew it),
    /// so on a user action we fall through to the keychain.
    func testNearExpiryCacheFallsThroughToKeychainWhenUserInitiated() {
        let result = LiveUsageDataSource.selectClaudeToken(
            file: nil, userInitiated: true, now: now,
            mimirCache: { self.token("cache", expiresInSeconds: 299) },
            keychain: { self.token("kc", expiresInSeconds: 9_999) })
        XCTAssertEqual(result?.accessToken, "kc")
    }

    /// Exactly 300s left is still "near expiry" (the rule is strictly greater than 5 minutes).
    func testExactlyFiveMinutesIsNotFreshEnough() {
        let result = LiveUsageDataSource.selectClaudeToken(
            file: nil, userInitiated: false, now: now,
            mimirCache: { self.token("cache", expiresInSeconds: 300) },
            keychain: { self.token("kc", expiresInSeconds: 9_999) })
        XCTAssertNil(result)
    }

    /// A cached token with no expiry metadata can't be trusted (we can't tell if it's alive), so it
    /// is skipped.
    func testCacheWithNoExpiryIsSkipped() {
        let result = LiveUsageDataSource.selectClaudeToken(
            file: nil, userInitiated: false, now: now,
            mimirCache: { self.token("cache", expiresInSeconds: nil) },
            keychain: { self.token("kc", expiresInSeconds: 9_999) })
        XCTAssertNil(result)
    }

    /// THE prompt guarantee: in the background (not user-initiated), with no file and no usable
    /// cache, we return nil and never invoke the keychain closure — so a background tick can't pop
    /// the macOS permission prompt.
    func testBackgroundNeverReadsKeychain() {
        var keychainCalled = false
        let result = LiveUsageDataSource.selectClaudeToken(
            file: nil, userInitiated: false, now: now,
            mimirCache: { nil },
            keychain: { keychainCalled = true; return self.token("kc", expiresInSeconds: 9_999) })
        XCTAssertNil(result)
        XCTAssertFalse(keychainCalled)
    }

    /// A user action (opening Mimir) with no prompt-free source may read the keychain.
    func testUserInitiatedReadsKeychainAsLastResort() {
        let result = LiveUsageDataSource.selectClaudeToken(
            file: nil, userInitiated: true, now: now,
            mimirCache: { nil },
            keychain: { self.token("kc", expiresInSeconds: 9_999) })
        XCTAssertEqual(result?.accessToken, "kc")
    }
}
