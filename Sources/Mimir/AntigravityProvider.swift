import Foundation

extension LiveUsageDataSource {
    func fetchAntigravity() async -> ServiceStatus {
        let defaults = ["Gemini", "Claude"]
        // Primary live source: the grouped weekly + 5h quota summary that backs the IDE's
        // "Model Quota" page. Antigravity moved quota off per-model and onto shared group
        // buckets (Gemini / Claude+GPT), each with a weekly and a 5-hour window.
        if let summary = fetchAntigravityQuotaSummary() {
            saveAntigravitySnapshot(summary)
            return summary
        }
        if let authorized = await fetchAntigravityAuthorized(models: defaults) {
            saveAntigravitySnapshot(authorized)
            return authorized
        }
        if let cached = fetchAntigravityCockpitCache(models: defaults) {
            return cached
        }
        if let local = fetchAntigravityLocalLanguageServer(models: defaults) {
            saveAntigravitySnapshot(local)
            return local
        }
        // Live sources gone (IDE/Cockpit closed). Fall back to the last snapshot we
        // captured while one was open — valid until its reset time passes.
        if let snapshot = fetchAntigravitySnapshot() {
            return snapshot
        }

        let note = readAntigravityCockpitAccount() == nil
            ? String(localized: "open Antigravity or Cockpit")
            : "antigravity auth failed"
        return unavailableService(name: "Antigravity", iconName: "antigravity", models: defaults, note: note)
    }
    private func fetchAntigravityAuthorized(models defaults: [String]) async -> ServiceStatus? {
        guard let account = readAntigravityCockpitAccount(),
              let token = await antigravityAccessToken(from: account) else {
            return nil
        }

        let projectID = account["projectId"] as? String
        let isGcpTos = account["isGcpTos"] as? Bool ?? false
        let baseURL = isGcpTos ? "https://cloudcode-pa.googleapis.com" : "https://daily-cloudcode-pa.googleapis.com"
        var req = URLRequest(url: URL(string: "\(baseURL)/v1internal:fetchAvailableModels")!, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("antigravity/unknown darwin/arm64", forHTTPHeaderField: "User-Agent")
        let bodyObj: [String: Any] = projectID.map { ["project": $0] } ?? [:]
        req.httpBody = try? JSONSerialization.data(withJSONObject: bodyObj)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse).map({ 200 ... 299 ~= $0.statusCode }) == true,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let normalized = normalizeAntigravityModels(root)
            guard normalized.contains(where: { $0.resetAt != nil }) else { return nil }
            return ServiceStatus(
                name: "Antigravity",
                iconName: "antigravity",
                sessionResetAt: normalized.compactMap(\.resetAt).sorted().first,
                weeklyResetAt: nil,
                models: normalized,
                isAvailable: true,
                statusNote: "cloudcode authorized"
            )
        } catch {
            return nil
        }
    }

    private func fetchAntigravityCockpitCache(models defaults: [String]) -> ServiceStatus? {
        let cacheRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".antigravity_cockpit/cache/quota_api_v1_plugin/authorized")
        guard let file = latestFile(in: cacheRoot, pathExtension: "json"),
              let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modDate = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modDate) < 6 * 3_600,
              let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let normalized = normalizeAntigravityModels(root)
        guard normalized.contains(where: { $0.resetAt != nil }) else { return nil }
        return ServiceStatus(
            name: "Antigravity",
            iconName: "antigravity",
            sessionResetAt: normalized.compactMap(\.resetAt).sorted().first,
            weeklyResetAt: nil,
            models: normalized,
            isAvailable: true,
            statusNote: "cockpit cache"
        )
    }

    /// Locate the running Antigravity language server and return its CSRF token plus the
    /// localhost ports it listens on. Shared by every local-gRPC fetch so the process /
    /// port discovery (and its lsof gotcha) lives in one place.
    private func antigravityLanguageServerEndpoint() -> (csrf: String, ports: [Int])? {
        let processRows = runShell("ps -ax -o pid=,command= | grep 'bin/language_server' | grep antigravity | grep -v grep")
            .split(separator: "\n")
        guard let row = processRows.first else {
            return nil
        }
        let command = String(row)
        guard let pidStr = command.split(separator: " ").first.map(String.init),
              let pidInt = Int(pidStr),
              let csrf = extractFlag("--csrf_token", from: command) else {
            return nil
        }

        // -a ANDs the filters; without it lsof ORs -iTCP and -p, returning every
        // listening port on the system and forcing dozens of curl probes that blow the timeout.
        let ports = runShell("lsof -a -nP -iTCP -sTCP:LISTEN -p \(pidInt) | awk '{print $9}' | sed -E 's/.*:([0-9]+)->?.*/\\1/' | sed -E 's/.*:([0-9]+)$/\\1/' | sort -u")
            .split(separator: "\n")
            .compactMap { Int($0) }
        guard !ports.isEmpty else {
            return nil
        }
        return (csrf, ports)
    }

    /// Call the grouped quota summary RPC the IDE's Model Quota page uses. Each group
    /// (Gemini, Claude+GPT) carries a weekly and a 5-hour bucket — flattened to one row each.
    private func fetchAntigravityQuotaSummary() -> ServiceStatus? {
        guard let (csrf, ports) = antigravityLanguageServerEndpoint() else {
            return nil
        }

        let body = "{\"metadata\":{\"ideName\":\"antigravity\",\"extensionName\":\"antigravity\",\"locale\":\"en\",\"ideVersion\":\"unknown\"}}"
        var groups: [[String: Any]]?
        for p in ports {
            let out = antigravityCurl(port: p, path: "RetrieveUserQuotaSummary", body: body, csrf: csrf)
            if let data = out.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let response = json["response"] as? [String: Any],
               let g = response["groups"] as? [[String: Any]], !g.isEmpty {
                groups = g
                break
            }
        }
        guard let groups else {
            return nil
        }

        var models = antigravityQuotaSummaryRows(groups: groups)
        guard !models.isEmpty else {
            return nil
        }
        if let credit = antigravityCreditRow(csrf: csrf, ports: ports) {
            models.append(credit)
        }
        return ServiceStatus(
            name: "Antigravity",
            iconName: "antigravity",
            sessionResetAt: models.compactMap(\.resetAt).min(),
            weeklyResetAt: nil,
            models: models,
            isAvailable: true,
            statusNote: "quota summary"
        )
    }

    /// Google One AI credit balance from Antigravity's GetUserStatus (`userTier.availableCredits`),
    /// shown alongside the quota rows. `creditAmount`/`minimumCreditAmountForUsage` are JSON strings.
    private func antigravityCreditRow(csrf: String, ports: [Int]) -> ModelStatus? {
        let body = "{\"metadata\":{\"ideName\":\"antigravity\",\"locale\":\"en\"}}"
        func num(_ raw: Any?) -> Double? { (raw as? String).flatMap(Double.init) ?? doubleValue(raw) }
        for p in ports {
            let out = antigravityCurl(port: p, path: "GetUserStatus", body: body, csrf: csrf)
            guard let data = out.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let userStatus = json["userStatus"] as? [String: Any],
                  let tier = userStatus["userTier"] as? [String: Any],
                  let credits = tier["availableCredits"] as? [[String: Any]], !credits.isEmpty else {
                continue
            }
            let one = credits.first { ($0["creditType"] as? String)?.contains("GOOGLE_ONE") == true } ?? credits[0]
            guard let amount = num(one["creditAmount"]) else { return nil }
            let minimum = num(one["minimumCreditAmountForUsage"]) ?? 0
            return ModelStatus(name: String(localized: "Google One credits"), remainingPercent: 0, resetAt: nil,
                               valueText: String(Int(amount)), isLow: amount < minimum)
        }
        return nil
    }

    /// Flatten `groups[].buckets[]` into one row per (group × window), ordered 5h then
    /// weekly within each group: Gemini · 5h, Gemini · Weekly, Claude/GPT · 5h, Claude/GPT · Weekly.
    private func antigravityQuotaSummaryRows(groups: [[String: Any]]) -> [ModelStatus] {
        var rows: [ModelStatus] = []
        for group in groups {
            let family = antigravityFamilyLabel(group["displayName"] as? String ?? "")
            let buckets = (group["buckets"] as? [[String: Any]] ?? [])
                .sorted { antigravityWindowRank($0["window"] as? String) < antigravityWindowRank($1["window"] as? String) }
            for bucket in buckets {
                guard let fraction = doubleValue(bucket["remainingFraction"]) else { continue }
                let percent = Int((min(1, max(0, fraction)) * 100).rounded())
                let reset = (bucket["resetTime"] as? String).flatMap { parseISO8601($0) }
                let window: ModelWindow = (bucket["window"] as? String == "weekly") ? .weekly : .session
                rows.append(ModelStatus(name: family, remainingPercent: percent, resetAt: reset, window: window))
            }
        }
        return rows
    }

    private func antigravityFamilyLabel(_ displayName: String) -> String {
        let lower = displayName.lowercased()
        if lower.contains("gemini") { return "Gemini" }
        if lower.contains("claude") || lower.contains("gpt") { return "Claude/GPT" }
        return displayName.isEmpty ? "Antigravity" : displayName
    }

    private func antigravityWindowRank(_ window: String?) -> Int {
        switch window {
        case "weekly": return 0
        case "5h": return 1
        default: return 2
        }
    }

    private func fetchAntigravityLocalLanguageServer(models defaults: [String]) -> ServiceStatus? {
        guard let (csrf, ports) = antigravityLanguageServerEndpoint() else {
            return nil
        }

        let body = "{\"metadata\":{\"ideName\":\"antigravity\",\"extensionName\":\"antigravity\",\"locale\":\"en\",\"ideVersion\":\"unknown\"}}"
        var payload: [String: Any]?
        for p in ports {
            let out = antigravityCurl(port: p, path: "GetUserStatus", body: body, csrf: csrf)
            if let data = out.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["userStatus"] != nil {
                payload = json
                break
            }
        }
        guard let payload else {
            return nil
        }

        let normalized = normalizeAntigravityModels(payload)
        return ServiceStatus(
            name: "Antigravity",
            iconName: "antigravity",
            sessionResetAt: normalized.compactMap(\.resetAt).sorted().first,
            weeklyResetAt: nil,
            models: normalized,
            isAvailable: true,
            statusNote: "local language server"
        )
    }

    private func normalizeAntigravityModels(_ root: [String: Any]) -> [ModelStatus] {
        let configs = antigravityModelConfigs(from: root)
        guard !configs.isEmpty else {
            return [
                ModelStatus(name: "Gemini", remainingPercent: 0, resetAt: nil),
                ModelStatus(name: "Claude", remainingPercent: 0, resetAt: nil)
            ]
        }

        var gemini: [ModelStatus] = []
        var claude: [ModelStatus] = []

        for c in configs {
            guard let quota = c["quotaInfo"] as? [String: Any] else { continue }
            let rawName = [
                c["_key"] as? String,
                c["displayName"] as? String,
                c["displayLabel"] as? String,
                c["label"] as? String,
                c["model"] as? String,
                c["modelId"] as? String,
                (c["modelOrAlias"] as? [String: Any])?["model"] as? String
            ]
                .compactMap { $0 }
                .joined(separator: " ")
                .lowercased()
            let remaining = doubleValue(quota["remainingFraction"]) ?? 0
            let remainingPercent = Int(min(100, max(0, remaining * 100)).rounded())
            let reset = (quota["resetTime"] as? String).flatMap { parseISO8601($0) }.map { projectAntigravityReset($0) }
            let status = ModelStatus(name: "", remainingPercent: max(0, min(100, remainingPercent)), resetAt: reset)

            if rawName.contains("gemini") {
                gemini.append(status)
            } else if rawName.contains("claude") || rawName.contains("gpt-oss") || rawName.contains("model_openai_gpt_oss") {
                claude.append(status)
            }
        }

        return [
            pickModel("Gemini", from: gemini),
            pickModel("Claude", from: claude)
        ]
    }


    private func antigravityModelConfigs(from root: [String: Any]) -> [[String: Any]] {
        if let payload = root["payload"] as? [String: Any] {
            return antigravityModelConfigs(from: payload)
        }
        if let models = root["models"] as? [String: Any] {
            return models.compactMap { key, value in
                guard var model = value as? [String: Any] else { return nil }
                model["_key"] = key
                return model
            }
        }
        if let userStatus = root["userStatus"] as? [String: Any],
           let cascade = userStatus["cascadeModelConfigData"] as? [String: Any],
           let configs = cascade["clientModelConfigs"] as? [[String: Any]] {
            return configs
        }
        return []
    }

    private func projectAntigravityReset(_ date: Date) -> Date {
        guard date < Date() else { return date }
        let period: TimeInterval = 5 * 3_600
        let elapsed = Date().timeIntervalSince(date)
        return date.addingTimeInterval(ceil(elapsed / period) * period)
    }

    private func pickModel(_ name: String, from candidates: [ModelStatus]) -> ModelStatus {
        guard let best = candidates.sorted(by: { lhs, rhs in
            if lhs.remainingPercent != rhs.remainingPercent {
                return lhs.remainingPercent < rhs.remainingPercent
            }
            switch (lhs.resetAt, rhs.resetAt) {
            case let (l?, r?):
                return l < r
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return false
            }
        }).first else {
            return ModelStatus(name: name, remainingPercent: 0, resetAt: nil)
        }
        return ModelStatus(name: name, remainingPercent: best.remainingPercent, resetAt: best.resetAt)
    }
    private func readAntigravityCockpitAccount() -> [String: Any]? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".antigravity_cockpit/credentials.json")
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = root["accounts"] as? [String: Any] else {
            return nil
        }

        return accounts.values.compactMap { $0 as? [String: Any] }.first {
            ($0["refreshToken"] as? String)?.isEmpty == false || ($0["accessToken"] as? String)?.isEmpty == false
        }
    }

    private func antigravityAccessToken(from account: [String: Any]) async -> String? {
        if let accessToken = account["accessToken"] as? String, !accessToken.isEmpty,
           let expiresRaw = account["expiresAt"] as? String,
           let expiresAt = parseISO8601(expiresRaw),
           expiresAt.timeIntervalSinceNow > 300 {
            return accessToken
        }

        guard let refreshToken = account["refreshToken"] as? String, !refreshToken.isEmpty else {
            return account["accessToken"] as? String
        }

        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // client_id ve client_secret Antigravity Cockpit kurulumundan okunmalı
        guard let clientId = account["clientId"] as? String, !clientId.isEmpty,
              let clientSecret = account["clientSecret"] as? String, !clientSecret.isEmpty else {
            return nil
        }
        let body = [
            "client_id": clientId,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
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
                return account["accessToken"] as? String
            }
            return accessToken
        } catch {
            return account["accessToken"] as? String
        }
    }
    /// POSTs to a local Antigravity language-server endpoint. The CSRF token is fed
    /// through curl's stdin config (`--config -`) instead of a `-H` argument, so it
    /// never lands in the process table — unlike command-line arguments, stdin is
    /// not world-readable.
    func antigravityCurl(port p: Int, path: String, body: String, csrf: String) -> String {
        runCommand("/usr/bin/curl", [
            "-ks", "--max-time", "2",
            "--config", "-",
            "-H", "Connect-Protocol-Version: 1",
            "-H", "Content-Type: application/json",
            "--data", body,
            "https://127.0.0.1:\(p)/exa.language_server_pb.LanguageServerService/\(path)"
        ], stdin: "header = \"X-Codeium-Csrf-Token: \(csrf)\"\n")
    }
}
