import Foundation
import Security
import LocalAuthentication

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

        // When Claude Code's prompt-free statusLine hook is fresh it already carries the live
        // session/weekly numbers, so a routine open must NOT reach for the prompting keychain read.
        // Claude Code wipes its item's ACL on every token refresh, so our "Always Allow" doesn't
        // survive — a prompting read would then re-pop the dialog every few hours (once per refresh).
        // Gate the prompt behind "no fresh hook": while the hook covers us we do silent reads only, so
        // the keychain (and its dialog) is touched solely when the hook can't (Claude Code idle).
        let hookFresh = readClaudeHookUsage(maxAge: 30 * 60) != nil

        // Reuse the in-memory token while it's comfortably valid, so the keychain — and its macOS
        // permission prompt — is touched only at launch and around token expiry, not every refresh.
        var tokenInfo = await Self.claudeTokenCache.get()
        let needsKeychain = tokenInfo.map { $0.expiresAt.map { $0.timeIntervalSinceNow <= 300 } ?? false } ?? true

        if needsKeychain {
            guard let read = readClaudeTokenInfo(userInitiated: userInitiated && !hookFresh) else {
                // No prompt-free source had a usable token. We deliberately did NOT read Claude
                // Code's keychain item in the background; opening Mimir (a user action) will.
                let note = userInitiated
                    ? String(localized: "claude token missing")
                    : String(localized: "open Mimir to refresh Claude")
                return claudeFailure(note: note)
            }
            tokenInfo = read

            // Mimir does NOT refresh Claude Code's OAuth token. Anthropic rotates the refresh token
            // single-use, so refreshing here consumes the token Claude Code still holds and logs it
            // out. We only READ whatever token Claude Code currently has and use it while valid;
            // once it's actually expired, Claude Code refreshes it on its own next use — Mimir just
            // asks the user to open it. ponytail: not our token to rotate — read-only is the safe
            // posture (the 30s buffer keeps a token from dying mid-request).
            if let exp = read.expiresAt, exp.timeIntervalSinceNow <= 30 {
                // Token is dead — but DON'T arm a fetch cooldown. The cooldown makes the store skip
                // fetchClaude entirely (LiveUsageDataSource: `skip.contains("Claude")` → snapshotOrFallback),
                // and with it the prompt-free hook read — which froze the card on a stale snapshot even
                // after Claude Code wrote fresh hook numbers. We make NO network call with a dead token,
                // so there's nothing to rate-limit; fall straight to claudeFailure, which reads the fresh
                // hook every tick and shows live session/weekly numbers without a prompt.
                let note = String(localized: "token expired — open Claude Code")
                return claudeFailure(note: note, staleNote: note)
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
        // Prompt-free statusLine hook first — the live session/weekly numbers Claude Code itself
        // renders, available without a token, so a background tick whose Mimir token cache expired (or
        // any live-fetch failure) stays fresh instead of falling to "open Mimir to refresh". Fresher
        // than the 24h cache/snapshot below, so it wins.
        if let hook = readClaudeHookUsage(maxAge: 30 * 60) {
            let card = claudeCardFromHook(hook)
            saveSnapshot(card)
            return card
        }
        // Recent cache → normal card (seed a snapshot so the cooldown/skip path can serve it too).
        // This is a failure fallback, so reset-classify it (`live: false`): a window that refilled
        // since this cache was written shouldn't show a phantom percent.
        if let cached = readClaudeUsageCache(maxAge: 24 * 60 * 60) {
            let status = buildClaudeStatus(from: cached, note: note, live: false)
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

    /// Build a Claude card from the usage JSON. `live` (the API success path and the <5 min cache)
    /// trusts the percents as-is; the stale fallbacks (24h cache / snapshot) pass `live: false` to
    /// reset-classify — there a window whose reset has passed is blanked because it really refilled.
    func buildClaudeStatus(from root: [String: Any], note: String, live: Bool = true) -> ServiceStatus {
        let fiveHour = mergeClaudeWindows(root: root, baseKey: "five_hour")
        let sevenDay = mergeClaudeWindows(root: root, baseKey: "seven_day")

        // Per-model weekly rows (e.g. "Fable") now come from the `limits` array, keyed by
        // `scope.model.display_name` — not the old flat `seven_day_<model>` keys, which the API
        // has stopped populating (they read back as null). Reading the array generically means a
        // new model tier shows up with no code change, instead of needing another hardcoded key
        // every time Anthropic ships one.
        var models: [ModelStatus] = claudeScopedModelRows(root["limits"], weeklyResetAt: sevenDay.resetAt)
        if let billing = claudeBillingRow(root) {
            models.append(billing)
        }

        let sessionPct = remainingPercent(fromUsed: fiveHour.utilization)
        let weeklyPct = remainingPercent(fromUsed: sevenDay.utilization)

        // Live data is authoritative: trust the percents even if a window's reset has *just* lapsed.
        // Right after a 5-hour boundary the API briefly returns the old window's `resets_at` (already
        // past) before rolling to the next; reset-classifying that — as we do for genuinely stale
        // cache — would blank the whole session, so Claude's card and widget vanish for a few minutes.
        if live {
            return ServiceStatus(
                name: "Claude", iconName: "claude",
                sessionResetAt: fiveHour.resetAt, weeklyResetAt: sevenDay.resetAt,
                sessionRemainingPercent: sessionPct, weeklyRemainingPercent: weeklyPct,
                models: models, isAvailable: true, statusNote: note)
        }

        // Stale fallback: a window whose reset has already passed is blanked (it refilled) rather than
        // shown as if current.
        return staleClassifiedCard(
            name: "Claude", iconName: "claude",
            sessionPct: sessionPct, sessionReset: fiveHour.resetAt,
            weeklyPct: weeklyPct, weeklyReset: sevenDay.resetAt,
            models: models, freshNote: note, staleNote: note)
            ?? unavailableService(name: "Claude", iconName: "claude", models: [], note: note)
    }
    /// One row per weekly-scoped model in the `limits` array (e.g. `{"kind": "weekly_scoped",
    /// "group": "weekly", "percent": 66, "scope": {"model": {"display_name": "Fable"}}}`). The
    /// array is already presentation-ordered by the API, so rows are emitted in that order. When a
    /// scoped entry omits its own `resets_at`, fall back to the account-wide weekly reset since they
    /// reset together (mirrors the old Sonnet-specific fallback).
    private func claudeScopedModelRows(_ raw: Any?, weeklyResetAt: Date?) -> [ModelStatus] {
        guard let limits = raw as? [[String: Any]] else { return [] }
        return limits.compactMap { entry -> ModelStatus? in
            guard entry["group"] as? String == "weekly",
                  let scope = entry["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let displayName = model["display_name"] as? String else { return nil }
            let percent = doubleValue(entry["percent"]) ?? 0
            let resetAt = (entry["resets_at"] as? String).flatMap(parseISO8601) ?? weeklyResetAt
            return ModelStatus(name: displayName, remainingPercent: remainingPercent(fromUsed: percent), resetAt: resetAt)
        }
    }

    /// Billing/credits row. Prefers the new `spend` object (richer: cap, balance, auto_reload,
    /// disclaimer) and falls back to the legacy `extra_usage` shape for accounts the API hasn't
    /// migrated yet — both are read defensively since neither's rollout is guaranteed complete.
    private func claudeBillingRow(_ root: [String: Any]) -> ModelStatus? {
        if let spend = root["spend"] as? [String: Any], spend["enabled"] as? Bool == true {
            return claudeSpendBillingRow(spend)
        }
        return claudeLegacyBillingRow(root["extra_usage"])
    }

    private func claudeSpendBillingRow(_ spend: [String: Any]) -> ModelStatus? {
        guard let usedObj = spend["used"] as? [String: Any] else { return nil }
        let exponent = (usedObj["exponent"] as? Int) ?? 2
        let scale = pow(10, Double(exponent))
        let used = (doubleValue(usedObj["amount_minor"]) ?? 0) / scale
        let cur = (usedObj["currency"] as? String)?.uppercased() ?? ""
        let limit = (spend["limit"] as? [String: Any]).flatMap { doubleValue($0["amount_minor"]) }.map { $0 / scale }
        func money(_ v: Double) -> String {
            let n = v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(format: "%.2f", v)
            return cur.isEmpty ? n : "\(n) \(cur)"
        }
        let text = limit.map { "\(money(used)) / \(money($0))" } ?? money(used)
        let util = doubleValue(spend["percent"]) ?? (limit.map { $0 > 0 ? used / $0 * 100 : 0 } ?? 0)
        return ModelStatus(name: String(localized: "Billing"), remainingPercent: 0, resetAt: nil,
                           valueText: text, isLow: util >= 80)
    }

    private func claudeLegacyBillingRow(_ raw: Any?) -> ModelStatus? {
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
        silentKeychain: () -> ClaudeToken?,
        keychain: () -> ClaudeToken?
    ) -> ClaudeToken? {
        if let file { return file }
        if let cached = mimirCache(), let exp = cached.expiresAt, exp.timeIntervalSince(now) > 300 {
            return cached
        }
        // A SILENT keychain read (interaction-not-allowed): returns a token only if Mimir was already
        // granted access to Claude Code's item, so even a background tick stays on LIVE data once the
        // user has allowed it once — and it never pops the macOS dialog (fails quietly otherwise).
        if let silent = silentKeychain() { return silent }
        // The one-time GRANT read can show the dialog, so it's reserved for a user action; a background
        // tick stops here and rides the prompt-free hook/usage cache instead of ever prompting.
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
            silentKeychain: {
                guard let raw = readClaudeKeychainItem(interactive: false) else { return nil }
                return parseClaudeToken(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            },
            keychain: {
                guard let raw = readClaudeKeychainItem(interactive: true) else { return nil }
                return parseClaudeToken(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            })
    }

    /// Claude Code's statusLine hook writes its own session JSON — including the official 5h/7d
    /// rate-limit numbers it already fetched server-side — to `~/.claude/mimir-usage.json` on every
    /// render (see `MimirStatusLineHook`). Reading that file is the prompt-free primary source for the
    /// session/weekly windows: no keychain, no token, no network. Returns nil when the file is absent,
    /// older than `maxAge`, malformed, or carries no `rate_limits` (older Claude Code / no subscription
    /// limits). Note `resets_at` here is epoch SECONDS (a number), unlike the OAuth API's ISO string.
    func readClaudeHookUsage(maxAge: TimeInterval)
        -> (five: (used: Double, reset: Date?), seven: (used: Double, reset: Date?))? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/mimir-usage.json")
        guard let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let mtime = vals.contentModificationDate,
              Date().timeIntervalSince(mtime) <= maxAge,
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Self.parseHookRateLimits(root)
    }

    /// Pure: pull the 5h/7d windows out of a statusLine JSON root. Both windows must be present (an
    /// account without subscription limits, or older Claude Code, omits `rate_limits`). `resets_at` is
    /// epoch SECONDS. Testable without the filesystem.
    static func parseHookRateLimits(_ root: [String: Any])
        -> (five: (used: Double, reset: Date?), seven: (used: Double, reset: Date?))? {
        guard let limits = root["rate_limits"] as? [String: Any] else { return nil }
        func window(_ key: String) -> (used: Double, reset: Date?)? {
            guard let obj = limits[key] as? [String: Any],
                  let used = doubleFromJSON(obj["used_percentage"]) else { return nil }
            let reset = doubleFromJSON(obj["resets_at"]).map { Date(timeIntervalSince1970: $0) }
            return (used, reset)
        }
        guard let five = window("five_hour"), let seven = window("seven_day") else { return nil }
        return (five, seven)
    }

    /// A JSON number (or numeric string) as Double — free function so `parseHookRateLimits` can stay
    /// `static` (the instance `doubleValue` isn't reachable from a static context).
    static func doubleFromJSON(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    /// Build Claude's card from the prompt-free statusLine hook. The fresh 5h/7d numbers come from the
    /// hook; the per-model rows (e.g. Fable) and the billing row are overlaid from the most recent
    /// OAuth usage cache (≤24h) so they still show — richer than the hook, and stale-safe because the
    /// hook's live session/weekly percents replace the cache's. When no recent cache exists, the card
    /// shows session/weekly only. ponytail: overlaid per-model rows are trusted within their weekly
    /// window; a real user open refreshes them live via the OAuth API.
    func claudeCardFromHook(_ hook: (five: (used: Double, reset: Date?), seven: (used: Double, reset: Date?))) -> ServiceStatus {
        var root = readClaudeUsageCache(maxAge: 24 * 60 * 60) ?? [:]
        let iso = ISO8601DateFormatter()
        func windowDict(_ w: (used: Double, reset: Date?)) -> [String: Any] {
            var d: [String: Any] = ["utilization": w.used]
            if let r = w.reset { d["resets_at"] = iso.string(from: r) }
            return d
        }
        // The hook's single 5h/7d reading is authoritative — drop any sub-keyed windows the cache
        // carried so `mergeClaudeWindows` can't pick a stale one over it.
        for k in root.keys where k == "five_hour" || k.hasPrefix("five_hour_")
            || k == "seven_day" || k.hasPrefix("seven_day_") { root.removeValue(forKey: k) }
        root["five_hour"] = windowDict(hook.five)
        root["seven_day"] = windowDict(hook.seven)
        return buildClaudeStatus(from: root, note: "statusline hook", live: true)
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
            try data.write(to: url, options: .atomic)
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
    /// Claude Code no longer keeps its login only under the exact legacy service name — newer
    /// versions write per-config items named "Claude Code-credentials-<hash>" and leave the legacy
    /// item behind with a dead token. List every matching item's ATTRIBUTES (no kSecReturnData, so
    /// this never pops the keychain prompt) and order newest-modified first: the item Claude Code
    /// last rewrote is the live login.
    static func claudeKeychainServicesOrdered(_ items: [(service: String, modifiedAt: Date?)]) -> [String] {
        items.filter { $0.service == claudeKeychainService || $0.service.hasPrefix("\(claudeKeychainService)-") }
            .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
            .map(\.service)
    }

    private func claudeKeychainCandidates() -> [(service: String, account: String?, modifiedAt: Date?)] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        let attrs = items.compactMap { dict -> (service: String, account: String?, modifiedAt: Date?)? in
            guard let service = dict[kSecAttrService as String] as? String else { return nil }
            return (service, dict[kSecAttrAccount as String] as? String,
                    dict[kSecAttrModificationDate as String] as? Date)
        }
        let ordered = Self.claudeKeychainServicesOrdered(attrs.map { ($0.service, $0.modifiedAt) })
        return ordered.compactMap { service in
            attrs.first { $0.service == service }
        }
    }

    /// Modification date of the keychain item we last attempted a DATA read on. Reading data is the
    /// only prompting op, so we skip it while the item is unchanged since our last attempt — the token
    /// hasn't rotated, so re-reading would only re-prompt (and, if it was already rejected, 401 again).
    /// Advisory single-writer-ish state; a rare race costs at most one extra read, never correctness.
    nonisolated(unsafe) private static var lastKeychainReadMdate: Date?

    /// Read the DATA of a SINGLE Claude Code keychain item — the newest-modified one, which is the
    /// login Claude Code last wrote (on macOS normally the plain "Claude Code-credentials"). Reading an
    /// item's data pops the macOS permission prompt when Mimir isn't in that item's ACL, so we read
    /// exactly ONE item: one prompt, not one per item. Looping data-reads over every candidate (24+
    /// stale per-config items on a long-lived machine) fired a prompt for each until one parsed — a
    /// storm — and because each item has its own ACL, the user's "Always Allow" on one never covered
    /// the next, so the storm never stopped. Reading the same single item every time means one
    /// "Always Allow" sticks (grant tied to Mimir's stable release signature). If it doesn't parse we
    /// return nil rather than reach for the next item: the prompt-free hook/usage cache already carry
    /// the card, so a missed enrichment is far cheaper than a prompt storm.
    private func readClaudeKeychainItem(interactive: Bool) -> String? {
        guard let candidate = claudeKeychainCandidates().first else { return nil }
        let query: [String: Any] = {
            var q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: candidate.service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            // A background read attaches an interaction-not-allowed context: if Mimir is already in the
            // item's ACL (the user granted once) the read succeeds SILENTLY and keeps the card on live
            // data; if not, it fails with errSecInteractionNotAllowed — never a prompt. Verified: this
            // suppresses the macOS keychain dialog. The prompting (grant) read is reserved for a user
            // action (opening Mimir), so a background tick can never pop the dialog.
            if !interactive {
                let ctx = LAContext()
                ctx.interactionNotAllowed = true
                q[kSecUseAuthenticationContext as String] = ctx
            }
            return q
        }()

        // The mdate gate applies only to the interactive (prompting) read: don't re-pop the dialog for
        // a token we've already tried — only when Claude Code rotates it (its item's mtime advances).
        // Silent reads never prompt, so they're free to run every tick (gated instead by the token
        // caches upstream) and pick up a freshly rotated token the moment it lands.
        if interactive {
            if let last = Self.lastKeychainReadMdate, let mdate = candidate.modifiedAt, mdate <= last {
                return nil
            }
            Self.lastKeychainReadMdate = candidate.modifiedAt
        }

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              parseClaudeToken(value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else {
            return nil
        }
        return value
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
}
