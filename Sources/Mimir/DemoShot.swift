#if DEBUG
import AppKit
import SwiftUI

/// Throwaway: renders the popover's cards to a PNG so a UI change can be reviewed without running
/// the menu-bar app. `MIMIR_DEMO_SHOT=/tmp/shot.png .build/debug/Mimir`. Not for release.
enum DemoShot {
    @MainActor
    static func render(to path: String) {
        let now = Date()
        // A tight day: the quotas that make the extra rows earn their place.
        let tight = ProcessInfo.processInfo.environment["MIMIR_DEMO_TIGHT"] != nil
        let claude = ServiceStatus(
            name: "Claude", iconName: "claude",
            sessionResetAt: now.addingTimeInterval(4 * 3600 + 23 * 60),
            weeklyResetAt: now.addingTimeInterval(3 * 86_400 + 19 * 3600),
            sessionRemainingPercent: tight ? 14 : 92, weeklyRemainingPercent: tight ? 8 : 99,
            models: [
                ModelStatus(name: "Fable", remainingPercent: 100,
                            resetAt: now.addingTimeInterval(3 * 86_400 + 19 * 3600), window: .weekly),
                ModelStatus(name: String(localized: "Spending"), remainingPercent: 0, resetAt: nil,
                            valueText: "$18.40 / $40", symbol: "dollarsign.circle"),
            ] + LiveUsageDataSource().claudeResetGrantRows([
                "cedar_ember": ["grants": [
                    ["resets_left": 2, "resets_total": 2, "paused": false, "usable_now": true,
                     "ends_at": iso(now.addingTimeInterval(26 * 86_400 + 8 * 3600))],
                ]],
            ], now: now)
              + LiveUsageDataSource().claudeDollarCreditRows([
                  "iguana_necktie": ["limit_dollars": 250, "used_dollars": 60,
                                     "resets_at": iso(now.addingTimeInterval(40 * 86_400))],
              ]),
            isAvailable: true, statusNote: "demo",
            account: AccountInfo(plan: "Max", email: "you@example.com"))

        // A second login of the same provider: same name, told apart by plan and e-mail.
        let claudeWork = ServiceStatus(
            name: "Claude Work", iconName: "claude",
            sessionResetAt: now.addingTimeInterval(2 * 3600 + 5 * 60),
            weeklyResetAt: nil,
            // A Team seat without a weekly limit: session only.
            sessionRemainingPercent: tight ? 22 : 64,
            models: [], isAvailable: true, statusNote: "demo",
            account: AccountInfo(plan: "Team", email: "name.surname@acme.com.tr"))

        let credits = LiveUsageDataSource().codexResetCreditRows(fromRoot: [
            "credits": [
                ["status": "available", "expires_at": iso(now.addingTimeInterval(3 * 86_400 + 19 * 3600))],
                ["status": "available", "expires_at": iso(now.addingTimeInterval(9 * 86_400 + 4 * 3600))],
            ],
        ], now: now)

        let codex = ServiceStatus(
            name: "Codex", iconName: "codex",
            sessionResetAt: now.addingTimeInterval(13 * 60),
            weeklyResetAt: now.addingTimeInterval(6 * 86_400 + 13 * 3600),
            sessionRemainingPercent: tight ? 31 : 91, weeklyRemainingPercent: tight ? 12 : 91,
            weeklyWindowSeconds: 7 * 86_400,
            models: [ModelStatus(name: String(localized: "Credit balance"), remainingPercent: 0,
                                 resetAt: nil, valueText: "42 kredi", symbol: "dollarsign.circle")] + credits,
            isAvailable: true, statusNote: "demo",
            account: AccountInfo(plan: "Plus", email: "you@example.com"))

        // Go: one 30-day window and no session, so the window takes the face.
        let codexGo = ServiceStatus(
            name: "Codex Go", iconName: "codex",
            sessionResetAt: nil, weeklyResetAt: now.addingTimeInterval(18 * 86_400),
            weeklyRemainingPercent: tight ? 20 : 72, weeklyWindowSeconds: 30 * 86_400,
            models: [], isAvailable: true, statusNote: "demo",
            account: AccountInfo(plan: "Go", email: "you@example.com"))

        // Antigravity carries per-family rows instead of account windows — and it's where the amber
        // and red bands show up in this render.
        let antigravity = ServiceStatus(
            name: "Antigravity", iconName: "antigravity",
            sessionResetAt: nil, weeklyResetAt: nil,
            models: [
                ModelStatus(name: "Gemini", remainingPercent: 28,
                            resetAt: now.addingTimeInterval(2 * 3600 + 40 * 60), window: .session),
                ModelStatus(name: "Gemini", remainingPercent: 44,
                            resetAt: now.addingTimeInterval(4 * 86_400), window: .weekly),
                ModelStatus(name: "Claude", remainingPercent: 6,
                            resetAt: now.addingTimeInterval(51 * 60), window: .session),
                ModelStatus(name: "Claude", remainingPercent: 9,
                            resetAt: now.addingTimeInterval(4 * 86_400), window: .weekly),
                ModelStatus(name: "Gemini 4 Argon", remainingPercent: 0,
                            resetAt: now.addingTimeInterval(4 * 86_400 + 18 * 3600), window: .weekly),
                ModelStatus(name: String(localized: "AI credit"), remainingPercent: 0, resetAt: nil,
                            valueText: "1250", symbol: "dollarsign.circle"),
            ],
            isAvailable: true, statusNote: "demo",
            account: AccountInfo(plan: "Pro", email: "you@example.com"))

        let view = VStack(spacing: 11) {
            ServiceCard(service: claude, now: now)
            ServiceCard(service: claudeWork, now: now)
            ServiceCard(service: codex, now: now)
            ServiceCard(service: codexGo, now: now)
            ServiceCard(service: antigravity, now: now)
        }
        // `MIMIR_DEMO_LIGHT=1` renders the light appearance; the status colours follow NSApp's.
        let light = ProcessInfo.processInfo.environment["MIMIR_DEMO_LIGHT"] != nil
        NSApp.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        let page = view
        .padding(11)
        .frame(width: PopoverMetrics.width)
        .background(Color(hex: light ? 0xECECEE : 0x2C2C30))
        .environment(\.colorScheme, light ? .light : .dark)

        let renderer = ImageRenderer(content: page)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
#endif
