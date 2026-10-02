import Foundation

extension LiveUsageDataSource {
    /// Gemini CLI quota, read the way the CLI's own `/stats` does: the OAuth login it keeps in
    /// `~/.gemini/oauth_creds.json`, `loadCodeAssist` for the account's Code Assist project, then
    /// `retrieveUserQuota` for per-model buckets (a remaining fraction plus a daily reset).
    /// Hidden when the CLI has never been signed in with a Google account (API-key users have no quota).
    func fetchGemini() async -> ServiceStatus {
        guard let creds = readGeminiCredentials() else {
            return unavailableService(name: "Gemini", iconName: "gemini", models: [], note: "run gemini to sign in")
        }
        let refreshToken = creds["refresh_token"] as? String ?? ""
        if let token = await geminiAccessToken(creds),
           let project = await geminiProject(token: token, refreshToken: refreshToken),
           let buckets = await geminiQuotaBuckets(token: token, project: project) {
            let models = geminiQuotaRows(buckets: buckets)
            if !models.isEmpty {
                let status = ServiceStatus(
                    name: "Gemini",
                    iconName: "gemini",
                    sessionResetAt: models.compactMap(\.resetAt).min(),
                    weeklyResetAt: nil,
                    models: models,
                    isAvailable: true,
                    statusNote: "gemini cli"
                )
                saveSnapshot(status)
                return status
            }
        }
        return loadSnapshot(for: "Gemini", iconName: "gemini")
            ?? unavailableService(name: "Gemini", iconName: "gemini", models: [], note: "gemini auth failed")
    }

    /// One row per model family (Pro, Flash, Flash Lite), each at its most-spent bucket — the CLI
    /// reports every model version and its `_vertex` twin separately, but they share the family's limit.
    func geminiQuotaRows(buckets: [[String: Any]]) -> [ModelStatus] {
        var best: [String: (fraction: Double, reset: Date?)] = [:]
        for bucket in buckets {
            guard let model = (bucket["modelId"] as? String)?.lowercased(),
                  let fraction = doubleValue(bucket["remainingFraction"]) else { continue }
            let family: String
            if model.contains("flash-lite") { family = "Gemini Flash Lite" }
            else if model.contains("flash") { family = "Gemini Flash" }
            else if model.contains("pro") { family = "Gemini Pro" }
            else { continue }
            let reset = (bucket["resetTime"] as? String).flatMap { parseISO8601($0) }
            if let current = best[family], current.fraction <= fraction { continue }
            best[family] = (fraction, reset)
        }
        return ["Gemini Pro", "Gemini Flash", "Gemini Flash Lite"].compactMap { family in
            best[family].map {
                ModelStatus(name: family, remainingPercent: Int((min(1, max(0, $0.fraction)) * 100).rounded()),
                            resetAt: $0.reset, window: .session)
            }
        }
    }

    private func readGeminiCredentials() -> [String: Any]? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/oauth_creds.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["refresh_token"] is String || root["access_token"] is String else {
            return nil
        }
        return root
    }

    /// The file's token while it's good; otherwise a refreshed one, kept in memory only — the file
    /// belongs to the CLI, which rewrites it itself the next time it runs.
    private func geminiAccessToken(_ creds: [String: Any]) async -> String? {
        if let token = creds["access_token"] as? String,
           let expiry = epochMillisToDate(creds["expiry_date"]), expiry.timeIntervalSinceNow > 60 {
            return token
        }
        guard let refresh = creds["refresh_token"] as? String else { return nil }
        if let cached = Self.geminiRefreshed, cached.refresh == refresh, cached.expires.timeIntervalSinceNow > 60 {
            return cached.token
        }
        guard let client = geminiOAuthClient() else { return nil }

        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = [
            "client_id": client.id,
            "client_secret": client.secret,
            "refresh_token": refresh,
            "grant_type": "refresh_token"
        ]
            .map { "\($0.key)=\(urlEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
        guard let root = await geminiPost(req),
              let token = root["access_token"] as? String else { return nil }
        let lifetime = doubleValue(root["expires_in"]) ?? 3_600
        Self.geminiRefreshed = (refresh, token, Date().addingTimeInterval(lifetime))
        return token
    }

    /// The CLI's OAuth client, read from the installed CLI rather than baked in here, so a rotated
    /// client follows the CLI's own updates.
    /// ponytail: grep over the CLI's @google scope for the first client id/secret; tighten to
    /// oauth2.js if another @google package ever ships its own client.
    private func geminiOAuthClient() -> (id: String, secret: String)? {
        if Self.geminiClientLookedUp { return Self.geminiClient }
        Self.geminiClientLookedUp = true
        let out = runShell("""
            bin=$(command -v gemini) || exit 0
            scope="$(readlink -f "$(dirname "$(readlink -f "$bin")")/../..")" || exit 0
            [ "$(basename "$scope")" = "@google" ] || exit 0
            grep -rhoE --include='*.js' '[0-9]+-[0-9a-z]+\\.apps\\.googleusercontent\\.com|GOCSPX-[A-Za-z0-9_-]+' "$scope" 2>/dev/null | sort -u
            """)
        let lines = out.split(separator: "\n").map(String.init)
        guard let id = lines.first(where: { $0.hasSuffix(".apps.googleusercontent.com") }),
              let secret = lines.first(where: { $0.hasPrefix("GOCSPX-") }) else { return nil }
        Self.geminiClient = (id, secret)
        return (id, secret)
    }

    /// Cached per refresh token, so switching accounts in the Gemini CLI resolves the new project.
    private func geminiProject(token: String, refreshToken: String) async -> String? {
        if let cached = Self.geminiProjectID, cached.refresh == refreshToken { return cached.project }
        let body: [String: Any] = ["metadata": ["ideType": "IDE_UNSPECIFIED", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]]
        guard let root = await geminiPost(geminiRequest("loadCodeAssist", token: token, body: body)) else { return nil }
        // A string for most accounts, an object with `id` for some Workspace ones.
        let project = (root["cloudaicompanionProject"] as? String)
            ?? ((root["cloudaicompanionProject"] as? [String: Any])?["id"] as? String)
        Self.geminiProjectID = project.map { (refresh: refreshToken, project: $0) }
        return project
    }

    private func geminiQuotaBuckets(token: String, project: String) async -> [[String: Any]]? {
        await geminiPost(geminiRequest("retrieveUserQuota", token: token, body: ["project": project]))?["buckets"] as? [[String: Any]]
    }

    private func geminiRequest(_ method: String, token: String, body: [String: Any]) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:\(method)")!, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func geminiPost(_ req: URLRequest) async -> [String: Any]? {
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse).map({ 200 ... 299 ~= $0.statusCode }) == true else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // Written and read only from the Gemini fetch, which the store runs one at a time.
    nonisolated(unsafe) private static var geminiRefreshed: (refresh: String, token: String, expires: Date)?
    nonisolated(unsafe) private static var geminiClientLookedUp = false
    nonisolated(unsafe) private static var geminiClient: (id: String, secret: String)?
    nonisolated(unsafe) private static var geminiProjectID: (refresh: String, project: String)?
}
