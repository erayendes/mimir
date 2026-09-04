import Foundation

extension LiveUsageDataSource {
    func fetchCodex() async -> ServiceStatus {
        if let apiStatus = await fetchCodexUsageAPI() {
            saveSnapshot(apiStatus)
            return apiStatus
        }

        let local = fetchCodexLocalSessions()
        if local.isAvailable {
            saveSnapshot(local)
            return local
        }

        // Both live sources failed — show the last-known snapshot instead of vanishing.
        return loadSnapshot(for: "Codex", iconName: "codex") ?? local
    }

    private func fetchCodexLocalSessions() -> ServiceStatus {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let file = latestJSONLFile(in: base),
              let text = try? String(contentsOf: file, encoding: .utf8) else {
            return unavailableService(name: "Codex", iconName: "codex", models: [])
        }

        let lines = text.split(separator: "\n").reversed()
        var sessionRemaining: Int?
        var weeklyRemaining: Int?
        var sessionReset: Date?
        var weeklyReset: Date?
        var weeklyWindow: TimeInterval?

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONDecoder().decode(CodexSessionRecord.self, from: data),
                  record.type == "event_msg",
                  record.payload?.type == "token_count",
                  let rl = record.payload?.rate_limits else { continue }

            // Classify each window by its real length, not its slot (see codexStatus): a window of
            // <= 6h is the 5-hour session, anything longer is the weekly one. Since July 2026 the
            // sole window OpenAI returns can be the weekly one (window_minutes 10080), so "primary"
            // no longer implies "5-hour".
            let now = Date()
            for (w, slotIsPrimary) in [(rl.primary, true), (rl.secondary, false)] {
                guard let w, let summary = summarizeCodexWindow(w, now: now) else { continue }
                let periodSeconds = w.window_minutes.map { Double($0) * 60 }
                let isSession = codexWindowIsSession(periodSeconds: periodSeconds,
                                                     resetAt: summary.resetAt,
                                                     slotIsPrimary: slotIsPrimary, now: now)
                if isSession, sessionRemaining == nil {
                    sessionRemaining = remainingPercent(fromUsed: summary.usedPercent)
                    sessionReset = summary.resetAt
                } else if weeklyRemaining == nil {
                    weeklyRemaining = remainingPercent(fromUsed: summary.usedPercent)
                    weeklyReset = summary.resetAt
                    // Keep the real length so the UI can label a 30-day (Go plan) window correctly.
                    weeklyWindow = periodSeconds
                }
            }

            if sessionRemaining != nil && weeklyRemaining != nil { break }
        }

        guard sessionRemaining != nil || weeklyRemaining != nil else {
            return unavailableService(name: "Codex", iconName: "codex", models: [])
        }

        let statusNote = sessionReset == nil
            ? "local .codex sessions (reset time not found in file)"
            : "local .codex sessions"

        // A window that isn't present stays nil (no misleading "100%"): when there's no 5-hour window
        // the popover drops the 5s block and promotes the weekly reading instead (see PopoverViews).
        return ServiceStatus(
            name: "Codex",
            iconName: "codex",
            sessionResetAt: sessionReset,
            weeklyResetAt: weeklyReset,
            sessionRemainingPercent: sessionRemaining,
            weeklyRemainingPercent: weeklyRemaining,
            weeklyWindowSeconds: weeklyWindow,
            models: [],
            isAvailable: true,
            statusNote: statusNote
        )
    }

    private func fetchCodexUsageAPI() async -> ServiceStatus? {
        guard let authState = readCodexAuthState(),
              let accessToken = await codexAccessToken(from: authState) else {
            return nil
        }

        if let status = await fetchCodexUsageAPI(accessToken: accessToken, accountID: codexAccountID(from: authState.auth)) {
            return status
        }

        guard let refreshed = await refreshCodexAccessToken(authState: authState) else {
            return nil
        }

        return await fetchCodexUsageAPI(accessToken: refreshed, accountID: codexAccountID(from: authState.auth))
    }

    private func fetchCodexUsageAPI(accessToken: String, accountID: String?) async -> ServiceStatus? {
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!, timeoutInterval: 10)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Mimir", forHTTPHeaderField: "User-Agent")
        if let accountID, !accountID.isEmpty {
            req.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse).map({ 200 ... 299 ~= $0.statusCode }) == true,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  root["rate_limit"] is [String: Any] else {
                return nil
            }
            let resetRow = await fetchCodexResetCredits(accessToken: accessToken, accountID: accountID)
            return codexStatus(fromUsageRoot: root, extraRows: resetRow.map { [$0] } ?? [])
        } catch {
            return nil
        }
    }

    /// Build the Codex `ServiceStatus` from a parsed `wham/usage` response root. Pure (no I/O) so it's
    /// unit-testable. Classifies each present window by its real PERIOD, not its slot: OpenAI
    /// temporarily removed Codex's 5-hour limit in July 2026, so the sole window it now returns can be
    /// the WEEKLY one sitting in the `primary_window` slot (limit_window_seconds 604800) — "primary" no
    /// longer implies "5-hour". A window of <= 6h is the 5-hour session, anything longer is the weekly
    /// one; see `codexWindowIsSession` for what happens when the period field is missing. An absent
    /// window stays nil (no misleading "100%"). If the 5h window returns later, it's the session again.
    func codexStatus(fromUsageRoot root: [String: Any], now: Date = Date(), extraRows: [ModelStatus] = []) -> ServiceStatus {
        let rateLimit = root["rate_limit"] as? [String: Any] ?? [:]

        var session: (percent: Int, resetAt: Date?)?
        var weekly: (percent: Int, resetAt: Date?)?
        var weeklyWindow: TimeInterval?
        for (raw, slotIsPrimary) in [(rateLimit["primary_window"], true), (rateLimit["secondary_window"], false)] {
            guard let obj = raw as? [String: Any] else { continue }
            let window = codexAPIWindow(obj)
            let percent = window.usedPercent.map(remainingPercent(fromUsed:)) ?? 100
            let periodSeconds = doubleValue(obj["limit_window_seconds"])
            let isSession = codexWindowIsSession(periodSeconds: periodSeconds,
                                                 resetAt: window.resetAt,
                                                 slotIsPrimary: slotIsPrimary, now: now)
            // A second window that also reads as the session lands in the weekly slot rather than
            // being dropped — better a slightly mislabelled reading than a missing one.
            if isSession, session == nil {
                session = (percent, window.resetAt)
            } else if weekly == nil {
                weekly = (percent, window.resetAt)
                // Keep the real length so the UI can label a 30-day (Go plan) window correctly.
                weeklyWindow = periodSeconds
            }
        }

        return ServiceStatus(
            name: "Codex",
            iconName: "codex",
            sessionResetAt: session?.resetAt,
            weeklyResetAt: weekly?.resetAt,
            sessionRemainingPercent: session?.percent,
            weeklyRemainingPercent: weekly?.percent,
            weeklyWindowSeconds: weeklyWindow,
            models: (codexCreditRow(root["credits"]).map { [$0] } ?? []) + extraRows,
            isAvailable: true,
            statusNote: "chatgpt usage api"
        )
    }

    /// Codex premium credit balance from `wham/usage` `credits: { has_credits, unlimited, balance }`.
    /// Returns nil for free/Plus accounts with no credits, so the row is simply omitted.
    private func codexCreditRow(_ raw: Any?) -> ModelStatus? {
        guard let c = raw as? [String: Any] else { return nil }
        let label = String(localized: "Credit balance")
        if c["unlimited"] as? Bool == true {
            return ModelStatus(name: label, remainingPercent: 0, resetAt: nil,
                               valueText: String(localized: "Unlimited"), symbol: "dollarsign.circle")
        }
        guard c["has_credits"] as? Bool == true else { return nil }
        let amount = (c["balance"] as? String).flatMap(Double.init) ?? doubleValue(c["balance"]) ?? 0
        guard amount > 0 else { return nil }
        let text = amount.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(amount)) : String(amount)
        return ModelStatus(name: label, remainingPercent: 0, resetAt: nil,
                           valueText: String(format: String(localized: "%@ credits"), text), isLow: amount < 5,
                           symbol: "dollarsign.circle")
    }

    /// Reset credits ("sıfırlama hakkı") from `wham/rate-limit-reset-credits`: one-shot passes that
    /// clear a spent rate-limit window. Only credits still available AND not yet expired count — a
    /// credit can lapse between polls, and `available_count` doesn't re-check that.
    /// Returns nil when there are none, so the row is simply omitted.
    func codexResetCreditRow(fromRoot root: [String: Any], now: Date = Date()) -> ModelStatus? {
        let credits = (root["credits"] as? [[String: Any]] ?? []).compactMap { item -> Date? in
            guard (item["status"] as? String)?.lowercased() == "available",
                  let raw = item["expires_at"] as? String,
                  let expiresAt = parseISO8601(raw), expiresAt > now else { return nil }
            return expiresAt
        }
        guard !credits.isEmpty else { return nil }
        let earliest = credits.min()
        let caption = earliest.map {
            String(format: String(localized: "first expires in %@"), TimeFormatter.duration(from: $0.timeIntervalSince(now)))
        }
        // `resetAt` carries the earliest expiry: the value row doesn't draw it, but the expiry
        // warning reads it from here rather than the row's already-formatted caption.
        return ModelStatus(name: String(localized: "Reset credits"), remainingPercent: 0, resetAt: earliest,
                           valueText: String(credits.count), caption: caption, symbol: "arrow.clockwise")
    }

    /// GET the reset-credit endpoint with the same auth as `wham/usage`. Failure returns nil and the
    /// row is dropped — this is a bonus reading, never a reason to fail the whole Codex fetch.
    private func fetchCodexResetCredits(accessToken: String, accountID: String?) async -> ModelStatus? {
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!,
                             timeoutInterval: 10)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Mimir", forHTTPHeaderField: "User-Agent")
        if let accountID, !accountID.isEmpty {
            req.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse).map({ 200 ... 299 ~= $0.statusCode }) == true,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return codexResetCreditRow(fromRoot: root)
    }
    private func summarizeCodexWindow(_ window: CodexRateWindow?, now: Date) -> CodexWindowSummary? {
        guard let window else { return nil }
        let used = window.used_percent ?? 0
        guard let resetEpoch = window.resets_at else {
            return CodexWindowSummary(usedPercent: used, resetAt: nil)
        }

        var reset = Date(timeIntervalSince1970: TimeInterval(resetEpoch))
        if reset <= now, let mins = window.window_minutes, mins > 0 {
            while reset <= now {
                reset = reset.addingTimeInterval(TimeInterval(mins * 60))
            }
            return CodexWindowSummary(usedPercent: 0, resetAt: reset)
        }
        if reset <= now {
            return CodexWindowSummary(usedPercent: 0, resetAt: nil)
        }
        return CodexWindowSummary(usedPercent: used, resetAt: reset)
    }

    func codexAPIWindow(_ raw: Any?) -> (usedPercent: Double?, resetAt: Date?) {
        guard let obj = raw as? [String: Any] else {
            return (nil, nil)
        }

        let used = doubleValue(obj["used_percent"])
        // The reset epoch has appeared under both spellings across Codex surfaces (`reset_at` in the
        // usage API, `resets_at` in the session files), so accept either rather than silently losing
        // the countdown if this response switches.
        let resetEpoch = doubleValue(obj["reset_at"]) ?? doubleValue(obj["resets_at"])
        return (used, resetEpoch.map { Date(timeIntervalSince1970: $0) })
    }

    /// Is this rate-limit window the 5-hour session (vs the weekly one)? Decided by the window's real
    /// PERIOD — "primary" no longer implies "5-hour" (see `codexStatus`). The period field is the only
    /// reliable signal, so when it's absent fall back to how far the reset is: a 5-hour window can
    /// never reset more than 5h out. That fallback misreads a weekly window in its final hours, which
    /// is still better than trusting the slot; the slot is the last resort.
    func codexWindowIsSession(periodSeconds: Double?, resetAt: Date?, slotIsPrimary: Bool, now: Date) -> Bool {
        if let periodSeconds { return periodSeconds <= 6 * 3600 }
        if let resetAt, resetAt > now { return resetAt.timeIntervalSince(now) <= 8 * 3600 }
        return slotIsPrimary
    }

    private func readCodexAuthState() -> CodexAuthState? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths: [URL] = []
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"],
           !codexHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            paths.append(URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json"))
        }
        paths.append(home.appendingPathComponent(".codex/auth.json"))
        paths.append(home.appendingPathComponent(".config/codex/auth.json"))

        for path in paths {
            guard let data = try? Data(contentsOf: path),
                  let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  codexAccessToken(in: auth) != nil || codexRefreshToken(in: auth) != nil else {
                continue
            }
            return CodexAuthState(path: path, auth: auth)
        }
        return nil
    }

    private func codexAccessToken(from state: CodexAuthState) async -> String? {
        guard let accessToken = codexAccessToken(in: state.auth) else {
            return await refreshCodexAccessToken(authState: state)
        }

        if let expiresAt = jwtExpiry(accessToken), expiresAt.timeIntervalSinceNow <= 300 {
            return await refreshCodexAccessToken(authState: state) ?? accessToken
        }
        return accessToken
    }

    private func codexAccessToken(in auth: [String: Any]) -> String? {
        if let token = auth["access_token"] as? String, !token.isEmpty { return token }
        if let tokens = auth["tokens"] as? [String: Any],
           let token = tokens["access_token"] as? String,
           !token.isEmpty {
            return token
        }
        return nil
    }

    private func codexRefreshToken(in auth: [String: Any]) -> String? {
        if let token = auth["refresh_token"] as? String, !token.isEmpty { return token }
        if let tokens = auth["tokens"] as? [String: Any],
           let token = tokens["refresh_token"] as? String,
           !token.isEmpty {
            return token
        }
        return nil
    }

    private func codexAccountID(from auth: [String: Any]) -> String? {
        if let accountID = auth["account_id"] as? String, !accountID.isEmpty { return accountID }
        if let tokens = auth["tokens"] as? [String: Any] {
            if let accountID = tokens["account_id"] as? String, !accountID.isEmpty { return accountID }
            if let idToken = tokens["id_token"] as? String,
               let accountID = codexAccountID(fromJWT: idToken) {
                return accountID
            }
        }
        if let idToken = auth["id_token"] as? String,
           let accountID = codexAccountID(fromJWT: idToken) {
            return accountID
        }
        return nil
    }

    private func codexAccountID(fromJWT token: String) -> String? {
        guard let payload = decodeJWTPayload(token),
              let auth = payload["https://api.openai.com/auth"] as? [String: Any],
              let accountID = auth["chatgpt_account_id"] as? String,
              !accountID.isEmpty else {
            return nil
        }
        return accountID
    }

    private func refreshCodexAccessToken(authState: CodexAuthState) async -> String? {
        guard let refreshToken = codexRefreshToken(in: authState.auth) else {
            return codexAccessToken(in: authState.auth)
        }

        var req = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "grant_type": "refresh_token",
            "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
            "refresh_token": refreshToken
        ]
            .map { "\($0.key)=\(urlEncode($0.value))" }
            .joined(separator: "&")
        req.httpBody = body.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse).map({ 200 ... 299 ~= $0.statusCode }) == true,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = root["access_token"] as? String,
                  !accessToken.isEmpty else {
                return codexAccessToken(in: authState.auth)
            }
            writeCodexAuth(existing: authState, refreshed: root)
            return accessToken
        } catch {
            return codexAccessToken(in: authState.auth)
        }
    }

    private func writeCodexAuth(existing state: CodexAuthState, refreshed: [String: Any]) {
        var auth = state.auth
        var tokens = auth["tokens"] as? [String: Any] ?? [:]
        if let token = refreshed["access_token"] as? String {
            tokens["access_token"] = token
            auth["access_token"] = token
        }
        if let token = refreshed["refresh_token"] as? String {
            tokens["refresh_token"] = token
            auth["refresh_token"] = token
        }
        if let token = refreshed["id_token"] as? String {
            tokens["id_token"] = token
            auth["id_token"] = token
        }
        if !tokens.isEmpty {
            auth["tokens"] = tokens
        }
        auth["last_refresh"] = ISO8601DateFormatter().string(from: Date())

        guard JSONSerialization.isValidJSONObject(auth),
              let data = try? JSONSerialization.data(withJSONObject: auth, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        // Token file → secure atomic write so the refreshed token never sits in a 0644 file between
        // write and chmod (TOCTOU). Replaces write(.atomic) + setAttributes.
        try? Self.secureAtomicWrite(data: data, to: state.path, permissions: 0o600)
    }
}

private struct CodexSessionRecord: Decodable {
    let type: String?
    let payload: CodexPayload?
}

private struct CodexPayload: Decodable {
    let type: String?
    let rate_limits: CodexRateLimits?
}

private struct CodexRateLimits: Decodable {
    let limit_id: String?
    let primary: CodexRateWindow?
    let secondary: CodexRateWindow?
}

private struct CodexRateWindow: Decodable {
    let used_percent: Double?
    let window_minutes: Int?
    let resets_at: Int?
}

private struct CodexAuthState {
    let path: URL
    let auth: [String: Any]
}

private struct CodexWindowSummary {
    let usedPercent: Double
    let resetAt: Date?
}

