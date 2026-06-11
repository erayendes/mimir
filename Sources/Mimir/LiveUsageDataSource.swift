import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published var services: [ServiceStatus] = LiveUsageDataSource.fallbackServices()
    @Published var isRefreshing = false
    @Published var availableUpdate: AvailableUpdate?
    private let source = LiveUsageDataSource()
    private var lastUpdateCheck: Date?

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

    /// Check GitHub for a newer release. Runs at most once per 24h (the timer calls it
    /// every tick; the first call after launch always runs since lastUpdateCheck is nil).
    /// Non-blocking and silent: any network/parse failure leaves the banner untouched.
    func checkForUpdate() {
        if let last = lastUpdateCheck, Date().timeIntervalSince(last) < 24 * 3_600 { return }
        lastUpdateCheck = Date()
        guard let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              !current.isEmpty else {
            return  // dev builds carry no version string — skip rather than nag
        }
        Task {
            guard let update = await LiveUsageDataSource.fetchLatestRelease(current: current) else { return }
            self.availableUpdate = update
        }
    }
}

struct LiveUsageDataSource {
    /// Fetch the latest GitHub release and return it only if newer than `current`.
    static func fetchLatestRelease(current: String) async -> AvailableUpdate? {
        guard let url = URL(string: "https://api.github.com/repos/erayendes/mimir/releases/latest") else {
            return nil
        }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Mimir", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse).map({ 200 ... 299 ~= $0.statusCode }) == true,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String,
              VersionCompare.isNewer(tag, than: current) else {
            return nil
        }

        let pageURL = (root["html_url"] as? String).flatMap(URL.init)
            ?? URL(string: "https://github.com/erayendes/mimir/releases/latest")!
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return AvailableUpdate(version: version, url: pageURL)
    }

    static func fallbackServices() -> [ServiceStatus] {
        [
            ServiceStatus(
                name: "Antigravity",
                iconName: "antigravity",
                sessionResetAt: nil,
                weeklyResetAt: nil,
                models: [
                    ModelStatus(name: "Claude", remainingPercent: 0, resetAt: nil),
                    ModelStatus(name: "Gemini Pro", remainingPercent: 0, resetAt: nil),
                    ModelStatus(name: "Gemini Flash", remainingPercent: 0, resetAt: nil)
                ],
                isAvailable: false,
                statusNote: "no local source"
            ),
            ServiceStatus(
                name: "Claude",
                iconName: "claude",
                sessionResetAt: nil,
                weeklyResetAt: nil,
                models: [],
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
            )
        ]
    }

    func fetchAll() async -> [ServiceStatus] {
        let order = ["Antigravity", "Claude", "Codex"]
        return await withTaskGroup(of: ServiceStatus.self) { group in
            group.addTask { await withTimeout(seconds: 8) { await fetchClaude() } ?? Self.fallbackServices().first(where: { $0.name == "Claude" })! }
            group.addTask { await withTimeout(seconds: 8) { await fetchCodex() } ?? Self.fallbackServices().first(where: { $0.name == "Codex" })! }
            group.addTask { await withTimeout(seconds: 8) { await fetchAntigravity() } ?? Self.fallbackServices().first(where: { $0.name == "Antigravity" })! }

            var out: [ServiceStatus] = []
            for await item in group {
                out.append(item)
            }
            return out.sorted { order.firstIndex(of: $0.name) ?? 99 < order.firstIndex(of: $1.name) ?? 99 }
        }
    }

    private func fetchClaude() async -> ServiceStatus {
        if let cached = readClaudeUsageCache(maxAge: 5 * 60) {
            return buildClaudeStatus(from: cached, note: "oauth usage cache")
        }

        guard let token = readClaudeToken() else {
            return unavailableService(name: "Claude", iconName: "claude", models: [], note: "claude token missing")
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return unavailableService(name: "Claude", iconName: "claude", models: [], note: "claude no http response")
            }
            guard 200 ... 299 ~= http.statusCode else {
                if let cached = readClaudeUsageCache(maxAge: 24 * 60 * 60) {
                    return buildClaudeStatus(from: cached, note: "oauth usage cache (http \(http.statusCode))")
                }
                return unavailableService(name: "Claude", iconName: "claude", models: [], note: "claude http \(http.statusCode)")
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return unavailableService(name: "Claude", iconName: "claude", models: [], note: "claude response parse fail")
            }
            writeClaudeUsageCache(data)

            return buildClaudeStatus(from: root, note: "oauth usage api")
        } catch {
            if let cached = readClaudeUsageCache(maxAge: 24 * 60 * 60) {
                return buildClaudeStatus(from: cached, note: "oauth usage cache")
            }
            return unavailableService(name: "Claude", iconName: "claude", models: [], note: "claude request failed")
        }
    }

    private func buildClaudeStatus(from root: [String: Any], note: String) -> ServiceStatus {
        let fiveHour = mergeClaudeWindows(root: root, baseKey: "five_hour")
        let sevenDay = mergeClaudeWindows(root: root, baseKey: "seven_day")
        let sonnet = mergeClaudeWindows(root: root, baseKey: "seven_day_sonnet")

        var models: [ModelStatus] = []
        if sonnet.utilization > 0 || sonnet.resetAt != nil {
            models.append(ModelStatus(
                name: "Sonnet",
                remainingPercent: remainingPercent(fromUsed: sonnet.utilization),
                resetAt: sonnet.resetAt ?? sevenDay.resetAt
            ))
        }

        return ServiceStatus(
            name: "Claude",
            iconName: "claude",
            sessionResetAt: fiveHour.resetAt,
            weeklyResetAt: sevenDay.resetAt,
            sessionRemainingPercent: remainingPercent(fromUsed: fiveHour.utilization),
            weeklyRemainingPercent: remainingPercent(fromUsed: sevenDay.utilization),
            models: models,
            isAvailable: true,
            statusNote: note
        )
    }

    private func remainingPercent(fromUsed used: Double) -> Int {
        max(0, min(100, Int((100 - used).rounded())))
    }

    private func fetchCodex() async -> ServiceStatus {
        if let apiStatus = await fetchCodexUsageAPI() {
            return apiStatus
        }

        return fetchCodexLocalSessions()
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
                models: [],
                isAvailable: true,
                statusNote: "chatgpt usage api"
            )
        } catch {
            return nil
        }
    }

    private func fetchAntigravity() async -> ServiceStatus {
        let defaults = ["Gemini", "Claude"]
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
            ? "open Antigravity or Cockpit"
            : "antigravity auth failed"
        return unavailableService(name: "Antigravity", iconName: "antigravity", models: defaults, note: note)
    }

    private var antigravitySnapshotURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mimir/antigravity_snapshot.json")
    }

    /// Persist the last live Antigravity reading so it can be shown while the IDE is closed.
    private func saveAntigravitySnapshot(_ service: ServiceStatus) {
        guard service.isAvailable, !service.models.isEmpty else { return }
        let iso = ISO8601DateFormatter()
        let models: [[String: Any]] = service.models.map { m in
            var dict: [String: Any] = ["name": m.name, "remainingPercent": m.remainingPercent]
            if let reset = m.resetAt { dict["resetAt"] = iso.string(from: reset) }
            if let valueText = m.valueText { dict["valueText"] = valueText }
            return dict
        }
        let payload: [String: Any] = ["models": models]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let url = antigravitySnapshotURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    /// Read the persisted snapshot. Shows the last-known values until the earliest
    /// reset time passes; after that the quota has refilled so the cached numbers are
    /// stale and the card is marked "güncel değil" instead of showing wrong percentages.
    private func fetchAntigravitySnapshot() -> ServiceStatus? {
        guard let data = try? Data(contentsOf: antigravitySnapshotURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawModels = root["models"] as? [[String: Any]], !rawModels.isEmpty else {
            return nil
        }

        let now = Date()
        // A cached number stays accurate only until that model's quota resets; after the
        // reset the quota has refilled, so drop it. Each model is judged on its own clock.
        let valid: [ModelStatus] = rawModels.compactMap { dict in
            guard let name = dict["name"] as? String,
                  let resetStr = dict["resetAt"] as? String,
                  let reset = parseISO8601(resetStr), now < reset else { return nil }
            let percent = dict["remainingPercent"] as? Int ?? 0
            return ModelStatus(name: name, remainingPercent: percent, resetAt: reset,
                               valueText: dict["valueText"] as? String)
        }

        // Every cached model has passed its reset → numbers are stale, don't show them.
        guard !valid.isEmpty else {
            return unavailableService(name: "Antigravity", iconName: "antigravity",
                                      models: ["Gemini", "Claude"], note: "güncel değil")
        }

        return ServiceStatus(
            name: "Antigravity",
            iconName: "antigravity",
            sessionResetAt: valid.compactMap(\.resetAt).min(),
            weeklyResetAt: nil,
            models: valid,
            isAvailable: true,
            statusNote: "antigravity snapshot"
        )
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

    private func fetchAntigravityLocalLanguageServer(models defaults: [String]) -> ServiceStatus? {
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

        let body = "{\"metadata\":{\"ideName\":\"antigravity\",\"extensionName\":\"antigravity\",\"locale\":\"en\",\"ideVersion\":\"unknown\"}}"
        var payload: [String: Any]?
        for p in ports {
            let out = runCommand("/usr/bin/curl", [
                "-ks", "--max-time", "2",
                "-H", "X-Codeium-Csrf-Token: \(csrf)",
                "-H", "Connect-Protocol-Version: 1",
                "-H", "Content-Type: application/json",
                "--data", body,
                "https://127.0.0.1:\(p)/exa.language_server_pb.LanguageServerService/GetUserStatus"
            ])
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
            models: models.map { ModelStatus(name: $0, remainingPercent: 0, resetAt: nil) },
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

    private func codexAPIWindow(_ raw: Any?) -> (usedPercent: Double?, resetAt: Date?) {
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
        try? data.write(to: state.path, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: state.path.path)
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

    private func parseTokenPossiblyJSON(_ raw: String) -> String? {
        if raw.hasPrefix("sk-ant-") || raw.hasPrefix("sk-ant-oat") { return raw }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let oauth = obj["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String { return token }
        if let token = obj["accessToken"] as? String { return token }
        return nil
    }

    private func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        if padding > 0 {
            base64 += String(repeating: "=", count: padding)
        }
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return payload
    }

    private func jwtExpiry(_ token: String) -> Date? {
        guard let payload = decodeJWTPayload(token),
              let exp = doubleValue(payload["exp"]) else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
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

    private func doubleValue(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? String { return Double(value) }
        return nil
    }

    private func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
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
        // Handles both --key value and --key=value styles
        let pattern = "\(NSRegularExpression.escapedPattern(for: key))(?:[\\s=]+)([^\\s]+)"
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

