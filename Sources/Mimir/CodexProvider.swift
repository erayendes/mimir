import Foundation

extension LiveUsageDataSource {
    /// `home` is a second login's `CODEX_HOME` (see `ExtraAccount`); nil is the main one.
    func fetchCodex(name: String = "Codex", home: URL? = nil) async -> ServiceStatus {
        let account = codexAccount(home: home)
        if let apiStatus = await fetchCodexUsageAPI(name: name, home: home)?.withAccount(account) {
            saveSnapshot(apiStatus)
            return apiStatus
        }

        let local = fetchCodexLocalSessions(name: name, home: home).withAccount(account)
        if local.isAvailable {
            saveSnapshot(local)
            return local
        }

        // Mimir never refreshes Codex's token (see `codexAccessToken(from:)`), so an expired one
        // stays expired until the user runs the CLI. Say that, rather than leaving them with a
        // silently ageing snapshot and no idea what to do about it.
        let note = codexTokenExpired(home: home) ? String(localized: "token expired — run codex login") : nil
        // Both live sources failed — show the last-known snapshot instead of vanishing.
        let snapshot = loadSnapshot(for: name, iconName: "codex",
                                    staleNote: note ?? String(localized: "out of date"))
        return snapshot?.withAccount(account) ?? local
    }

    /// The login a Codex home holds — e-mail, plan and ChatGPT account id from its `id_token`. Local
    /// file only; nil when the dir has no usable login.
    func codexAccount(home: URL?) -> AccountInfo? {
        guard let auth = readCodexAuthState(home: home)?.auth else { return nil }
        let idToken = (auth["tokens"] as? [String: Any])?["id_token"] as? String ?? auth["id_token"] as? String
        let claims = idToken.flatMap(decodeJWTPayload)
        let openai = claims?["https://api.openai.com/auth"] as? [String: Any]
        return AccountInfo(plan: AccountInfo.codexPlan(openai?["chatgpt_plan_type"] as? String),
                           email: claims?["email"] as? String,
                           id: codexAccountID(from: auth))
    }

    /// Set by the token read: the CLI is logged in, but the token it holds has run out.
    private func codexTokenExpired(home: URL?) -> Bool {
        guard let state = readCodexAuthState(home: home), let token = codexAccessToken(in: state.auth) else { return false }
        return jwtExpiry(token).map { $0.timeIntervalSinceNow <= 30 } ?? false
    }

    private func fetchCodexLocalSessions(name: String, home: URL?) -> ServiceStatus {
        let base = (home ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
            .appendingPathComponent("sessions")
        guard let file = latestJSONLFile(in: base),
              let text = try? String(contentsOf: file, encoding: .utf8) else {
            return unavailableService(name: name, iconName: "codex", models: [])
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
            return unavailableService(name: name, iconName: "codex", models: [])
        }

        let statusNote = sessionReset == nil
            ? "local .codex sessions (reset time not found in file)"
            : "local .codex sessions"

        // A window that isn't present stays nil (no misleading "100%"): when there's no 5-hour window
        // the popover drops the 5s block and promotes the weekly reading instead (see PopoverViews).
        return ServiceStatus(
            name: name,
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

    private func fetchCodexUsageAPI(name: String, home: URL?) async -> ServiceStatus? {
        guard let authState = readCodexAuthState(home: home),
              let accessToken = codexAccessToken(from: authState) else {
            return nil
        }

        return await fetchCodexUsageAPI(name: name, accessToken: accessToken,
                                        accountID: codexAccountID(from: authState.auth))
    }

    private func fetchCodexUsageAPI(name: String, accessToken: String, accountID: String?) async -> ServiceStatus? {
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
            Self.recordCodexShape(root)
            let resetRows = await fetchCodexResetCredits(accessToken: accessToken, accountID: accountID)
            return codexStatus(fromUsageRoot: root, extraRows: resetRows, name: name)
        } catch {
            return nil
        }
    }

    // ponytail: temporary probe for #77 (Luna Reserve) — local builds only. Records the *shape* of
    // `wham/usage` (key paths, and the short enum-like strings under name/type/banner/model/plan
    // keys) each time it changes, so the reserve quota's fields can be read off a real response the
    // day the main quota runs out. No token, no ids, no numbers. Delete once #77 is decided.
    nonisolated(unsafe) private static var lastCodexShape = ""

    private static func recordCodexShape(_ root: [String: Any]) {
        guard Telemetry.isDevBuild else { return }
        var lines: [String] = []
        func walk(_ value: Any, _ path: String) {
            switch value {
            case let dict as [String: Any]:
                for key in dict.keys.sorted() { walk(dict[key]!, path.isEmpty ? key : "\(path).\(key)") }
            case let array as [Any]:
                if array.isEmpty { lines.append("\(path)[] empty") }
                for item in array { walk(item, "\(path)[]") }
            case let text as String:
                let key = path.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
                let enumLike = ["name", "type", "banner", "model", "plan", "reason", "status"]
                    .contains { key.contains($0) } && text.count <= 40
                lines.append("\(path) = \(enumLike ? "\"\(text)\"" : "<string>")")
            case is NSNull:
                lines.append("\(path) = null")
            default:
                lines.append("\(path) = <\(type(of: value))>")
            }
        }
        walk(root, "")
        let shape = Array(Set(lines)).sorted().joined(separator: "\n")
        guard shape != lastCodexShape else { return }
        lastCodexShape = shape
        let url = LiveUsageDataSource.supportDirectory.appendingPathComponent("codex-shape.log")
        let entry = "=== \(ISO8601DateFormatter().string(from: Date()))\n\(shape)\n\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(entry.utf8)); try? handle.close()
        } else {
            try? entry.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Build the Codex `ServiceStatus` from a parsed `wham/usage` response root. Pure (no I/O) so it's
    /// unit-testable. Classifies each present window by its real PERIOD, not its slot: OpenAI
    /// temporarily removed Codex's 5-hour limit in July 2026, so the sole window it now returns can be
    /// the WEEKLY one sitting in the `primary_window` slot (limit_window_seconds 604800) — "primary" no
    /// longer implies "5-hour". A window of <= 6h is the 5-hour session, anything longer is the weekly
    /// one; see `codexWindowIsSession` for what happens when the period field is missing. An absent
    /// window stays nil (no misleading "100%"). If the 5h window returns later, it's the session again.
    func codexStatus(fromUsageRoot root: [String: Any], now: Date = Date(), extraRows: [ModelStatus] = [],
                     name: String = "Codex") -> ServiceStatus {
        let (session, weekly, weeklyWindow) = codexWindows(root["rate_limit"] as? [String: Any] ?? [:], now: now)

        return ServiceStatus(
            name: name,
            iconName: "codex",
            sessionResetAt: session?.resetAt,
            weeklyResetAt: weekly?.resetAt,
            sessionRemainingPercent: session.flatMap(\.percent),
            weeklyRemainingPercent: weekly.flatMap(\.percent),
            weeklyWindowSeconds: weeklyWindow,
            models: (codexCreditRow(root["credits"]).map { [$0] } ?? []) + extraRows
                + codexAdditionalLimitRows(root["additional_rate_limits"], now: now),
            isAvailable: true,
            statusNote: "chatgpt usage api"
        )
    }

    /// Marks the rows that are a separate quota of their own, drawn as their own panel on the card.
    static let codexExtraLimitGroup = "codex.additional-limit"

    /// `additional_rate_limits`: quotas that sit beside the plan's own — Luna Reserve, the fallback
    /// model Codex moves you to once the main quota is spent, or a model-specific limit. Each entry
    /// is `{ limit_name, metered_feature, rate_limit: { primary_window, secondary_window } }`, the
    /// same window shape as the main `rate_limit` (from OpenAI's own Codex client types). Shown only
    /// while the API reports one; `null` on an account that has none.
    func codexAdditionalLimitRows(_ raw: Any?, now: Date = Date()) -> [ModelStatus] {
        guard let entries = raw as? [[String: Any]] else { return [] }
        return entries.flatMap { entry -> [ModelStatus] in
            guard let raw = [entry["limit_name"], entry["metered_feature"]]
                    .compactMap({ ($0 as? String)?.trimmingCharacters(in: .whitespaces) })
                    .first(where: { !$0.isEmpty }),
                  let rateLimit = entry["rate_limit"] as? [String: Any] else { return [] }
            // Codex's own client names the reserve `gpt-reserve` on the wire and "Luna Reserve" on screen.
            let name = raw.caseInsensitiveCompare("gpt-reserve") == .orderedSame ? "Luna Reserve" : raw
            let (session, weekly, _) = codexWindows(rateLimit, now: now)
            return [(session, ModelWindow.session), (weekly, .weekly)].compactMap { pair, window in
                guard let pair, let percent = pair.percent else { return nil }
                return ModelStatus(name: name, remainingPercent: percent, resetAt: pair.resetAt,
                                   window: window, groupLabel: Self.codexExtraLimitGroup)
            }
        }
    }

    /// The session and long window out of one `rate_limit` object, by length rather than by slot.
    private func codexWindows(_ rateLimit: [String: Any], now: Date)
        -> (session: (percent: Int?, resetAt: Date?)?, weekly: (percent: Int?, resetAt: Date?)?, weeklyWindow: TimeInterval?) {
        var session: (percent: Int?, resetAt: Date?)?
        var weekly: (percent: Int?, resetAt: Date?)?
        var weeklyWindow: TimeInterval?
        for (raw, slotIsPrimary) in [(rateLimit["primary_window"], true), (rateLimit["secondary_window"], false)] {
            guard let obj = raw as? [String: Any] else { continue }
            let window = codexAPIWindow(obj)
            // A window returned without `used_percent` has an UNKNOWN percent, not a full one. Reading it
            // as 100 made a partial response look like a fresh reset, which fired "quota refilled" in the
            // middle of a 30-day (Go) window. nil keeps the countdown and drops only the number.
            let percent = window.usedPercent.map(remainingPercent(fromUsed:))
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
        return (session, weekly, weeklyWindow)
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

    /// Reset credits ("yenileme hakkı") from `wham/rate-limit-reset-credits`: one-shot passes that
    /// clear a spent rate-limit window. One row per credit, soonest expiry first — a count alone hid
    /// the fact that credits expire on their own dates, and the "first expires in …" caption read
    /// oddly when there was only one. Only credits still available AND not yet expired count: a credit
    /// can lapse between polls, and `available_count` doesn't re-check that. Empty → no rows at all.
    func codexResetCreditRows(fromRoot root: [String: Any], now: Date = Date()) -> [ModelStatus] {
        let expiries = (root["credits"] as? [[String: Any]] ?? []).compactMap { item -> Date? in
            guard (item["status"] as? String)?.lowercased() == "available",
                  let raw = item["expires_at"] as? String,
                  let expiresAt = parseISO8601(raw), expiresAt > now else { return nil }
            return expiresAt
        }.sorted()

        // One line per credit, labelled by the date it lapses; the popover groups them under a single
        // "Renewal credits" heading, so neither the icon nor the label repeats. `resetAt` carries the
        // expiry: the line draws a live countdown off it, and the expiry warning reads it from here
        // rather than from the formatted text.
        // One line per credit: the chip above them carries the count, these carry the dates.
        return expiries.map { expiresAt in
            ModelStatus(name: Self.shortDateFormatter.string(from: expiresAt),
                        remainingPercent: 0, resetAt: expiresAt,
                        valueText: TimeFormatter.duration(from: expiresAt.timeIntervalSince(now)),
                        symbol: "plus.circle", groupLabel: String(localized: "Renewal credit"))
        }
    }

    /// A credit's expiry is a calendar date, not a countdown, so it reads as one: "13.10.26", with
    /// the century left off since a line that says what the date is for never raises the question.
    /// Not the locale's short style — that dropped the leading zero ("8.09.26"), so a column of
    /// dates didn't line up. `yy` (calendar year), never `YY` (week-year, off by one in late
    /// December). POSIX locale so a non-Gregorian regional calendar can't reformat it.
    static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "dd.MM.yy"
        return f
    }()

    /// GET the reset-credit endpoint with the same auth as `wham/usage`. Failure returns nil and the
    /// row is dropped — this is a bonus reading, never a reason to fail the whole Codex fetch.
    private func fetchCodexResetCredits(accessToken: String, accountID: String?) async -> [ModelStatus] {
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
            return []
        }
        return codexResetCreditRows(fromRoot: root)
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

    private func readCodexAuthState(home codexHomeDir: URL?) -> CodexAuthState? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths: [URL] = []
        if let codexHomeDir {
            // A second login reads only its own dir — never fall back to the main account's token.
            paths.append(codexHomeDir.appendingPathComponent("auth.json"))
        } else {
            if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"],
               !codexHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                paths.append(URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json"))
            }
            paths.append(home.appendingPathComponent(".codex/auth.json"))
            paths.append(home.appendingPathComponent(".config/codex/auth.json"))
        }

        for path in paths {
            guard let data = try? Data(contentsOf: path),
                  let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  codexAccessToken(in: auth) != nil else {
                continue
            }
            return CodexAuthState(path: path, auth: auth)
        }
        return nil
    }

    /// Read whatever token the Codex CLI currently holds; never refresh it, never write it back.
    ///
    /// OpenAI rotates Codex's refresh token single-use (openai/codex#46028: reusing one outside a
    /// ~30s tolerance window returns `invalid_grant`; OpenHands/enterprise#426 quotes Codex's own
    /// `auth/manager.rs`). Mimir refreshing in the background therefore consumes the token the CLI
    /// still holds and can log the user out of their own terminal — and the CLI refreshes often,
    /// up to six times in a single failed turn (openai/codex#48303). This is the same posture the
    /// Claude side already takes, and for the same reason.
    ///
    /// A token within 30s of expiry is treated as gone rather than used: it would likely die
    /// mid-request, and there is nothing to fall back to but the same dead token.
    private func codexAccessToken(from state: CodexAuthState) -> String? {
        guard let accessToken = codexAccessToken(in: state.auth) else { return nil }
        if let expiresAt = jwtExpiry(accessToken), expiresAt.timeIntervalSinceNow <= 30 { return nil }
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

