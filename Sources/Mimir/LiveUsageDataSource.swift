import Foundation
import Security

@MainActor
final class UsageStore: ObservableObject {
    @Published var services: [ServiceStatus] = LiveUsageDataSource.fallbackServices()
    @Published var isRefreshing = false
    private let source = LiveUsageDataSource()
    /// Per-service fetch cooldown: while `Date()` is before the stored value, that service is
    /// served from its snapshot instead of hitting the network (set after an HTTP 429 / expired
    /// token; cleared on the next live success). Stops Mimir hammering a failing endpoint.
    private var cooldownUntil: [String: Date] = [:]

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let now = Date()
        let skip = Set(cooldownUntil.compactMap { $0.value > now ? $0.key : nil })
        let source = self.source
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                await source.fetchAll(skip: skip).sorted { $0.name < $1.name }
            }.value
            for status in result { self.applyCooldownOutcome(status) }
            self.services = result
            self.isRefreshing = false
        }
    }

    /// Translate a fetch result's `cooldownHint` into the cooldown map: `nil` leaves it unchanged,
    /// `<= 0` clears it (live success), `> 0` parks the service for that many seconds.
    private func applyCooldownOutcome(_ status: ServiceStatus) {
        guard let hint = status.cooldownHint else { return }
        if hint <= 0 {
            cooldownUntil[status.name] = nil
        } else {
            cooldownUntil[status.name] = Date().addingTimeInterval(hint)
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
                    ModelStatus(name: "Claude", remainingPercent: 0, resetAt: nil),
                    ModelStatus(name: "Gemini Pro", remainingPercent: 0, resetAt: nil),
                    ModelStatus(name: "Gemini Flash", remainingPercent: 0, resetAt: nil)
                ],
                isAvailable: false,
                statusNote: String(localized: "no local source")
            ),
            ServiceStatus(
                name: "Claude",
                iconName: "claude",
                sessionResetAt: nil,
                weeklyResetAt: nil,
                models: [],
                isAvailable: false,
                statusNote: String(localized: "no local source")
            ),
            ServiceStatus(
                name: "Codex",
                iconName: "codex",
                sessionResetAt: nil,
                weeklyResetAt: nil,
                models: [],
                isAvailable: false,
                statusNote: String(localized: "no local source")
            )
        ]
    }

    /// Explains how Antigravity quota is sourced and why it may not be current. Surfaced
    /// behind the (i) icon on the Antigravity card.
    static let antigravityInfo = String(localized: "Quota is read from Antigravity's local language server. Antigravity must be running for live data; when it's closed, the last seen values are shown.")

    /// Fetch every service. Services named in `skip` are in a fetch cooldown (e.g. after a 429)
    /// and are served from their snapshot instead of hitting the network. A live fetch that times
    /// out also falls back to the snapshot, so a transient failure never empties a card.
    func fetchAll(skip: Set<String> = []) async -> [ServiceStatus] {
        let order = ["Antigravity", "Claude", "Codex"]
        return await withTaskGroup(of: ServiceStatus.self) { group in
            group.addTask {
                if skip.contains("Claude") { return self.snapshotOrFallback("Claude", iconName: "claude") }
                return await withTimeout(seconds: 8) { await fetchClaude() }
                    ?? self.snapshotOrFallback("Claude", iconName: "claude")
            }
            group.addTask {
                if skip.contains("Codex") { return self.snapshotOrFallback("Codex", iconName: "codex") }
                return await withTimeout(seconds: 8) { await fetchCodex() }
                    ?? self.snapshotOrFallback("Codex", iconName: "codex")
            }
            group.addTask {
                if skip.contains("Antigravity") { return self.snapshotOrFallback("Antigravity", iconName: "antigravity").withInfoText(Self.antigravityInfo) }
                let status = await withTimeout(seconds: 8) { await fetchAntigravity() }
                    ?? self.snapshotOrFallback("Antigravity", iconName: "antigravity")
                return status.withInfoText(Self.antigravityInfo)
            }

            var out: [ServiceStatus] = []
            for await item in group {
                out.append(item)
            }
            return out.sorted { order.firstIndex(of: $0.name) ?? 99 < order.firstIndex(of: $1.name) ?? 99 }
        }
    }

    private func fetchClaude() async -> ServiceStatus {
        if let cached = readClaudeUsageCache(maxAge: 5 * 60) {
            return buildClaudeStatus(from: cached, note: "oauth usage cache").withCooldownHint(0)
        }

        // Reuse the in-memory token while it's comfortably valid, so the keychain — and its macOS
        // permission prompt — is touched only at launch and around token expiry, not every refresh.
        var tokenInfo = await Self.claudeTokenCache.get()
        let needsKeychain = tokenInfo.map { $0.expiresAt.map { $0.timeIntervalSinceNow <= 300 } ?? false } ?? true

        if needsKeychain {
            guard let read = readClaudeTokenInfo() else {
                return claudeFailure(note: "claude token missing")
            }
            tokenInfo = read

            // Refresh proactively when the freshly-read token is expired or within 5 min of expiry.
            // Anthropic rotates the refresh token, so `refreshClaudeToken()` writes the new pair back
            // to the keychain — keeping Claude Code's own login valid. If refresh fails, back off.
            if let exp = read.expiresAt, exp.timeIntervalSinceNow <= 300 {
                guard let fresh = await refreshClaudeToken() else {
                    let note = String(localized: "token expired — open Claude Code")
                    return claudeFailure(note: note, staleNote: note).withCooldownHint(15 * 60)
                }
                tokenInfo = fresh
            }
            await Self.claudeTokenCache.set(tokenInfo)
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
                // A rejected token is likely stale (rotated out by Claude Code); drop the cache so the
                // next refresh re-reads the keychain instead of replaying the dead token.
                if http.statusCode == 401 || http.statusCode == 403 {
                    await Self.claudeTokenCache.set(nil)
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

    func remainingPercent(fromUsed used: Double) -> Int {
        max(0, min(100, Int((100 - used).rounded())))
    }

    /// Claude pay-as-you-go billing from the usage API's `extra_usage: { is_enabled, monthly_limit,
    /// used_credits, utilization, currency }`. Returns nil when not enabled (Pro without overage), so
    /// the row is omitted — matching the issue's "fall back silently when billing isn't applicable".
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


    private func fetchAntigravity() async -> ServiceStatus {
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

    // MARK: - Generic last-known snapshot (shared by all services)

    func snapshotURL(for service: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mimir/\(service.lowercased())_snapshot.json")
    }

    /// Persist the last live reading of any service so it can be shown (dimmed, marked stale)
    /// when the live source later fails, instead of the card silently vanishing. Never persists
    /// an unavailable reading. Captures the two account-level windows (Claude/Codex) and/or the
    /// per-model rows (Antigravity); every key is optional, so each service writes only what it has.
    func saveSnapshot(_ status: ServiceStatus) {
        guard status.isAvailable else { return }
        let hasData = status.sessionRemainingPercent != nil
            || status.weeklyRemainingPercent != nil
            || !status.models.isEmpty
        guard hasData else { return }

        let iso = ISO8601DateFormatter()
        var payload: [String: Any] = ["version": 1, "savedAt": iso.string(from: Date())]
        if let p = status.sessionRemainingPercent { payload["sessionRemainingPercent"] = p }
        if let p = status.weeklyRemainingPercent { payload["weeklyRemainingPercent"] = p }
        if let d = status.sessionResetAt { payload["sessionResetAt"] = iso.string(from: d) }
        if let d = status.weeklyResetAt { payload["weeklyResetAt"] = iso.string(from: d) }
        if !status.models.isEmpty {
            payload["models"] = status.models.map { m -> [String: Any] in
                var dict: [String: Any] = ["name": m.name, "remainingPercent": m.remainingPercent]
                if let reset = m.resetAt { dict["resetAt"] = iso.string(from: reset) }
                if let valueText = m.valueText { dict["valueText"] = valueText }
                if let w = m.window { dict["window"] = (w == .weekly) ? "weekly" : "session" }
                return dict
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let url = snapshotURL(for: status.name)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Load a service's snapshot, classifying each window by reset time: a window whose reset is
    /// still in the future shows its cached percent; one that has already reset is blanked (the
    /// real quota has refilled). Any fresh window/model → a normal (available) card from cache;
    /// all stale → a dimmed `isStale` card marked with `staleNote`, still visible so the service
    /// never vanishes. Returns nil only when the file is missing, corrupt, or past the 30-day cap.
    func loadSnapshot(for service: String, iconName: String,
                              freshNote: String = "snapshot", staleNote: String = String(localized: "out of date")) -> ServiceStatus? {
        guard let data = try? Data(contentsOf: snapshotURL(for: service)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let now = Date()
        // Past ~30 days a snapshot is archaeology, not data.
        if let savedRaw = root["savedAt"] as? String, let saved = parseISO8601(savedRaw),
           now.timeIntervalSince(saved) > 30 * 24 * 3_600 {
            return nil
        }

        let allModels: [ModelStatus] = (root["models"] as? [[String: Any]] ?? []).compactMap { dict in
            guard let name = dict["name"] as? String else { return nil }
            let percent = dict["remainingPercent"] as? Int ?? 0
            let reset = (dict["resetAt"] as? String).flatMap { parseISO8601($0) }
            let window: ModelWindow? = switch dict["window"] as? String {
            case "weekly": .weekly
            case "session": .session
            default: nil
            }
            return ModelStatus(name: name, remainingPercent: percent, resetAt: reset,
                               valueText: dict["valueText"] as? String, window: window)
        }
        let sessionReset = (root["sessionResetAt"] as? String).flatMap { parseISO8601($0) }
        let weeklyReset = (root["weeklyResetAt"] as? String).flatMap { parseISO8601($0) }
        return staleClassifiedCard(
            name: service, iconName: iconName,
            sessionPct: root["sessionRemainingPercent"] as? Int, sessionReset: sessionReset,
            weeklyPct: root["weeklyRemainingPercent"] as? Int, weeklyReset: weeklyReset,
            models: allModels, freshNote: freshNote, staleNote: staleNote)
    }

    /// Classify a last-known reading by reset time. A window keeps its cached percent while its
    /// reset is still in the future — or while it has no reset time at all, since then nothing has
    /// invalidated it; a window whose reset has already passed is blanked (its quota refilled). Any
    /// fresh window/model → an available card; everything stale → a dimmed `isStale` card. Returns
    /// nil only when there is no data at all.
    func staleClassifiedCard(name: String, iconName: String,
                                     sessionPct: Int?, sessionReset: Date?,
                                     weeklyPct: Int?, weeklyReset: Date?,
                                     models: [ModelStatus],
                                     freshNote: String, staleNote: String) -> ServiceStatus? {
        guard sessionPct != nil || weeklyPct != nil || !models.isEmpty else { return nil }
        let now = Date()
        let sessionFresh = sessionPct != nil && (sessionReset.map { now < $0 } ?? true)
        let weeklyFresh = weeklyPct != nil && (weeklyReset.map { now < $0 } ?? true)
        let freshModels = models.filter { ($0.resetAt.map { now < $0 }) ?? true }

        if sessionFresh || weeklyFresh || !freshModels.isEmpty {
            return ServiceStatus(
                name: name, iconName: iconName,
                sessionResetAt: sessionFresh ? sessionReset : nil,
                weeklyResetAt: weeklyFresh ? weeklyReset : nil,
                sessionRemainingPercent: sessionFresh ? sessionPct : nil,
                weeklyRemainingPercent: weeklyFresh ? weeklyPct : nil,
                models: freshModels,
                isAvailable: true, statusNote: freshNote)
        }

        return ServiceStatus(
            name: name, iconName: iconName,
            sessionResetAt: nil, weeklyResetAt: nil,
            sessionRemainingPercent: sessionPct, weeklyRemainingPercent: weeklyPct,
            models: models,
            isAvailable: false, statusNote: staleNote, isStale: true)
    }

    /// Antigravity keeps its original method names as thin wrappers over the generic helpers,
    /// so its fetch chain (and the "antigravity snapshot" / "out of date" labels) is unchanged.
    func saveAntigravitySnapshot(_ service: ServiceStatus) { saveSnapshot(service) }
    func fetchAntigravitySnapshot() -> ServiceStatus? {
        loadSnapshot(for: "Antigravity", iconName: "antigravity", freshNote: "antigravity snapshot")
    }

    /// Last-known snapshot for a service, else its hidden fallback card. Used when a fetch is
    /// skipped (cooldown) or times out, so the card shows stale data instead of disappearing.
    func snapshotOrFallback(_ name: String, iconName: String) -> ServiceStatus {
        loadSnapshot(for: name, iconName: iconName)
            ?? Self.fallbackServices().first { $0.name == name }!
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

    func unavailableService(name: String, iconName: String, models: [String], note: String? = nil) -> ServiceStatus {
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

    func latestJSONLFile(in directory: URL) -> URL? {
        latestFile(in: directory, pathExtension: "jsonl")
    }

    func latestFile(in directory: URL, pathExtension: String) -> URL? {
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


    private struct ClaudeToken {
        let accessToken: String
        let expiresAt: Date?   // nil when the source is a bare token with no expiry metadata
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

    /// Read the Claude Code OAuth token plus its expiry, from the keychain entry
    /// ("Claude Code-credentials") or the `~/.claude/.credentials.json` fallback. `expiresAt`
    /// drives whether `fetchClaude` refreshes before calling the usage API (see `refreshClaudeToken`).
    private func readClaudeTokenInfo() -> ClaudeToken? {
        if let raw = readClaudeKeychainItem()?.value,
           let info = parseClaudeToken(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return info
        }

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

    /// Claude stores `expiresAt` as epoch milliseconds (distinct from the ISO8601 used elsewhere).
    func epochMillisToDate(_ raw: Any?) -> Date? {
        guard let ms = doubleValue(raw), ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    private static let claudeKeychainService = "Claude Code-credentials"
    private static let claudeOAuthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

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

    /// Read the full Claude credential JSON and remember where it came from, so a refreshed token
    /// can be written back to the same store (preserving the rest of the blob, e.g. `mcpOAuth`).
    private func readClaudeCredential() -> (root: [String: Any], source: ClaudeCredentialSource)? {
        if let item = readClaudeKeychainItem(),
           let data = item.value.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           root["claudeAiOauth"] != nil {
            // SecItemUpdate locates the entry to rewrite by account; fall back to the login name.
            if let account = item.account ?? (NSUserName().isEmpty ? nil : NSUserName()) {
                return (root, .keychain(account: account))
            }
        }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: url),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (root, .file(url))
        }
        return nil
    }

    /// Refresh Claude's access token with the stored refresh token, then write the rotated pair back
    /// to the same store so Claude Code's own login keeps working (Anthropic rotates the refresh
    /// token, so persisting it is mandatory). Returns the new access token, or nil on any failure.
    private func refreshClaudeToken() async -> ClaudeToken? {
        guard let credential = readClaudeCredential(),
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
        return ClaudeToken(accessToken: newAccess, expiresAt: epochMillisToDate(oauth["expiresAt"]))
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
            try? data.write(to: url, options: .atomic)
        }
    }

    func decodeJWTPayload(_ token: String) -> [String: Any]? {
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

    func jwtExpiry(_ token: String) -> Date? {
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

    func doubleValue(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? String { return Double(value) }
        return nil
    }

    func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    func parseISO8601(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }

        let standard = ISO8601DateFormatter()
        return standard.date(from: raw)
    }

    func extractFlag(_ key: String, from command: String) -> String? {
        // Handles both --key value and --key=value styles
        let pattern = "\(NSRegularExpression.escapedPattern(for: key))(?:[\\s=]+)([^\\s]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = command as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = regex.firstMatch(in: command, range: range), m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    func runShell(_ script: String) -> String {
        runCommand("/bin/zsh", ["-lc", script])
    }

    /// `stdin`, when set, is written to the process's standard input. Used to feed
    /// secrets (e.g. a curl `--config -` block) without exposing them in `arguments`,
    /// which are world-readable via the process table (`ps aux`).
    func runCommand(_ launchPath: String, _ args: [String], stdin: String? = nil) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        let input: Pipe? = stdin != nil ? Pipe() : nil
        if let input { p.standardInput = input }
        do {
            try p.run()
            if let input, let stdin {
                input.fileHandleForWriting.write(Data(stdin.utf8))
                input.fileHandleForWriting.closeFile()
            }
            p.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
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

