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

    /// `userInitiated` is forwarded to the Claude fetch so it knows whether it may read Claude
    /// Code's own keychain item (the prompt-triggering source). The 60s background timer passes
    /// `false`; opening the menu-bar panel passes `true`. See `fetchClaude(userInitiated:)`.
    func refresh(userInitiated: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        let now = Date()
        let skip = Set(cooldownUntil.compactMap { $0.value > now ? $0.key : nil })
        let source = self.source
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                await source.fetchAll(skip: skip, userInitiated: userInitiated).sorted { $0.name < $1.name }
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
    func fetchAll(skip: Set<String> = [], userInitiated: Bool = false) async -> [ServiceStatus] {
        let order = ["Antigravity", "Claude", "Codex"]
        return await withTaskGroup(of: ServiceStatus.self) { group in
            group.addTask {
                if skip.contains("Claude") { return self.snapshotOrFallback("Claude", iconName: "claude") }
                return await withTimeout(seconds: 8) { await fetchClaude(userInitiated: userInitiated) }
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

    /// Write `data` to `targetURL` without ever exposing it through a world-readable window. The usual
    /// `write(.atomic)` + `setAttributes(0o600)` leaves the file briefly at the umask default (e.g.
    /// 0644) before the chmod — a TOCTOU window where another local process could read a token. Instead,
    /// create a temp file already at `permissions`, then atomically swap it in. Used for the credential/
    /// token writes (Codex auth, Claude credential file), not the non-secret quota snapshots.
    static func secureAtomicWrite(data: Data, to targetURL: URL, permissions: Int = 0o600) throws {
        let fm = FileManager.default
        // Follow symlinks to the real file: if the credential path is a symlink (a common dotfile-
        // manager pattern, e.g. ~/.codex/auth.json → elsewhere), update the linked file and keep the
        // link, rather than replacing the symlink node itself and stranding the real file. The old
        // `write(.atomic)` wrote through the link, so this preserves that behaviour.
        let target = targetURL.resolvingSymlinksInPath()
        let dir = target.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let tempURL = dir.appendingPathComponent(UUID().uuidString)
        guard fm.createFile(atPath: tempURL.path, contents: data,
                            attributes: [.posixPermissions: permissions]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            if fm.fileExists(atPath: target.path) {
                // `.usingNewMetadataOnly` keeps the temp's restrictive permissions instead of
                // inheriting the original file's (which may be looser).
                _ = try fm.replaceItemAt(target, withItemAt: tempURL, options: .usingNewMetadataOnly)
            } else {
                try fm.moveItem(at: tempURL, to: target)
            }
        } catch {
            try? fm.removeItem(at: tempURL)
            throw error
        }
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

        // Live source unreachable long enough (>4.5 h — just under the 5-hour session window, beyond
        // which the last-known session reading is from a window that has already rotated, so it's
        // provably stale; a shorter horizon cried wolf on normal breaks) that the snapshot can't be
        // trusted. Only providers that map to an installable GUI app get the "couldn't fetch — open it"
        // state, and only while that app is actually installed:
        //   • mapped + installed     → unavailable card (keeps model labels for the empty state). It's
        //                               `isAvailable: false` so a stale snapshot never fires a
        //                               low/refill notification (see checkNotifications), only `isStale`
        //                               so it still survives the popover/menu-bar/widget filters.
        //   • mapped + NOT installed → nil → falls back to hidden (don't nag to open a missing app).
        //   • unmapped (Claude/Codex)→ fall through to staleClassifiedCard (CLIs/APIs, nothing to open).
        if let savedRaw = root["savedAt"] as? String, let saved = parseISO8601(savedRaw),
           now.timeIntervalSince(saved) > 4.5 * 3600,
           AppTarget.bundleID(for: service) != nil {
            guard AppTarget.installedURL(for: service) != nil else { return nil }
            return ServiceStatus(
                name: service, iconName: iconName,
                sessionResetAt: sessionReset, weeklyResetAt: weeklyReset,
                sessionRemainingPercent: root["sessionRemainingPercent"] as? Int,
                weeklyRemainingPercent: root["weeklyRemainingPercent"] as? Int,
                models: allModels, isAvailable: false, statusNote: staleNote,
                isStale: true, dataUnavailable: true)
        }

        return staleClassifiedCard(
            name: service, iconName: iconName,
            sessionPct: root["sessionRemainingPercent"] as? Int, sessionReset: sessionReset,
            weeklyPct: root["weeklyRemainingPercent"] as? Int, weeklyReset: weeklyReset,
            models: allModels, freshNote: freshNote, staleNote: staleNote)
    }

    /// Standard reset periods for the quota windows all three providers expose: a 5-hour session and a
    /// 7-day week. Used only to roll a *lapsed* last-known reset forward to the next boundary so the
    /// countdown stays meaningful (the window itself really did refill); the live fetch always carries
    /// the exact `resets_at`.
    static let sessionResetPeriod: TimeInterval = 5 * 60 * 60
    static let weeklyResetPeriod: TimeInterval = 7 * 24 * 60 * 60

    /// Classify a last-known reading by reset time. A window/model still within its reset keeps its
    /// real percent; one whose reset has already passed has *refilled to full*, so it shows 100% with
    /// its reset rolled forward to the next boundary — NOT blanked (which made the session vanish and
    /// dropped the provider from the widget) and NOT dropped (which made per-model rows like Fable
    /// disappear). When every row is only a refilled estimate (nothing still inside its original
    /// window) the card is dimmed (`isStale`) so it reads as last-known rather than live. Returns nil
    /// only when there is no data at all.
    func staleClassifiedCard(name: String, iconName: String,
                                     sessionPct: Int?, sessionReset: Date?,
                                     weeklyPct: Int?, weeklyReset: Date?,
                                     models: [ModelStatus],
                                     freshNote: String, staleNote: String) -> ServiceStatus? {
        guard sessionPct != nil || weeklyPct != nil || !models.isEmpty else { return nil }
        let now = Date()

        // Advance a passed reset to the next future boundary so a refilled window still shows a live
        // countdown instead of a stale/blank one.
        func rollForward(_ reset: Date?, _ period: TimeInterval) -> Date? {
            guard let reset, period > 0, reset <= now else { return reset }
            let steps = (now.timeIntervalSince(reset) / period).rounded(.down) + 1
            return reset.addingTimeInterval(steps * period)
        }
        // (displayPct, displayReset, stillInWindow) for a window: in-window keeps its real number,
        // lapsed refills to 100% with the reset rolled forward.
        func window(_ pct: Int?, _ reset: Date?, _ period: TimeInterval) -> (pct: Int?, reset: Date?, live: Bool) {
            guard let pct else { return (nil, nil, false) }
            let live = reset.map { now < $0 } ?? true
            return live ? (pct, reset, true) : (100, rollForward(reset, period), false)
        }

        let s = window(sessionPct, sessionReset, Self.sessionResetPeriod)
        let w = window(weeklyPct, weeklyReset, Self.weeklyResetPeriod)
        // Keep every model row: an in-window one as-is, a lapsed (refilled) one at 100% with its weekly
        // reset rolled forward. Value rows (billing) carry no resetting percent — pass them through.
        let rows = models.map { m -> (row: ModelStatus, live: Bool) in
            if m.valueText != nil { return (m, true) }
            let live = m.resetAt.map { now < $0 } ?? true
            if live { return (m, true) }
            return (ModelStatus(name: m.name, remainingPercent: 100, resetAt: rollForward(m.resetAt, Self.weeklyResetPeriod)), false)
        }

        let anyLive = s.live || w.live || rows.contains { $0.live }
        return ServiceStatus(
            name: name, iconName: iconName,
            sessionResetAt: s.reset, weeklyResetAt: w.reset,
            sessionRemainingPercent: s.pct, weeklyRemainingPercent: w.pct,
            models: rows.map(\.row),
            isAvailable: true,
            statusNote: anyLive ? freshNote : staleNote,
            isStale: !anyLive)
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

