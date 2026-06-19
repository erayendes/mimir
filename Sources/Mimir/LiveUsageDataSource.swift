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


    func remainingPercent(fromUsed used: Double) -> Int {
        max(0, min(100, Int((100 - used).rounded())))
    }

    /// Claude pay-as-you-go billing from the usage API's `extra_usage: { is_enabled, monthly_limit,
    /// used_credits, utilization, currency }`. Returns nil when not enabled (Pro without overage), so
    /// the row is omitted — matching the issue's "fall back silently when billing isn't applicable".



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



    /// Claude stores `expiresAt` as epoch milliseconds (distinct from the ISO8601 used elsewhere).
    func epochMillisToDate(_ raw: Any?) -> Date? {
        guard let ms = doubleValue(raw), ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    static let claudeKeychainService = "Claude Code-credentials"
    static let claudeOAuthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"


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

}

func withTimeout<T: Sendable>(
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

