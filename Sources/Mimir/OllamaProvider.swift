import Foundation
import Security

extension LiveUsageDataSource {
    /// Ollama Cloud usage is read by fetching ollama.com/settings with Chrome's session cookies.
    /// The cookie encryption key comes from the macOS Keychain ("Chrome Safe Storage");
    /// cookies are decrypted from Chrome's SQLite cookie store (AES-128-CBC, v10 format with
    /// embedded IV). The fetched HTML is parsed for session/weekly usage percentages and
    /// `data-time` reset timestamps — the same approach as CodexBar's OllamaUsageParser.
    func fetchOllama() async -> ServiceStatus {
        guard let me = await fetchOllamaMe() else {
            if let snap = loadSnapshot(for: "Ollama", iconName: "ollama") {
                return snap
            }
            return unavailableService(
                name: "Ollama",
                iconName: "ollama",
                models: [],
                note: String(localized: "open Ollama to refresh")
            )
        }

        // Try fetching settings page with Chrome cookies.
        if let parsed = fetchOllamaSettingsHTML() {
            let status = buildOllamaStatus(me: me, parsed: parsed)
            saveSnapshot(status)
            return status
        }

        // No Chrome cookies or fetch failed — show snapshot or unavailable.
        if let snap = loadSnapshot(for: "Ollama", iconName: "ollama") {
            return snap
        }
        return unavailableService(
            name: "Ollama",
            iconName: "ollama",
            models: [],
            note: String(localized: "sign in to ollama.com in Chrome")
        )
    }

    // MARK: - Status builders

    private func buildOllamaStatus(me: OllamaAccount, parsed: OllamaSettingsData) -> ServiceStatus {
        let sessionRemaining = max(0, min(100, Int((100 - parsed.sessionUsedPercent).rounded())))
        let weeklyRemaining = max(0, min(100, Int((100 - parsed.weeklyUsedPercent).rounded())))

        return ServiceStatus(
            name: "Ollama",
            iconName: "ollama",
            sessionResetAt: parsed.sessionResetAt,
            weeklyResetAt: parsed.weeklyResetAt,
            sessionRemainingPercent: sessionRemaining,
            weeklyRemainingPercent: weeklyRemaining,
            models: [],
            isAvailable: true,
            statusNote: String(localized: "ollama cloud")
        )
    }


    // MARK: - Chrome cookie extraction + HTML fetch

    /// Python script that extracts Chrome cookies for ollama.com, fetches the settings page,
    /// and parses usage data. Returns JSON with session/weekly percentages and reset timestamps.
    /// Based on CodexBar's OllamaUsageFetcher approach: Keychain password → PBKDF2 → AES-CBC
    /// decrypt → HTTP fetch with cookies → regex parse.
    private static let ollamaFetchScript = #"""
import sqlite3, os, hashlib, subprocess, json, re, sys, shutil, tempfile
from urllib.request import Request, build_opener, HTTPRedirectHandler

keychain_pass = subprocess.check_output(
    ['security', 'find-generic-password', '-w', '-s', 'Chrome Safe Storage', '-ga', 'Chrome'],
    stderr=subprocess.DEVNULL).strip()
derived_key = hashlib.pbkdf2_hmac('sha1', keychain_pass, b'saltysalt', 1003, dklen=16)

src_db = os.path.expanduser("~/Library/Application Support/Google/Chrome/Default/Cookies")
if not os.path.exists(src_db):
    print(json.dumps({"error": "no chrome"})); sys.exit(0)
temp_db = "/tmp/mimir_ollama_cookies.db"
try: shutil.copy2(src_db, temp_db)
except: temp_db = src_db

cookies = {}
try:
    conn = sqlite3.connect(temp_db)
    for name, enc_val in conn.execute("SELECT name, encrypted_value FROM cookies WHERE host_key LIKE '%ollama%'"):
        if not enc_val or len(enc_val) < 19: continue
        if enc_val[:3] not in (b'v10', b'v11'): continue
        ed = enc_val[3:]
        if len(ed) <= 16: continue
        iv = ed[:16]
        ct = ed[16:]
        # Use openssl for AES-128-CBC decryption (no pycryptodome needed)
        key_hex = derived_key.hex()
        iv_hex = iv.hex()
        with tempfile.NamedTemporaryFile(suffix='.bin', delete=False) as f:
            f.write(ct)
            ct_file = f.name
        try:
            result = subprocess.run(
                ['openssl', 'enc', '-aes-128-cbc', '-d', '-K', key_hex, '-iv', iv_hex, '-in', ct_file, '-nopad'],
                capture_output=True)
            if result.returncode == 0 and result.stdout:
                dec = result.stdout
                pl = dec[-1]
                if 1 <= pl <= 16: dec = dec[:-pl]
                cookies[name] = dec[16:].decode('utf-8', errors='replace')
        finally:
            os.unlink(ct_file)
    conn.close()
finally:
    if temp_db != src_db:
        try: os.remove(temp_db)
        except: pass

if not cookies:
    print(json.dumps({"error": "no cookies"})); sys.exit(0)

hdr = '; '.join(f'{k}={v}' for k, v in cookies.items())
req = Request('https://ollama.com/settings')
req.add_header('Cookie', hdr)
req.add_header('User-Agent', 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36')
try:
    html = build_opener(HTTPRedirectHandler()).open(req, timeout=15).read().decode('utf-8', errors='replace')
except Exception as e:
    print(json.dumps({"error": f"fetch: {e}"})); sys.exit(0)

def pct(t):
    m = re.search(r'([\d.]+)\s*%\s*used', t, re.I)
    return float(m.group(1)) if m else (float(re.search(r'width:\s*([\d.]+)%', t, re.I).group(1)) if re.search(r'width:\s*([\d.]+)%', t, re.I) else None)

def blk(label, h):
    i = h.find(label)
    if i < 0: return None
    t = h[i+len(label):]
    others = [l for l in ["Session usage","Weekly usage","Extra usage","Billing","Profile","Keys"] if l != label]
    bounds = [t.find(l) for l in others if t.find(l) >= 0]
    return t[:min(bounds) if bounds else min(len(t),4000)]

sb = blk("Session usage", html)
wb = blk("Weekly usage", html)
su = pct(sb) if sb else None
wu = pct(wb) if wb else None
if su is None and wu is None:
    print(json.dumps({"error": "no usage"})); sys.exit(0)

dts = re.findall(r'data-time="([^"]+)"', html)
print(json.dumps({
    "sessionUsedPercent": su or 0,
    "weeklyUsedPercent": wu or 0,
    "sessionResetAt": dts[0] if len(dts) > 0 else None,
    "weeklyResetAt": dts[1] if len(dts) > 1 else None
}))
"""#

    /// Fetch ollama.com/settings HTML using Chrome's session cookies via a Python script.
    /// Returns parsed usage data, or nil if Chrome isn't installed, cookies can't be decrypted,
    /// or the fetch fails.
    private func fetchOllamaSettingsHTML() -> OllamaSettingsData? {
        let result = runCommand("/usr/bin/python3", ["-c", Self.ollamaFetchScript])
        guard !result.isEmpty else { return nil }

        guard let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["error"] == nil else {
            return nil
        }

        let sessionUsed = (json["sessionUsedPercent"] as? Double) ?? 0
        let weeklyUsed = (json["weeklyUsedPercent"] as? Double) ?? 0
        let sessionReset = (json["sessionResetAt"] as? String).flatMap(parseISO8601)
        let weeklyReset = (json["weeklyResetAt"] as? String).flatMap(parseISO8601)

        return OllamaSettingsData(
            sessionUsedPercent: sessionUsed,
            weeklyUsedPercent: weeklyUsed,
            sessionResetAt: sessionReset,
            weeklyResetAt: weeklyReset
        )
    }

    // MARK: - HTML parsing (same patterns as CodexBar's OllamaUsageParser)

    struct OllamaSettingsData {
        let sessionUsedPercent: Double
        let weeklyUsedPercent: Double
        let sessionResetAt: Date?
        let weeklyResetAt: Date?
    }

    private func parseOllamaSettingsHTML(_ html: String) -> OllamaSettingsData? {
        let sessionBlock = usageBlockHTML(after: "Session usage", in: html)
        let weeklyBlock = usageBlockHTML(after: "Weekly usage", in: html)

        let sessionUsed = sessionBlock.flatMap { parsePercentUsed(in: $0) }
        let weeklyUsed = weeklyBlock.flatMap { parsePercentUsed(in: $0) }

        guard sessionUsed != nil || weeklyUsed != nil else { return nil }

        // data-time attributes give exact ISO8601 reset timestamps.
        let allDataTimes = regexCaptures(in: html, pattern: #"data-time="([^"]+)""#)
        let sessionReset = allDataTimes.first.flatMap(parseISO8601)
        let weeklyReset = allDataTimes.dropFirst().first.flatMap(parseISO8601)

        return OllamaSettingsData(
            sessionUsedPercent: sessionUsed ?? 0,
            weeklyUsedPercent: weeklyUsed ?? 0,
            sessionResetAt: sessionReset,
            weeklyResetAt: weeklyReset
        )
    }

    private func usageBlockHTML(after label: String, in html: String) -> String? {
        guard let labelRange = html.range(of: label) else { return nil }
        let tail = String(html[labelRange.upperBound...])
        let otherLabels = ["Session usage", "Weekly usage", "Extra usage", "Billing", "Profile", "Keys"]
            .filter { $0 != label }
        let boundary = otherLabels
            .compactMap { tail.range(of: $0)?.lowerBound }
            .min()
        let bounded = boundary.map { String(tail[..<$0]) } ?? String(tail.prefix(4000))
        return String(bounded.prefix(4000))
    }

    private func parsePercentUsed(in text: String) -> Double? {
        if let raw = firstRegexCapture(in: text, pattern: #"([\d.]+)\s*%\s*used"#) {
            return Double(raw)
        }
        if let raw = firstRegexCapture(in: text, pattern: #"width:\s*([\d.]+)%"#) {
            return Double(raw)
        }
        return nil
    }

    private func firstRegexCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = regex.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let captureRange = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[captureRange])
    }

    private func regexCaptures(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.matches(in: text, range: range).compactMap { m in
            guard m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }

    // MARK: - Local Ollama API (127.0.0.1:11434)

    private func fetchOllamaMe() async -> OllamaAccount? {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/me")!, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse).map({ 200 ... 299 ~= $0.statusCode }) == true else {
                return nil
            }
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let plan = root?["plan"] as? String else { return nil }
            return OllamaAccount(plan: plan)
        } catch {
            return nil
        }
    }


}

// MARK: - Models

private struct OllamaAccount {
    let plan: String
}
