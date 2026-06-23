import Foundation
import Security

extension LiveUsageDataSource {
    /// `userInitiated` gates whether this fetch may read Claude Code's *own* keychain item — the
    /// only source that pops the macOS permission prompt, because Claude Code resets the item's ACL
    /// (wiping our "Always Allow") every time it rotates its token. A background tick passes `false`
    /// and stays on prompt-free sources (usage cache, the on-disk credential file, Mimir's own token
    /// cache); only a real user action — opening Mimir — passes `true` and may read that item.
    func fetchClaude(userInitiated: Bool) async -> ServiceStatus {
        if let cached = readClaudeUsageCache(maxAge: 5 * 60) {
            return buildClaudeStatus(from: cached, note: "oauth usage cache").withCooldownHint(0)
        }

        // Reuse the in-memory token while it's comfortably valid, so the keychain — and its macOS
        // permission prompt — is touched only at launch and around token expiry, not every refresh.
        var tokenInfo = await Self.claudeTokenCache.get()
        let needsKeychain = tokenInfo.map { $0.expiresAt.map { $0.timeIntervalSinceNow <= 300 } ?? false } ?? true

        if needsKeychain {
            guard let read = readClaudeTokenInfo(userInitiated: userInitiated) else {
                // No prompt-free source had a usable token. We deliberately did NOT read Claude
                // Code's keychain item in the background; opening Mimir (a user action) will.
                let note = userInitiated
                    ? String(localized: "claude token missing")
                    : String(localized: "open Mimir to refresh Claude")
                return claudeFailure(note: note)
            }
            tokenInfo = read

            // Refresh proactively when the freshly-read token is expired or within 5 min of expiry.
            // Anthropic rotates the refresh token, so `refreshClaudeToken()` writes the new pair back
            // to the source it came from — keeping Claude Code's own login valid. If refresh fails,
            // back off. Background refresh only has the file as a refresh source (the keychain is
            // gated), so a keychain-only setup defers its refresh to the next time Mimir is opened.
            if let exp = read.expiresAt, exp.timeIntervalSinceNow <= 300 {
                guard let fresh = await refreshClaudeToken(userInitiated: userInitiated) else {
                    let note = String(localized: "token expired — open Claude Code")
                    return claudeFailure(note: note, staleNote: note).withCooldownHint(15 * 60)
                }
                tokenInfo = fresh
            }
            await Self.claudeTokenCache.set(tokenInfo)
            // Mirror the access token into Mimir's own keychain item so the next background tick can
            // reuse it without prompting (see cacheMimirClaudeToken — access token only, no refresh).
            if let tokenInfo { cacheMimirClaudeToken(tokenInfo) }
        }

        guard let token = tokenInfo else {
            return claudeFailure(note: "claude token missing")
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 10)
        req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return claudeFailure(note: "claude no http response")
            }
            guard 200 ... 299 ~= http.statusCode else {
                // A rejected token is likely stale (rotated out by Claude Code); drop both caches so
                // the next refresh re-reads a fresh token instead of replaying the dead one. Dropping
                // Mimir's own cache is load-bearing in the background: the keychain that holds a fresh
                // token is gated to user actions, so a kept-but-dead cache would 401 on every tick.
                if http.statusCode == 401 || http.statusCode == 403 {
                    await Self.claudeTokenCache.set(nil)
                    deleteMimirClaudeToken()
                }
                // Back off on rate limiting so we stop pounding a 429ing endpoint.
                let cooldown: TimeInterval? = http.statusCode == 429 ? (retryAfterSeconds(http) ?? 15 * 60) : nil
                return claudeFailure(note: "claude http \(http.statusCode)").withCooldownHint(cooldown)
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return claudeFailure(note: "claude response parse fail")
            }
            writeClaudeUsageCache(data)
            let status = buildClaudeStatus(from: root, note: "oauth usage api")
            saveSnapshot(status)
            return status.withCooldownHint(0)   // live success → clear any cooldown
        } catch {
            return claudeFailure(note: "claude request failed")
        }
    }

    /// Claude's live fetch failed — show last-known data instead of vanishing: the still-valid
    /// 24h usage cache, else the persisted snapshot (dimmed when its windows have reset), else
    /// the hidden unavailable card (only when nothing was ever cached).
    private func claudeFailure(note: String, staleNote: String = String(localized: "out of date")) -> ServiceStatus {
        // Recent cache → normal card (seed a snapshot so the cooldown/skip path can serve it too).
        if let cached = readClaudeUsageCache(maxAge: 24 * 60 * 60) {
            let status = buildClaudeStatus(from: cached, note: note)
            saveSnapshot(status)
            return status
        }
        // Persisted snapshot, else an older cache trusted by reset time (windows still within their
        // reset show dimmed; refilled windows are blanked) — seeded as a snapshot for next time.
        if let snap = loadSnapshot(for: "Claude", iconName: "claude", staleNote: staleNote) {
            return snap
        }
        if let stale = claudeCardFromStaleCache(staleNote: staleNote) {
            saveSnapshot(stale)
            return stale
        }
        return unavailableService(name: "Claude", iconName: "claude", models: [], note: note)
    }

    /// Build a Claude card from the cache at any age, trusting each window by its reset time, so a
    /// still-valid weekly number survives even when the 24h cache window and the token have lapsed.
    private func claudeCardFromStaleCache(staleNote: String) -> ServiceStatus? {
        guard let root = readClaudeUsageCacheRaw() else { return nil }
        let full = buildClaudeStatus(from: root, note: "snapshot")
        return staleClassifiedCard(
            name: "Claude", iconName: "claude",
            sessionPct: full.sessionRemainingPercent, sessionReset: full.sessionResetAt,
            weeklyPct: full.weeklyRemainingPercent, weeklyReset: full.weeklyResetAt,
            models: full.models, freshNote: "snapshot", staleNote: staleNote)
    }

    /// Parse an HTTP `Retry-After` header (delta-seconds or HTTP-date) into a backoff interval.
    private func retryAfterSeconds(_ http: HTTPURLResponse) -> TimeInterval? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let secs = TimeInterval(raw) { return max(0, secs) }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "GMT")
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return fmt.date(from: raw).map { max(0, $0.timeIntervalSinceNow) }
    }

    private func buildClaudeStatus(from root: [String: Any], note: String) -> ServiceStatus {
        let fiveHour = mergeClaudeWindows(root: root, baseKey: "five_hour")
        let sevenDay = mergeClaudeWindows(root: root, baseKey: "seven_day")
        let sonnet = mergeClaudeWindows(root: root, baseKey: "seven_day_sonnet")

        // Sonnet is a weekly (7-day) window, so it's always shown like the overall
        // Weekly row — even at 0% used. When the API omits its own reset, fall back
        // to the seven-day reset since they reset together.
        var models: [ModelStatus] = [
            ModelStatus(
                name: "Sonnet",
                remainingPercent: remainingPercent(fromUsed: sonnet.utilization),
                resetAt: sonnet.resetAt ?? sevenDay.resetAt
            )
        ]
        if let billing = claudeBillingRow(root["extra_usage"]) {
            models.append(billing)
        }

        // Classify by reset time so a window that has already reset (e.g. a 5h reading from an old
        // cache used as a fallback) is blanked rather than shown as if current. Live readings have
        // future resets, so this is a no-op on the happy path.
        return staleClassifiedCard(
            name: "Claude", iconName: "claude",
            sessionPct: remainingPercent(fromUsed: fiveHour.utilization), sessionReset: fiveHour.resetAt,
            weeklyPct: remainingPercent(fromUsed: sevenDay.utilization), weeklyReset: sevenDay.resetAt,
            models: models, freshNote: note, staleNote: note)
            ?? unavailableService(name: "Claude", iconName: "claude", models: [], note: note)
    }
    private func claudeBillingRow(_ raw: Any?) -> ModelStatus? {
        guard let e = raw as? [String: Any], e["is_enabled"] as? Bool == true else { return nil }
        let used = doubleValue(e["used_credits"]) ?? 0
        let limit = doubleValue(e["monthly_limit"])
        let cur = (e["currency"] as? String).map { $0.uppercased() } ?? ""
        func money(_ v: Double) -> String {
            let n = v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(format: "%.2f", v)
            return cur.isEmpty ? n : "\(n) \(cur)"
        }
        let text = limit.map { "\(money(used)) / \(money($0))" } ?? money(used)
        let util = doubleValue(e["utilization"]) ?? (limit.map { $0 > 0 ? used / $0 * 100 : 0 } ?? 0)
        return ModelStatus(name: String(localized: "Billing"), remainingPercent: 0, resetAt: nil,
                           valueText: text, isLow: util >= 80)
    }
    private func mergeClaudeWindows(root: [String: Any], baseKey: String) -> (utilization: Double, resetAt: Date?) {
        var bestUtil = 0.0
        var resetDates: [Date] = []
        for (k, raw) in root where k == baseKey || k.hasPrefix("\(baseKey)_") {
            guard let obj = raw as? [String: Any] else { continue }
            bestUtil = max(bestUtil, obj["utilization"] as? Double ?? 0)
            if let resetRaw = obj["resets_at"] as? String, let date = parseISO8601(resetRaw) {
                resetDates.append(date)
            }
        }
        return (bestUtil, resetDates.sorted().first)
    }
    struct ClaudeToken: Equatable {
        let accessToken: String
        let expiresAt: Date?   // nil when the source is a bare token with no expiry metadata
    }

    /// Pick which Claude token to use from the available sources, in prompt-free-first order:
    ///   1. the on-disk credential file (`file`) — no keychain prompt;
    ///   2. Mimir's own cached access token (`mimirCache`) — only while it still has more than
    ///      5 minutes of validity (it carries no refresh token, so a near-dead one is useless);
    ///   3. Claude Code's keychain item (`keychain`) — the only prompting source, read solely on a
    ///      user action (`userInitiated`).
    /// `mimirCache` and `keychain` are closures so a source is touched only if it's actually reached
    /// — in particular the keychain (the prompt) is never invoked when a prompt-free source suffices.
    /// Pure: the ordering/gating rules are testable without the filesystem, the keychain, or the clock.
    static func selectClaudeToken(
        file: ClaudeToken?,
        userInitiated: Bool,
        now: Date,
        mimirCache: () -> ClaudeToken?,
        keychain: () -> ClaudeToken?
    ) -> ClaudeToken? {
        if let file { return file }
        if let cached = mimirCache(), let exp = cached.expiresAt, exp.timeIntervalSince(now) > 300 {
            return cached
        }
        guard userInitiated else { return nil }
        return keychain()
    }

    /// In-memory cache of the Claude OAuth token so the keychain is read only at launch and around
    /// token expiry — not on every refresh. The "Claude Code-credentials" item is owned by Claude
    /// Code, which resets the item's ACL each time it rewrites the entry on its own token refresh;
    /// reading it repeatedly therefore re-triggers the macOS permission prompt. Mirroring Claude
    /// Code's own "read once, reuse" behaviour keeps that prompt rare. An actor because refreshes
    /// run off the main thread.
    private actor ClaudeTokenCache {
        private var token: ClaudeToken?
        func get() -> ClaudeToken? { token }
        func set(_ value: ClaudeToken?) { token = value }
    }
    private static let claudeTokenCache = ClaudeTokenCache()

    /// Read the Claude Code OAuth token plus its expiry, wiring the live sources (file, Mimir's own
    /// cache, Claude Code's keychain item) into `selectClaudeToken`, which holds the prompt-free-first
    /// ordering and the user-action gate. The keychain — the only prompting source — is a closure, so
    /// it's reached only when no prompt-free source has a usable token and the read is user-initiated.
    /// `expiresAt` drives whether `fetchClaude` refreshes before calling the usage API.
    private func readClaudeTokenInfo(userInitiated: Bool) -> ClaudeToken? {
        Self.selectClaudeToken(
            file: readClaudeCredentialFileToken(),
            userInitiated: userInitiated,
            now: Date(),
            mimirCache: { readMimirClaudeToken() },
            keychain: {
                guard let raw = readClaudeKeychainItem()?.value else { return nil }
                return parseClaudeToken(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            })
    }

    /// The OAuth token from the on-disk credential file only (no keychain, so no prompt).
    private func readClaudeCredentialFileToken() -> ClaudeToken? {
        let credPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: credPath),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        return parseClaudeToken(raw)
    }

    private func readClaudeUsageCache(maxAge: TimeInterval) -> [String: Any]? {
        let url = claudeUsageCacheURL()
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let modifiedAt = values.contentModificationDate,
              Date().timeIntervalSince(modifiedAt) <= maxAge else {
            return nil
        }
        return readClaudeUsageCacheRaw()
    }

    /// The cached usage JSON regardless of age — used as a deep fallback that is trusted not by
    /// age but by each window's reset time (a weekly number from a 3-day-old cache is still right
    /// if that week hasn't reset yet).
    private func readClaudeUsageCacheRaw() -> [String: Any]? {
        guard let data = try? Data(contentsOf: claudeUsageCacheURL()),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return root
    }

    private func writeClaudeUsageCache(_ data: Data) {
        let url = claudeUsageCacheURL()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try LiveUsageDataSource.secureAtomicWrite(data: data, to: url)
        } catch {
            // Cache is an optimization; the live result is still usable.
        }
    }

    private func claudeUsageCacheURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mimir/claude_usage.json")
    }

    private func parseClaudeToken(_ raw: String) -> ClaudeToken? {
        if raw.hasPrefix("sk-ant-") || raw.hasPrefix("sk-ant-oat") {
            return ClaudeToken(accessToken: raw, expiresAt: nil)
        }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let oauth = obj["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String {
            return ClaudeToken(accessToken: token, expiresAt: epochMillisToDate(oauth["expiresAt"]))
        }
        if let token = obj["accessToken"] as? String {
            return ClaudeToken(accessToken: token, expiresAt: epochMillisToDate(obj["expiresAt"]))
        }
        return nil
    }
    private enum ClaudeCredentialSource {
        case keychain(account: String)
        case file(URL)
    }

    /// Read the Claude Code generic-password item in-process via the Security framework — no
    /// `/usr/bin/security` subprocess. This matters for the keychain prompt: an in-process read is
    /// attributed to Mimir's own code signature, so the user's "Always Allow" is tied to Mimir
    /// (stable in release builds) rather than to `/usr/bin/security`, whose grant the item's owner
    /// (Claude Code) wipes whenever it rewrites the entry on token refresh. Returns the stored value
    /// plus the item's account attribute (needed to update the same entry in place).
    private func readClaudeKeychainItem() -> (value: String, account: String?)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.claudeKeychainService,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let dict = result as? [String: Any],
              let data = dict[kSecValueData as String] as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return (value, dict[kSecAttrAccount as String] as? String)
    }

    /// Read the full Claude credential JSON (which carries the refresh token) and remember where it
    /// came from, so a refreshed token can be written back to the same store (preserving the rest of
    /// the blob, e.g. `mcpOAuth`). The on-disk file is tried first because it never prompts; Claude
    /// Code's keychain item is reached only on a user action (`userInitiated`), since reading it pops
    /// the macOS permission prompt. A background refresh therefore only succeeds on a file-backed
    /// setup — a keychain-only login defers its refresh to the next time the user opens Mimir.
    private func readClaudeCredential(userInitiated: Bool) -> (root: [String: Any], source: ClaudeCredentialSource)? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: url),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (root, .file(url))
        }
        guard userInitiated,
              let item = readClaudeKeychainItem(),
              let data = item.value.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["claudeAiOauth"] != nil,
              // SecItemUpdate locates the entry to rewrite by account; fall back to the login name.
              let account = item.account ?? (NSUserName().isEmpty ? nil : NSUserName()) else {
            return nil
        }
        return (root, .keychain(account: account))
    }

    /// Refresh Claude's access token with the stored refresh token, then write the rotated pair back
    /// to the same store so Claude Code's own login keeps working (Anthropic rotates the refresh
    /// token, so persisting it is mandatory). Returns the new access token, or nil on any failure.
    private func refreshClaudeToken(userInitiated: Bool) async -> ClaudeToken? {
        guard let credential = readClaudeCredential(userInitiated: userInitiated),
              var oauth = credential.root["claudeAiOauth"] as? [String: Any],
              let refresh = oauth["refreshToken"] as? String, !refresh.isEmpty else {
            return nil
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/oauth/token")!, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": Self.claudeOAuthClientID
        ])

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse).map({ 200 ... 299 ~= $0.statusCode }) == true,
              let resp = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccess = resp["access_token"] as? String, !newAccess.isEmpty else {
            return nil
        }

        oauth["accessToken"] = newAccess
        if let newRefresh = resp["refresh_token"] as? String, !newRefresh.isEmpty {
            oauth["refreshToken"] = newRefresh
        }
        if let expiresIn = doubleValue(resp["expires_in"]) {
            oauth["expiresAt"] = Int(Date().timeIntervalSince1970 * 1000 + expiresIn * 1000)
        }
        var root = credential.root
        root["claudeAiOauth"] = oauth
        writeClaudeCredential(root, to: credential.source)
        let token = ClaudeToken(accessToken: newAccess, expiresAt: epochMillisToDate(oauth["expiresAt"]))
        cacheMimirClaudeToken(token)   // keep the prompt-free background cache in sync
        return token
    }

    static let mimirClaudeKeychainService = "Mimir-claude-oauth"

    /// Cache ONLY the short-lived access token (+ its expiry) in Mimir's OWN keychain item. We never
    /// store the refresh token here: refresh tokens rotate single-use and are shared with Claude
    /// Code, so refreshing from a private copy would silently invalidate Claude Code's own login.
    /// This item is owned by Mimir, so reading it back never prompts — it lets a background tick
    /// reuse a still-valid access token instead of reaching for Claude Code's keychain item.
    private func cacheMimirClaudeToken(_ token: ClaudeToken) {
        guard let expiresAt = token.expiresAt else { return }  // nothing to expiry-check → don't cache
        let payload: [String: Any] = [
            "accessToken": token.accessToken,
            "expiresAt": Int(expiresAt.timeIntervalSince1970 * 1000)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.mimirClaudeKeychainService,
            kSecAttrAccount as String: NSUserName()
        ]
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            // Background refreshes run while the screen may be locked, so the item must be readable
            // after the first unlock — not only while unlocked (the SecItemAdd default).
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// Drop Mimir's cached access token. Called when the server rejects it (401/403): otherwise a
    /// background tick would keep replaying the dead token, since the keychain holding a fresh one is
    /// read only on a user action. Safe to call when the item is absent (`SecItemDelete` no-ops).
    private func deleteMimirClaudeToken() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.mimirClaudeKeychainService
        ] as CFDictionary)
    }

    /// Read Mimir's own cached access token (prompt-free — Mimir owns this item). Returns nil when
    /// the item is missing or malformed; the caller checks `expiresAt` before trusting it.
    private func readMimirClaudeToken() -> ClaudeToken? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.mimirClaudeKeychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["accessToken"] as? String, !access.isEmpty else {
            return nil
        }
        return ClaudeToken(accessToken: access, expiresAt: epochMillisToDate(obj["expiresAt"]))
    }

    private func writeClaudeCredential(_ root: [String: Any], to source: ClaudeCredentialSource) {
        guard let data = try? JSONSerialization.data(withJSONObject: root) else { return }
        switch source {
        case .keychain(let account):
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.claudeKeychainService,
                kSecAttrAccount as String: account
            ]
            let attributes: [String: Any] = [
                kSecValueData as String: data
            ]
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var newItem = query
                for (k, v) in attributes {
                    newItem[k] = v
                }
                SecItemAdd(newItem as CFDictionary, nil)
            }
        case .file(let url):
            try? LiveUsageDataSource.secureAtomicWrite(data: data, to: url)
        }
    }
}
