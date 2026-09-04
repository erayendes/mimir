#if DEBUG
import AppKit
import SwiftUI

/// Throwaway: renders the popover's cards to a PNG so a UI change can be reviewed without running
/// the menu-bar app. `MIMIR_DEMO_SHOT=/tmp/shot.png .build/debug/Mimir`. Not for release.
enum DemoShot {
    @MainActor
    static func render(to path: String) {
        let now = Date()
        let claude = ServiceStatus(
            name: "Claude", iconName: "claude",
            sessionResetAt: now.addingTimeInterval(4 * 3600 + 23 * 60),
            weeklyResetAt: now.addingTimeInterval(3 * 86_400 + 19 * 3600),
            sessionRemainingPercent: 92, weeklyRemainingPercent: 99,
            models: [
                ModelStatus(name: "Fable", remainingPercent: 100,
                            resetAt: now.addingTimeInterval(3 * 86_400 + 19 * 3600), window: .weekly),
            ],
            isAvailable: true, statusNote: "demo")

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
            sessionRemainingPercent: 91, weeklyRemainingPercent: 91,
            weeklyWindowSeconds: 2_592_000,
            models: credits,
            isAvailable: true, statusNote: "demo")

        let view = VStack(spacing: 11) {
            ServiceCard(service: claude, now: now)
            ServiceCard(service: codex, now: now)
        }
        .padding(11)
        .frame(width: PopoverMetrics.width)
        .background(Color(hex: 0x2C2C30))
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: view)
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
