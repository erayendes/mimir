import SwiftUI

// Design tokens shared between the app and the widget. The status hexes are the spec's vivid
// values; they read well on both the dark and light widget surfaces (the app keeps its own
// appearance-adaptive `quotaStatusColor`).

public extension Color {
    /// 0xRRGGBB → opaque sRGB colour. The single hex initialiser for both targets.
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// The one status-colour rule from the design spec: green ≥50%, amber 15–50%, red <15% — derived
/// from *remaining* percent (low percent = critical = red). Drives the percentage text and bars.
public func statusColor(_ percent: Int) -> Color {
    switch max(0, min(100, percent)) {
    case 50...100: return Color(hex: 0x3FB984)
    case 15..<50:  return Color(hex: 0xE0A93C)
    default:       return Color(hex: 0xE5564E)
    }
}

/// Compact "kalan süre" string (e.g. `18d`, `4s 23d`, `5g 21s`) for an interval, with the unit
/// suffixes injected so the caller controls localisation. Mirrors the app's `TimeFormatter`
/// breakdown; lives here so the widget (which can't see the Mimir target) can format too.
public func shortDuration(_ interval: TimeInterval, day: String, hour: String, minute: String) -> String {
    let clamped = max(0, Int(interval.rounded(.down)))
    let days = clamped / 86_400
    let hours = (clamped % 86_400) / 3_600
    let minutes = (clamped % 3_600) / 60
    if days > 0 { return hours > 0 ? "\(days)\(day) \(hours)\(hour)" : "\(days)\(day)" }
    if hours > 0 { return minutes > 0 ? "\(hours)\(hour) \(minutes)\(minute)" : "\(hours)\(hour)" }
    return "\(max(minutes, 1))\(minute)"
}
