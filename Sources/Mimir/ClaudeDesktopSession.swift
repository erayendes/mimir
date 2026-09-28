import Foundation
import SQLite3
import CommonCrypto
import Security
import LocalAuthentication
import os

/// Reads the Claude **desktop** app's live usage. The desktop app is Electron, so — unlike Claude Code
/// CLI, which keeps an OAuth token in the keychain — it logs in via a `sessionKey` cookie stored in a
/// Chromium cookie DB, encrypted with a key derived from the "Claude Safe Storage" keychain item. We
/// read + decrypt that cookie and call the same claude.ai endpoints the app uses, so a desktop-only
/// user (who never touches the CLI, whose CLI token/hook are therefore always stale) still gets live
/// numbers. Unlike Claude Code, Electron does not rewrite the Safe Storage item on every use, so one
/// "Always Allow" for it sticks — after which every read is silent.
extension LiveUsageDataSource {
    private static let desktopLog = Logger(subsystem: "com.erayendes.mimir.desktop", category: "claude")

    /// Fetch usage from claude.ai using the desktop app's session. Returns nil (falling back to the
    /// CLI/hook path) when the desktop app isn't installed/logged-in, the session can't be read, or
    /// the request fails. `userInitiated` gates the one-time Safe Storage grant prompt.
    func fetchClaudeDesktopUsage(userInitiated: Bool) async -> ServiceStatus? {
        if let web = await fetchClaudeDesktopWebUsage(userInitiated: userInitiated) { return web }
        return await fetchClaudeDesktopOAuthUsage()
    }

    private func fetchClaudeDesktopWebUsage(userInitiated: Bool) async -> ServiceStatus? {
        guard let sessionKey = readClaudeDesktopSessionKey(userInitiated: userInitiated) else {
            Self.desktopLog.log("no desktop sessionKey (silent read failed / not granted / not logged in)")
            return nil
        }

        func request(_ url: String) -> URLRequest {
            var r = URLRequest(url: URL(string: url)!, timeoutInterval: 10)
            r.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
            r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
            r.setValue("application/json", forHTTPHeaderField: "Accept")
            return r
        }

        do {
            let (orgData, orgResp) = try await URLSession.shared.data(for: request("https://claude.ai/api/organizations"))
            let orgCode = (orgResp as? HTTPURLResponse)?.statusCode ?? -1
            guard orgCode == 200,
                  let orgs = try? JSONSerialization.jsonObject(with: orgData) as? [[String: Any]],
                  let uuid = Self.selectClaudeOrgUUID(orgs) else {
                Self.desktopLog.log("orgs failed http=\(orgCode) cloudflare=\(Self.isCloudflareChallenge(orgResp, orgData)) count=\(((try? JSONSerialization.jsonObject(with: orgData)) as? [[String: Any]])?.count ?? -1)")
                return nil
            }

            // `?cedar_ember=1` asks the same endpoint to also return the account's usage-limit reset
            // grants — the "Resets" card claude.ai shows. The field is gated on the *surface* making
            // the request (the response echoes `event_props.surface`), and this path already IS
            // claude.ai with the desktop app's own session, so it arrives honestly. The CLI's
            // `api.anthropic.com` sibling gates the same field behind Claude Code's own User-Agent,
            // which Mimir will not impersonate — so this is the one path that can carry it.
            let (usageData, usageResp) = try await URLSession.shared.data(for: request("https://claude.ai/api/organizations/\(uuid)/usage?cedar_ember=1"))
            let usageCode = (usageResp as? HTTPURLResponse)?.statusCode ?? -1
            guard usageCode == 200,
                  let root = try? JSONSerialization.jsonObject(with: usageData) as? [String: Any] else {
                Self.desktopLog.log("usage failed http=\(usageCode) cloudflare=\(Self.isCloudflareChallenge(usageResp, usageData))")
                return nil
            }

            // Before trusting anything cached, make sure it belongs to this account.
            noteClaudeAccount(uuid)
            writeClaudeUsageCache(usageData)
            let status = buildClaudeStatus(from: root, note: "claude.ai desktop")
            saveSnapshot(status)
            Self.desktopLog.log("OK session=\(status.sessionRemainingPercent ?? -1) weekly=\(status.weeklyRemainingPercent ?? -1)")
            return status.withCooldownHint(0)
        } catch {
            Self.desktopLog.log("request threw: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Cloudflare's "Just a moment" page: claude.ai sits behind it, and some networks (VPNs,
    /// datacenter IPs) get the challenge instead of the API. Told apart from a dead session only in
    /// the log — either way the OAuth path below takes over.
    static func isCloudflareChallenge(_ response: URLResponse, _ body: Data) -> Bool {
        if (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "cf-mitigated") == "challenge" { return true }
        return String(data: body.prefix(4096), encoding: .utf8)?.contains("Just a moment") ?? false
    }

    /// The desktop app's own OAuth token, used when claude.ai's web API won't answer (Cloudflare,
    /// an expired cookie). It goes to `api.anthropic.com`, which Cloudflare doesn't front. Second,
    /// not first: that endpoint leaves out the reset grants, which only the web path carries.
    /// Read only — never refreshed, the same rule as Claude Code's token.
    private func fetchClaudeDesktopOAuthUsage() async -> ServiceStatus? {
        guard let password = readClaudeSafeStoragePassword(interactive: false),
              let data = FileManager.default.contents(atPath: NSHomeDirectory() + "/Library/Application Support/Claude/config.json"),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = Self.claudeDesktopOAuthToken(config: config, safeStoragePassword: password) else {
            Self.desktopLog.log("no desktop oauth token")
            return nil
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        guard let (body, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Self.desktopLog.log("desktop oauth usage failed")
            return nil
        }
        writeClaudeUsageCache(body)
        let status = buildClaudeStatus(from: root, note: "claude desktop oauth")
        saveSnapshot(status)
        return status.withCooldownHint(0)
    }

    /// The unexpired access token in the desktop app's `oauth:tokenCacheV2` (older builds:
    /// `oauth:tokenCache`) — Electron safeStorage, so the same Safe Storage password and cipher as
    /// the cookie. The decrypted layout isn't documented, so this looks for any `sk-ant-oat…` token
    /// with an expiry and takes the one that lasts longest. Pure → unit-testable.
    static func claudeDesktopOAuthToken(config: [String: Any], safeStoragePassword: String,
                                        now: Date = Date()) -> String? {
        guard let blob = (config["oauth:tokenCacheV2"] ?? config["oauth:tokenCache"]) as? String,
              let encrypted = Data(base64Encoded: blob),
              let plain = decryptChromium(encrypted, safeStoragePassword: safeStoragePassword),
              let cache = try? JSONSerialization.jsonObject(with: plain) else { return nil }
        return claudeOAuthToken(in: cache, now: now)
    }

    static func claudeOAuthToken(in cache: Any, now: Date = Date()) -> String? {
        var best: (token: String, expires: Date)?
        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                let token = ["token", "accessToken", "access_token"].lazy
                    .compactMap { dict[$0] as? String }.first { $0.hasPrefix("sk-ant-oat") }
                if let token, let expires = expiry(dict["expiresAt"] ?? dict["expires_at"]), expires > now,
                   expires > best?.expires ?? .distantPast {
                    best = (token, expires)
                }
                dict.values.forEach(walk)
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        walk(cache)
        return best?.token
    }

    /// Milliseconds or seconds since 1970, or an ISO 8601 string.
    private static func expiry(_ raw: Any?) -> Date? {
        if let text = raw as? String { return ISO8601DateFormatter().date(from: text) }
        guard let number = (raw as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number)
    }

    /// Pick the organization whose usage we report. Prefer one that looks like a chat/Pro account
    /// (has `capabilities`), else the first — a personal login typically has exactly one.
    static func selectClaudeOrgUUID(_ orgs: [[String: Any]]) -> String? {
        let withCaps = orgs.first { ($0["capabilities"] as? [String])?.contains(where: { $0.contains("chat") || $0.contains("claude") }) ?? false }
        return (withCaps?["uuid"] as? String) ?? (orgs.first?["uuid"] as? String)
    }

    // MARK: - Session key extraction

    /// The claude.ai `sessionKey`, decrypted. Tries a SILENT keychain read first (never prompts); only
    /// a user action may fall through to the one-time granting read.
    func readClaudeDesktopSessionKey(userInitiated: Bool) -> String? {
        let password = readClaudeSafeStoragePassword(interactive: false)
            ?? (userInitiated ? readClaudeSafeStoragePassword(interactive: true) : nil)
        guard let password else { return nil }
        guard let encrypted = readClaudeCookieEncryptedValue() else {
            Self.desktopLog.log("cookie read failed (no Cookies DB / no sessionKey row)")
            return nil
        }
        let key = Self.decryptChromiumCookie(encrypted, safeStoragePassword: password)
        if key == nil { Self.desktopLog.log("cookie decrypt failed (\(encrypted.count) bytes)") }
        return key
    }

    /// The "Claude Safe Storage" keychain password (Chromium's per-app encryption secret). A background
    /// read is silent via `interactionNotAllowed`; the granting read is reserved for a user action.
    private func readClaudeSafeStoragePassword(interactive: Bool) -> String? {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if !interactive {
            let ctx = LAContext()
            ctx.interactionNotAllowed = true
            q[kSecUseAuthenticationContext as String] = ctx
        }
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// The encrypted `sessionKey` cookie value from the desktop app's Chromium cookie DB. Copied to a
    /// temp file first so we don't contend with the app's SQLite lock.
    private func readClaudeCookieEncryptedValue() -> Data? {
        let src = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/Cookies")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimir-cc-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? FileManager.default.copyItem(at: src, to: tmp)) != nil else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        // Longest value wins if there are stale duplicates.
        let sql = "SELECT encrypted_value FROM cookies WHERE host_key LIKE '%claude.ai' AND name='sessionKey' ORDER BY LENGTH(encrypted_value) DESC LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let blob = sqlite3_column_blob(stmt, 0) else { return nil }
        return Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0)))
    }

    /// Chromium macOS cookie decryption: after the `v10`/`v11` tag, AES-128-CBC with key =
    /// PBKDF2-SHA1(safeStoragePassword, salt "saltysalt", 1003 iterations, 16 bytes) and IV = 16 spaces.
    /// Newer Chromium prepends a 32-byte SHA-256(host) to the plaintext — stripped when the result
    /// doesn't already look like a `sk-ant-…` session key. Pure → unit-testable.
    static func decryptChromiumCookie(_ encrypted: Data, safeStoragePassword: String) -> String? {
        guard let plain = decryptChromium(encrypted, safeStoragePassword: safeStoragePassword) else { return nil }
        if let s = String(data: plain, encoding: .utf8), s.hasPrefix("sk-ant") { return s }
        if plain.count > 32, let s = String(data: plain.subdata(in: 32 ..< plain.count), encoding: .utf8),
           s.hasPrefix("sk-ant") { return s }
        // Last resort: return whatever decoded (still usable if the format shifts), else nil.
        return String(data: plain, encoding: .utf8).flatMap { $0.hasPrefix("sk-") ? $0 : nil }
    }

    /// Electron/Chromium safeStorage on macOS, the raw plaintext: `v10`/`v11` tag, then AES-128-CBC
    /// as above.
    static func decryptChromium(_ encrypted: Data, safeStoragePassword: String) -> Data? {
        guard encrypted.count > 3, let tag = String(data: encrypted.prefix(3), encoding: .utf8),
              tag == "v10" || tag == "v11" else { return nil }
        let ciphertext = encrypted.subdata(in: 3 ..< encrypted.count)
        guard !ciphertext.isEmpty, ciphertext.count % 16 == 0 else { return nil }

        var key = [UInt8](repeating: 0, count: 16)
        let pw = Array(safeStoragePassword.utf8)
        let salt = Array("saltysalt".utf8)
        let derive = pw.withUnsafeBufferPointer { p in
            salt.withUnsafeBufferPointer { s in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     p.baseAddress, p.count,
                                     s.baseAddress, s.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                     &key, key.count)
            }
        }
        guard derive == kCCSuccess else { return nil }

        let iv = [UInt8](repeating: 0x20, count: 16)
        var out = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var outLen = 0
        let status = ciphertext.withUnsafeBytes { ct in
            key.withUnsafeBufferPointer { k in
                iv.withUnsafeBufferPointer { i in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                            k.baseAddress, k.count, i.baseAddress,
                            ct.baseAddress, ciphertext.count,
                            &out, out.count, &outLen)
                }
            }
        }
        guard status == kCCSuccess, outLen > 0 else { return nil }
        return Data(out.prefix(outLen))
    }
}
