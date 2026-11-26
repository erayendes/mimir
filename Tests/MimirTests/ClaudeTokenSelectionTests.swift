import XCTest
@testable import Mimir

/// `selectClaudeToken` encodes the prompt-free-first sourcing rules: file → Mimir's own (still-valid)
/// cache → a silent keychain read → a user-action keychain read (only its in-process fallback may
/// show the dialog). The load-bearing checks are the laziness ones: earlier sources short-circuit
/// the rest, and the interactive fallback is never reached in the background.
final class ClaudeTokenSelectionTests: XCTestCase {
    private typealias Token = LiveUsageDataSource.ClaudeToken
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func token(_ id: String, expiresInSeconds: TimeInterval?) -> Token {
        Token(accessToken: id, expiresAt: expiresInSeconds.map { now.addingTimeInterval($0) })
    }

    func testSecurityDataSkipsFallbackAndTrimsOnlyTrailingNewline() {
        var fallbackCalled = false
        let value = LiveUsageDataSource.claudeKeychainData(securityOutput: " secret \n") {
            fallbackCalled = true
            return "fallback"
        }
        XCTAssertEqual(value, " secret ")
        XCTAssertFalse(fallbackCalled)
    }

    func testEmptySecurityDataUsesFallback() {
        var fallbackCalled = false
        let value = LiveUsageDataSource.claudeKeychainData(securityOutput: "\n") {
            fallbackCalled = true
            return "fallback"
        }
        XCTAssertEqual(value, "fallback")
        XCTAssertTrue(fallbackCalled)
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

    /// A silent read can supply a token in the background without reaching the interactive path.
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

    /// With no file, cache or silent result, a background tick returns nil without trying the
    /// interactive fallback.
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
    /// on a user action with no silent result we fall through to the interactive keychain path.
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

    /// A user action (opening Mimir) with no earlier token source may read the
    /// keychain path as the last resort, where only the fallback may prompt.
    func testUserInitiatedReadsGrantKeychainAsLastResort() {
        let result = LiveUsageDataSource.selectClaudeToken(
            file: nil, userInitiated: true, now: now,
            mimirCache: { nil },
            silentKeychain: { nil },
            keychain: { self.token("kc", expiresInSeconds: 9_999) })
        XCTAssertEqual(result?.accessToken, "kc")
    }

    /// #111: a newest keychain entry holding only an MCP login, or a blank `accessToken`, is no login
    /// — the next entry is tried, and only the newest may be read with a prompt. A blank credential
    /// file likewise yields no token, so it can't hide the keychain login.
    func testUnusableKeychainEntriesFallThroughSilently() {
        let ds = LiveUsageDataSource()
        let entries: [(service: String, account: String?, modifiedAt: Date?)] = [
            ("Claude Code-credentials-aa", nil, nil), ("Claude Code-credentials-bb", nil, nil),
            ("Claude Code-credentials", nil, nil)
        ]
        let data = [
            "Claude Code-credentials-aa": #"{"mcpOAuth":{"srv":{"accessToken":"x"}}}"#,
            "Claude Code-credentials-bb": #"{"claudeAiOauth":{"accessToken":"  ","expiresAt":1}}"#,
            "Claude Code-credentials": #"{"claudeAiOauth":{"accessToken":"good","expiresAt":1}}"#,
        ]
        var interactiveReads: [String] = []
        let raw = ds.firstUsableClaudeKeychainItem(in: entries, interactive: true) { candidate, interactive in
            if interactive { interactiveReads.append(candidate.service) }
            return data[candidate.service]
        }
        XCTAssertEqual(raw.flatMap(ds.parseClaudeToken)?.accessToken, "good")
        XCTAssertEqual(interactiveReads, ["Claude Code-credentials-aa"])
        XCTAssertNil(ds.parseClaudeToken(#"{"claudeAiOauth":{"accessToken":""}}"#))
        XCTAssertNil(ds.parseClaudeToken(""))
    }

    /// A token Claude Code can renew asks to open it; one it can't asks for a new login.
    func testAnExpiredTokenSaysOpenWhenRenewableAndLoginWhenNot() {
        let ds = LiveUsageDataSource()
        let renewable = ds.parseClaudeToken(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1}}"#)
        let dead = ds.parseClaudeToken(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":" ","expiresAt":1}}"#)
        XCTAssertEqual(renewable?.renewable, true)
        XCTAssertEqual(dead?.renewable, false)
        XCTAssertEqual(renewable?.expiredNote, String(localized: "token expired — open Claude Code"))
        XCTAssertEqual(dead?.expiredNote, String(localized: "token expired — run /login in Claude Code"))
    }
}
