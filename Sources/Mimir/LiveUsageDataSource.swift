import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published var services: [ServiceStatus] = LiveUsageDataSource.fallbackServices()
    @Published var isRefreshing = false
    private let source = LiveUsageDataSource()

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let source = self.source
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                await source.fetchAll().sorted { $0.name < $1.name }
            }.value
            self.services = result
            self.isRefreshing = false
        }
    }
}

struct LiveUsageDataSource {
    static func fallbackServices() -> [ServiceStatus] {
        [
            ServiceStatus(
                name: "Antigravity",
                iconName: "antigravity",
                sessionResetAt: nil,
                weeklyResetAt: nil,
                models: [
                    ModelStatus(name: "Claude", usagePercent: 0, resetAt: nil),
                    ModelStatus(name: "Gemini Pro", usagePercent: 0, resetAt: nil),
                    ModelStatus(name: "Gemini Flash", usagePercent: 0, resetAt: nil)
                ],
                isAvailable: false,
                statusNote: "no local source"
            ),
            ServiceStatus(
                name: "Claude",
                iconName: "claude",
                sessionResetAt: nil,
                weeklyResetAt: nil,
                models: [
                    ModelStatus(name: "Design", usagePercent: 0, resetAt: nil)
                ],
                isAvailable: false,
                statusNote: "no local source"
            ),
            ServiceStatus(
                name: "Codex",
                iconName: "codex",
                sessionResetAt: nil,
                weeklyResetAt: nil,
                models: [],
                isAvailable: false,
                statusNote: "no local source"
            ),
            ServiceStatus(
                name: "Gemini",
                iconName: "gemini",
                sessionResetAt: nil,
                weeklyResetAt: nil,
                models: [
                    ModelStatus(name: "Flash", usagePercent: 0, resetAt: nil),
                    ModelStatus(name: "Pro", usagePercent: 0, resetAt: nil)
                ],
                isAvailable: false,
                statusNote: "no local source"
            )
        ]
    }

    func fetchAll() async -> [ServiceStatus] {
        await withTaskGroup(of: ServiceStatus.self) { group in
            group.addTask { await withTimeout(seconds: 8) { await fetchClaude() } ?? Self.fallbackServices().first(where: { $0.name == "Claude" })! }
            group.addTask { await withTimeout(seconds: 8) { await fetchCodex() } ?? Self.fallbackServices().first(where: { $0.name == "Codex" })! }
            group.addTask { await withTimeout(seconds: 8) { await fetchGemini() } ?? Self.fallbackServices().first(where: { $0.name == "Gemini" })! }
            group.addTask { await withTimeout(seconds: 8) { await fetchAntigravity() } ?? Self.fallbackServices().first(where: { $0.name == "Antigravity" })! }

            var out: [ServiceStatus] = []
            for await item in group {
                out.append(item)
            }
            return out
        }
    }

    private func fetchClaude() async -> ServiceStatus {
        let models = ["Design"]
        if let cached = readClaudeUsageCache(maxAge: 5 * 60) {
            return buildClaudeStatus(from: cached, note: "oauth usage cache")
        }

        guard let token = readClaudeToken() else {
            return unavailableService(name: "Claude", iconName: "codex", models: models, note: "claude token missing")
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return unavailableService(name: "Claude", iconName: "codex", models: models, note: "claude no http response")
            }
            guard 200 ... 299 ~= http.statusCode else {
                if let cached = readClaudeUsageCache(maxAge: 24 * 60 * 60) {
                    return buildClaudeStatus(from: cached, note: "oauth usage cache (http \(http.statusCode))")
                }
                return unavailableService(name: "Claude", iconName: "codex", models: models, note: "claude http \(http.statusCode)")
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return unavailableService(name: "Claude", iconName: "codex", models: models, note: "claude response parse fail")
            }
            writeClaudeUsageCache(data)

            return buildClaudeStatus(from: root, note: "oauth usage api")
        } catch {
            if let cached = readClaudeUsageCache(maxAge: 24 * 60 * 60) {
                return buildClaudeStatus(from: cached, note: "oauth usage cache")
            }
            return unavailableService(name: "Claude", iconName: "codex", models: models, note: "claude request failed")
        }
    }

    private func buildClaudeStatus(from root: [String: Any], note: String) -> ServiceStatus {
        let fiveHour = mergeClaudeWindows(root: root, baseKey: "five_hour")
        let sevenDay = mergeClaudeWindows(root: root, baseKey: "seven_day")
        let design = mergeClaudeWindows(root: root, baseKey: "seven_day_omelette")

        return ServiceStatus(
            name: "Claude",
            iconName: "claude",
            sessionResetAt: fiveHour.resetAt,
            weeklyResetAt: sevenDay.resetAt,
            sessionUsagePercent: remainingPercent(fromUsed: fiveHour.utilization),
            weeklyUsagePercent: remainingPercent(fromUsed: sevenDay.utilization),
            models: [
                ModelStatus(
                    name: "Design",
                    usagePercent: remainingPercent(fromUsed: design.utilization),
                    resetAt: design.resetAt ?? sevenDay.resetAt
                )
            ],
            isAvailable: true,
            statusNote: note
        )
    }

    private func remainingPercent(fromUsed used: Double) -> Int {
        max(0, min(100, Int((100 - used).rounded())))
    }

    private func fetchCodex() async -> ServiceStatus {
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
        var models: [ModelStatus] = []

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
            
            if let c = rl.credits {
                if sessionRemaining == nil && c.balance == "0" { sessionRemaining = 0 }
                if models.isEmpty {
                    models.append(ModelStatus(name: "Credits", usagePercent: 0, resetAt: nil, valueText: c.balance))
                }
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

        var statusNote = "local .codex sessions"
        if sessionReset == nil {
            statusNote += " (reset time not found in file)"
        }

        return ServiceStatus(
            name: "Codex",
            iconName: "codex",
            sessionResetAt: sessionReset,
            weeklyResetAt: weeklyReset,
            sessionUsagePercent: sessionRemaining ?? 100,
            weeklyUsagePercent: weeklyRemaining ?? 100,
            models: models,
            isAvailable: true,
            statusNote: statusNote
        )
    }

    private func fetchGemini() async -> ServiceStatus {
        guard let token = await geminiAccessToken() else {
            return unavailableService(name: "Gemini", iconName: "gemini", models: ["Pro", "Flash"])
        }

        let loadCodeAssist = await fetchGeminiLoadCodeAssist(accessToken: token)
        let projectId = readGeminiProjectID() ?? readFirstStringDeep(loadCodeAssist, keys: ["cloudaicompanionProject"])

        let root: [String: Any]
        if let quota = await fetchGeminiQuota(accessToken: token, projectID: projectId) {
            root = quota
        } else if let creds = readGeminiOAuthCreds(),
                  let refreshed = await refreshGeminiAccessToken(creds: creds),
                  let quota = await fetchGeminiQuota(accessToken: refreshed, projectID: projectId) {
            root = quota
        } else {
            return unavailableService(name: "Gemini", iconName: "gemini", models: ["Pro", "Flash"])
        }

        let buckets = extractGeminiQuotaBuckets(root)
        guard !buckets.isEmpty else {
            return unavailableService(name: "Gemini", iconName: "gemini", models: ["Pro", "Flash"])
        }

        let pro = bestGeminiBucket(buckets, contains: "pro")
        let flash = bestGeminiBucket(buckets, contains: "flash")
        let proRemaining = pro.map { Int(($0.remainingFraction * 100).rounded()) } ?? 0
        let flashRemaining = flash.map { Int(($0.remainingFraction * 100).rounded()) } ?? 0
        let proReset = pro?.resetAt
        let flashReset = flash?.resetAt

        return ServiceStatus(
            name: "Gemini",
            iconName: "gemini",
            sessionResetAt: [proReset, flashReset].compactMap { $0 }.sorted().first,
            weeklyResetAt: nil,
            models: [
                ModelStatus(name: "Flash", usagePercent: max(0, min(100, flashRemaining)), resetAt: flashReset),
                ModelStatus(name: "Pro", usagePercent: max(0, min(100, proRemaining)), resetAt: proReset)
            ],
            isAvailable: true,
            statusNote: "google quota api"
        )
    }

    private func fetchAntigravity() async -> ServiceStatus {
        let defaults = ["Gemini Flash", "Gemini Pro", "Claude", "AI Credits"]
        if let authorized = await fetchAntigravityAuthorized(models: defaults) {
            return authorized
        }
        if let cached = fetchAntigravityCockpitCache(models: defaults) {
            return cached
        }
        if let local = fetchAntigravityLocalLanguageServer(models: defaults) {
            return local
        }

        let note = readAntigravityCockpitAccount() == nil
            ? "open Antigravity or Cockpit"
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
        let body = projectID.map { "{\"project\":\"\($0)\"}" } ?? "{}"
        req.httpBody = body.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse).map({ 200 ... 299 ~= $0.statusCode }) == true,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            var normalized = normalizeAntigravityModels(root)
            guard normalized.contains(where: { $0.resetAt != nil }) else { return nil }
            var credits = readAntigravityAICreditsFromLocalLanguageServer()
            if credits == nil {
                credits = await fetchAntigravityAICredits(token: token, projectID: projectID, baseURL: baseURL)
            }
            if credits == nil {
                credits = readAntigravityAICreditsFromStateDB()
            }
            if let credits {
                normalized.append(ModelStatus(name: "AI Credits", usagePercent: 0, resetAt: nil, valueText: "\(credits)"))
            }
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

    private func readAntigravityAICreditsFromStateDB() -> Int? {
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Antigravity/User/globalStorage/state.vscdb")
            .path
        let sql = "select value from ItemTable where key='antigravityUnifiedStateSync.modelCredits';"
        let encoded = runCommand("/usr/bin/sqlite3", [dbPath, sql])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let outer = Data(base64Encoded: encoded),
              let sentinel = "availableCreditsSentinelKey".data(using: .utf8),
              let sentinelRange = outer.range(of: sentinel) else {
            return nil
        }

        let tail = outer[sentinelRange.upperBound..<min(outer.endIndex, sentinelRange.upperBound + 32)]
        let base64Chars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=".utf8)
        var candidates: [String] = []
        var current: [UInt8] = []

        for byte in tail {
            if base64Chars.contains(byte) {
                current.append(byte)
            } else {
                if current.count >= 4, let candidate = String(bytes: current, encoding: .utf8) {
                    candidates.append(candidate)
                }
                current.removeAll()
            }
        }
        if current.count >= 4, let candidate = String(bytes: current, encoding: .utf8) {
            candidates.append(candidate)
        }

        for candidate in candidates {
            guard let data = Data(base64Encoded: candidate),
                  let value = parseFirstProtoVarintValue(in: data) else {
                continue
            }
            return value
        }
        return nil
    }

    private func parseFirstProtoVarintValue(in data: Data) -> Int? {
        var index = data.startIndex
        while index < data.endIndex {
            guard let tag = readProtoVarint(data, index: &index) else { return nil }
            let wireType = tag & 7
            if wireType == 0 {
                return readProtoVarint(data, index: &index)
            }
            if wireType == 2,
               let length = readProtoVarint(data, index: &index),
               length >= 0,
               data.distance(from: index, to: data.endIndex) >= length {
                index = data.index(index, offsetBy: length)
                continue
            }
            return nil
        }
        return nil
    }

    private func readProtoVarint(_ data: Data, index: inout Data.Index) -> Int? {
        var result = 0
        var shift = 0
        while index < data.endIndex {
            let byte = Int(data[index])
            index = data.index(after: index)
            result |= (byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
            if shift > 28 {
                return nil
            }
        }
        return nil
    }

    private func fetchAntigravityAICredits(token: String, projectID: String?, baseURL: String) async -> Int? {
        var req = URLRequest(url: URL(string: "\(baseURL)/v1internal:loadCodeAssist")!, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("antigravity/unknown darwin/arm64", forHTTPHeaderField: "User-Agent")

        var payload: [String: Any] = [
            "metadata": [
                "ideName": "antigravity",
                "ideType": "ANTIGRAVITY",
                "ideVersion": "unknown",
                "pluginVersion": "unknown",
                "platform": "DARWIN_ARM64",
                "updateChannel": "stable",
                "pluginType": "GEMINI"
            ],
            "mode": "FULL_ELIGIBILITY_CHECK"
        ]
        if let projectID, !projectID.isEmpty {
            payload["cloudaicompanionProject"] = projectID
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse).map({ 200 ... 299 ~= $0.statusCode }) == true,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let paidTier = root["paidTier"] as? [String: Any],
                  let credits = paidTier["availableCredits"] as? [[String: Any]] else {
                return nil
            }

            let total = credits.reduce(0.0) { partial, credit in
                partial + (doubleValue(credit["creditAmount"]) ?? 0)
            }
            return Int(total.rounded())
        } catch {
            return nil
        }
    }

    private func fetchAntigravityCockpitCache(models defaults: [String]) -> ServiceStatus? {
        let cacheRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".antigravity_cockpit/cache/quota_api_v1_plugin/authorized")
        guard let file = latestFile(in: cacheRoot, pathExtension: "json"),
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

    private func fetchAntigravityLocalLanguageServer(models defaults: [String]) -> ServiceStatus? {
        let processRows = runShell("ps -ax -o pid=,command= | grep language_server_macos | grep antigravity | grep -v grep")
            .split(separator: "\n")
        guard let row = processRows.first else {
            return nil
        }
        let command = String(row)
        guard let pid = command.split(separator: " ").first.map(String.init),
              let csrf = extractFlag("--csrf_token", from: command) else {
            return nil
        }

        let ports = runShell("lsof -nP -iTCP -sTCP:LISTEN -p \(pid) | awk '{print $9}' | sed -E 's/.*:([0-9]+)->?.*/\\1/' | sed -E 's/.*:([0-9]+)$/\\1/' | sort -u")
            .split(separator: "\n")
            .compactMap { Int($0) }
        guard !ports.isEmpty else {
            return nil
        }

        let body = "{\"metadata\":{\"ideName\":\"antigravity\",\"extensionName\":\"antigravity\",\"locale\":\"en\",\"ideVersion\":\"unknown\"}}"
        var payload: [String: Any]?
        for p in ports {
            let out = runShell("curl -ks --max-time 2 -H 'X-Codeium-Csrf-Token: \(csrf)' -H 'Connect-Protocol-Version: 1' -H 'Content-Type: application/json' --data '\(body)' https://127.0.0.1:\(p)/exa.language_server_pb.LanguageServerService/GetUserStatus")
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

        var normalized = normalizeAntigravityModels(payload)
        if let credits = extractAntigravityAICredits(from: payload) {
            normalized.append(ModelStatus(name: "AI Credits", usagePercent: 0, resetAt: nil, valueText: "\(credits)"))
        }
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

    private func readAntigravityAICreditsFromLocalLanguageServer() -> Int? {
        guard let payload = fetchAntigravityLocalUserStatusPayload() else { return nil }
        return extractAntigravityAICredits(from: payload)
    }

    private func fetchAntigravityLocalUserStatusPayload() -> [String: Any]? {
        let processRows = runShell("ps -ax -o pid=,command= | grep language_server_macos | grep antigravity | grep -v grep")
            .split(separator: "\n")
        guard let row = processRows.first else {
            return nil
        }
        let command = String(row)
        guard let pid = command.split(separator: " ").first.map(String.init),
              let csrf = extractFlag("--csrf_token", from: command) else {
            return nil
        }

        let ports = runShell("lsof -nP -iTCP -sTCP:LISTEN -p \(pid) | awk '{print $9}' | sed -E 's/.*:([0-9]+)->?.*/\\1/' | sed -E 's/.*:([0-9]+)$/\\1/' | sort -u")
            .split(separator: "\n")
            .compactMap { Int($0) }
        guard !ports.isEmpty else {
            return nil
        }

        let body = "{\"metadata\":{\"ideName\":\"antigravity\",\"extensionName\":\"antigravity\",\"locale\":\"en\",\"ideVersion\":\"unknown\"}}"
        for p in ports {
            let out = runShell("curl -ks --max-time 2 -H 'X-Codeium-Csrf-Token: \(csrf)' -H 'Connect-Protocol-Version: 1' -H 'Content-Type: application/json' --data '\(body)' https://127.0.0.1:\(p)/exa.language_server_pb.LanguageServerService/GetUserStatus")
            if let data = out.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["userStatus"] != nil {
                return json
            }
        }
        return nil
    }

    private func normalizeAntigravityModels(_ root: [String: Any]) -> [ModelStatus] {
        let configs = antigravityModelConfigs(from: root)
        guard !configs.isEmpty else {
            return [
                ModelStatus(name: "Claude", usagePercent: 0, resetAt: nil),
                ModelStatus(name: "Gemini Pro", usagePercent: 0, resetAt: nil),
                ModelStatus(name: "Gemini Flash", usagePercent: 0, resetAt: nil)
            ]
        }

        var claude: [ModelStatus] = []
        var pro: [ModelStatus] = []
        var flash: [ModelStatus] = []

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
            let reset = (quota["resetTime"] as? String).flatMap { parseISO8601($0) }
            let status = ModelStatus(name: "", usagePercent: max(0, min(100, remainingPercent)), resetAt: reset)

            if rawName.contains("claude") || rawName.contains("gpt-oss") || rawName.contains("model_openai_gpt_oss") {
                claude.append(status)
            } else if rawName.contains("gemini") && rawName.contains("pro") {
                pro.append(status)
            } else if rawName.contains("gemini") && rawName.contains("flash") {
                flash.append(status)
            }
        }

        return [
            pickModel("Gemini Flash", from: flash),
            pickModel("Gemini Pro", from: pro),
            pickModel("Claude", from: claude)
        ]
    }

    private func extractAntigravityAICredits(from root: [String: Any]) -> Int? {
        if let userStatus = root["userStatus"] as? [String: Any],
           let credits = extractAntigravityAICredits(from: userStatus) {
            return credits
        }

        if let userTier = root["userTier"] as? [String: Any],
           let availableCredits = userTier["availableCredits"] as? [[String: Any]] {
            let total = availableCredits.reduce(0.0) { partial, credit in
                partial + (doubleValue(credit["creditAmount"]) ?? 0)
            }
            if total > 0 {
                return Int(total.rounded())
            }
        }

        if let planStatus = root["planStatus"] as? [String: Any],
           let promptCredits = doubleValue(planStatus["availablePromptCredits"]) {
            return Int(max(0, promptCredits).rounded())
        }

        if let promptCredits = root["promptCredits"] as? [String: Any],
           let available = doubleValue(promptCredits["available"]) {
            return Int(max(0, available).rounded())
        }

        if let userInfo = root["userInfo"] as? [String: Any],
           let available = doubleValue(userInfo["availablePromptCredits"]) {
            return Int(max(0, available).rounded())
        }

        return nil
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

    private func pickModel(_ name: String, from candidates: [ModelStatus]) -> ModelStatus {
        guard let best = candidates.sorted(by: { lhs, rhs in
            if lhs.usagePercent != rhs.usagePercent {
                return lhs.usagePercent < rhs.usagePercent
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
            return ModelStatus(name: name, usagePercent: 0, resetAt: nil)
        }
        return ModelStatus(name: name, usagePercent: best.usagePercent, resetAt: best.resetAt)
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

    private func unavailableService(name: String, iconName: String, models: [String], note: String? = nil) -> ServiceStatus {
        ServiceStatus(
            name: name,
            iconName: iconName,
            sessionResetAt: nil,
            weeklyResetAt: nil,
            models: models.map { ModelStatus(name: $0, usagePercent: 0, resetAt: nil) },
            isAvailable: false,
            statusNote: note ?? "source unavailable"
        )
    }

    private func latestJSONLFile(in directory: URL) -> URL? {
        latestFile(in: directory, pathExtension: "jsonl")
    }

    private func latestFile(in directory: URL, pathExtension: String) -> URL? {
        guard let e = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }
        var latest: (URL, Date)?
        while let raw = e.nextObject() {
            guard let url = raw as? URL, url.pathExtension == pathExtension,
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let date = values.contentModificationDate else { continue }
            if latest == nil || date > latest!.1 {
                latest = (url, date)
            }
        }
        return latest?.0
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

    private func readClaudeToken() -> String? {
        let keychainRaw = runCommand("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if let token = parseTokenPossiblyJSON(keychainRaw) { return token }

        let credPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: credPath),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        return parseTokenPossiblyJSON(raw)
    }

    private func readClaudeUsageCache(maxAge: TimeInterval) -> [String: Any]? {
        let url = claudeUsageCacheURL()
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let modifiedAt = values.contentModificationDate,
              Date().timeIntervalSince(modifiedAt) <= maxAge,
              let data = try? Data(contentsOf: url),
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

    private func readGeminiOAuthCreds() -> [String: Any]? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/oauth_creds.json")
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private func geminiAccessToken() async -> String? {
        guard let creds = readGeminiOAuthCreds() else { return nil }

        let expiryMs = doubleValue(creds["expiry_date"])
        let expiresAt = expiryMs.map { Date(timeIntervalSince1970: $0 > 10_000_000_000 ? $0 / 1000 : $0) }
        if let token = creds["access_token"] as? String,
           !token.isEmpty,
           expiresAt.map({ $0.timeIntervalSinceNow > 300 }) != false {
            return token
        }

        return await refreshGeminiAccessToken(creds: creds)
    }

    private func refreshGeminiAccessToken(creds: [String: Any]) async -> String? {
        guard let refreshToken = creds["refresh_token"] as? String, !refreshToken.isEmpty else {
            return creds["access_token"] as? String
        }

        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "client_id": "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com",
            "client_secret": "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",
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
                return creds["access_token"] as? String
            }
            writeGeminiOAuthCreds(existing: creds, refreshed: root)
            return accessToken
        } catch {
            return creds["access_token"] as? String
        }
    }

    private func writeGeminiOAuthCreds(existing: [String: Any], refreshed: [String: Any]) {
        var merged = existing
        if let token = refreshed["access_token"] as? String { merged["access_token"] = token }
        if let token = refreshed["id_token"] as? String { merged["id_token"] = token }
        if let token = refreshed["refresh_token"] as? String { merged["refresh_token"] = token }
        if let expiresIn = doubleValue(refreshed["expires_in"]) {
            merged["expiry_date"] = Date().timeIntervalSince1970 * 1000 + expiresIn * 1000
        }

        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/oauth_creds.json")
        guard JSONSerialization.isValidJSONObject(merged),
              let data = try? JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: path, options: .atomic)
    }

    private func fetchGeminiLoadCodeAssist(accessToken: String) async -> [String: Any]? {
        var req = URLRequest(url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = """
        {"metadata":{"ideType":"IDE_UNSPECIFIED","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI","duetProject":"default"}}
        """.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse).map({ 200 ... 299 ~= $0.statusCode }) == true else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }

    private func fetchGeminiQuota(accessToken: String, projectID: String?) async -> [String: Any]? {
        var req = URLRequest(url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = projectID == nil ? "{}" : "{\"project\":\"\(projectID!)\"}"
        req.httpBody = body.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse).map({ 200 ... 299 ~= $0.statusCode }) == true else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }

    private func readGeminiProjectID() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/settings.json")
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let v = obj["cloudaicompanionProject"] as? String, !v.isEmpty { return v }
        if let v = obj["project"] as? String, !v.isEmpty { return v }
        return nil
    }

    private func readFirstStringDeep(_ value: Any?, keys: Set<String>) -> String? {
        guard let value else { return nil }
        if let dict = value as? [String: Any] {
            for key in keys {
                if let found = dict[key] as? String, !found.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return found
                }
            }
            for child in dict.values {
                if let found = readFirstStringDeep(child, keys: keys) {
                    return found
                }
            }
        } else if let arr = value as? [Any] {
            for child in arr {
                if let found = readFirstStringDeep(child, keys: keys) {
                    return found
                }
            }
        }
        return nil
    }

    private func extractGeminiQuotaBuckets(_ root: [String: Any]) -> [GeminiQuotaBucket] {
        var buckets: [GeminiQuotaBucket] = []
        func walk(_ node: Any) {
            if let arr = node as? [Any] {
                for x in arr { walk(x) }
                return
            }
            guard let dict = node as? [String: Any] else { return }
            if let modelID = dict["modelId"] as? String,
               let remaining = dict["remainingFraction"] as? Double {
                let reset = (dict["resetTime"] as? String).flatMap { parseISO8601($0) }
                buckets.append(GeminiQuotaBucket(modelID: modelID.lowercased(), remainingFraction: remaining, resetAt: reset))
            }
            for v in dict.values { walk(v) }
        }

        walk(root)
        return buckets
    }

    private func bestGeminiBucket(_ buckets: [GeminiQuotaBucket], contains needle: String) -> GeminiQuotaBucket? {
        buckets
            .filter { $0.modelID.contains(needle) }
            .min { $0.remainingFraction < $1.remainingFraction }
    }

    private func parseTokenPossiblyJSON(_ raw: String) -> String? {
        if raw.hasPrefix("sk-ant-") || raw.hasPrefix("sk-ant-oat") { return raw }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let oauth = obj["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String { return token }
        if let token = obj["accessToken"] as? String { return token }
        return nil
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
        let body = [
            "client_id": "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com",
            "client_secret": "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",
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

    private func doubleValue(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? String { return Double(value) }
        return nil
    }

    private func urlEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    private func parseISO8601(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }

        let standard = ISO8601DateFormatter()
        return standard.date(from: raw)
    }

    private func extractFlag(_ key: String, from command: String) -> String? {
        let pattern = "\(NSRegularExpression.escapedPattern(for: key))\\s+([^\\s]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = command as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = regex.firstMatch(in: command, range: range), m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private func runShell(_ script: String) -> String {
        runCommand("/bin/zsh", ["-lc", script])
    }

    private func runCommand(_ launchPath: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}

private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            let nanos = UInt64(max(0, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
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
    let credits: CodexCredits?
}

private struct CodexCredits: Decodable {
    let has_credits: Bool?
    let balance: String?
}

private struct CodexRateWindow: Decodable {
    let used_percent: Double?
    let window_minutes: Int?
    let resets_at: Int?
}

private struct CodexWindowSummary {
    let usedPercent: Double
    let resetAt: Date?
}

private struct GeminiQuotaBucket {
    let modelID: String
    let remainingFraction: Double
    let resetAt: Date?
}


