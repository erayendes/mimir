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

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONDecoder().decode(CodexSessionRecord.self, from: data),
                  record.type == "event_msg",
                  record.payload?.type == "token_count",
                  let rl = record.payload?.rate_limits else { continue }

            if let p = rl.primary, let summary = summarizeCodexWindow(p, now: Date()) {
                if sessionRemaining == nil { sessionRemaining = remainingPercent(fromUsed: summary.usedPercent) }
                if sessionReset == nil { sessionReset = summary.resetAt }
            }

            if let s = rl.secondary, let summary = summarizeCodexWindow(s, now: Date()) {
                if weeklyRemaining == nil { weeklyRemaining = remainingPercent(fromUsed: summary.usedPercent) }
                if weeklyReset == nil { weeklyReset = summary.resetAt }
            }

            if sessionRemaining != nil && weeklyRemaining != nil && sessionReset != nil && weeklyReset != nil { break }
        }

        guard sessionRemaining != nil || weeklyRemaining != nil else {
            return unavailableService(name: "Codex", iconName: "codex", models: [])
        }

        let statusNote = sessionReset == nil
            ? "local .codex sessions (reset time not found in file)"
            : "local .codex sessions"

        return ServiceStatus(
            name: "Codex",
            iconName: "codex",
            sessionResetAt: sessionReset,
            weeklyResetAt: weeklyReset,
            sessionRemainingPercent: sessionRemaining ?? 100,
            weeklyRemainingPercent: weeklyRemaining ?? 100,
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
                  let rateLimit = root["rate_limit"] as? [String: Any] else {
                return nil
            }

            let session = codexAPIWindow(rateLimit["primary_window"])
            let weekly = codexAPIWindow(rateLimit["secondary_window"])

            return ServiceStatus(
                name: "Codex",
                iconName: "codex",
                sessionResetAt: session.resetAt,
                weeklyResetAt: weekly.resetAt,
                sessionRemainingPercent: session.usedPercent.map(remainingPercent(fromUsed:)) ?? 100,
                weeklyRemainingPercent: weekly.usedPercent.map(remainingPercent(fromUsed:)) ?? 100,
                models: codexCreditRow(root["credits"]).map { [$0] } ?? [],
                isAvailable: true,
                statusNote: "chatgpt usage api"
            )
        } catch {
            return nil
        }
    }

    /// Codex premium credit balance from `wham/usage` `credits: { has_credits, unlimited, balance }`.
    /// Returns nil for free/Plus accounts with no credits, so the row is simply omitted.
    private func codexCreditRow(_ raw: Any?) -> ModelStatus? {
        guard let c = raw as? [String: Any] else { return nil }
        if c["unlimited"] as? Bool == true {
            return ModelStatus(name: String(localized: "Credits"), remainingPercent: 0, resetAt: nil, valueText: String(localized: "Unlimited"))
        }
        guard c["has_credits"] as? Bool == true else { return nil }
        let amount = (c["balance"] as? String).flatMap(Double.init) ?? doubleValue(c["balance"]) ?? 0
        guard amount > 0 else { return nil }
        let text = amount.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(amount)) : String(amount)
        return ModelStatus(name: String(localized: "Credits"), remainingPercent: 0, resetAt: nil,
                           valueText: String(format: String(localized: "%@ credits"), text), isLow: amount < 5)
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
        let reset = doubleValue(obj["reset_at"]).map { Date(timeIntervalSince1970: $0) }
        return (used, reset)
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
        try? LiveUsageDataSource.secureAtomicWrite(data: data, to: state.path, permissions: 0o600)
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

