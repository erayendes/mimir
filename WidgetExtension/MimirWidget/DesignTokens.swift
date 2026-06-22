import SwiftUI
// MimirShared sources (WidgetTheme/WidgetPayload/AppGroup) compile into this target — `statusColor`,
// `dynamicColor`, `Color(hex:)`, `shortDuration`, and `WidgetPayload` are same-module (no import).

// Pixel-exact tokens from the design handoff (design_handoff_widgets/README.md). Colours derive
// from `Color.primary` (the semantic label colour) so they track WidgetKit's light/dark environment
// automatically — black-on-light, white-on-dark. (NSColor dynamic providers do NOT resolve against
// a widget's appearance, which is why text stayed white in light mode.)
enum Tok {
    static var primary:   Color { .primary.opacity(0.90) }   // model name
    static var secondary: Color { .primary.opacity(0.62) }
    static var brand:     Color { .primary.opacity(0.48) }   // "mimir", labels
    static var tertiary:  Color { .primary.opacity(0.42) }   // remaining time
    static var track:     Color { .primary.opacity(0.09) }   // bar track
    static var badgeBg:   Color { .primary.opacity(0.06) }   // 5s pill
}

/// The layered background: dark base with purple/orange glows, or a light tinted base.
struct WidgetBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            if scheme == .dark {
                LinearGradient(colors: [Color(hex: 0x14141D), Color(hex: 0x0E0F16), Color(hex: 0x0A0B11)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Color(hex: 0x7E8BF2).opacity(0.20), .clear],
                               center: UnitPoint(x: 0.9, y: -0.12), startRadius: 0, endRadius: 260)
                RadialGradient(colors: [Color(hex: 0xE6885B).opacity(0.16), .clear],
                               center: UnitPoint(x: -0.1, y: 1.12), startRadius: 0, endRadius: 280)
            } else {
                LinearGradient(colors: [Color(hex: 0xF6F6F9), Color(hex: 0xEDEDF1), Color(hex: 0xE7E7EC)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Color(hex: 0x7E8BF2).opacity(0.12), .clear],
                               center: UnitPoint(x: 0.9, y: -0.12), startRadius: 0, endRadius: 260)
                RadialGradient(colors: [Color(hex: 0xE6885B).opacity(0.10), .clear],
                               center: UnitPoint(x: -0.1, y: 1.12), startRadius: 0, endRadius: 280)
            }
        }
    }
}

/// Status-coloured capsule progress bar. Track + fill, fill width = percent of available width.
struct ProgressBar: View {
    let percent: Int
    var height: CGFloat = 5
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Tok.track)
                Capsule().fill(statusColor(percent))
                    .frame(width: max(height, geo.size.width * CGFloat(clampPct(percent)) / 100))
            }
        }
        .frame(height: height)
    }
}

/// Provider logo as a template image tinted with the primary text colour (the brand SVGs are
/// monochrome paths), so it inverts to dark on a light surface.
struct BrandMark: View {
    let iconName: String
    var size: CGFloat
    var body: some View {
        Image(iconName)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(Tok.primary)
    }
}

func clampPct(_ p: Int) -> Int { max(0, min(100, p)) }

// Localised "kalan süre" + reset clock for a metric, computed against the entry's `now` so the
// countdown stays live between timeline reloads. Unit suffixes resolve against the widget bundle's
// Localizable.strings (en: d/h/m · tr: g/s/d), shared with the app.
enum Reset {
    static func remaining(_ resetAt: Date?, now: Date) -> String? {
        guard let resetAt else { return nil }
        return shortDuration(resetAt.timeIntervalSince(now),
                             day: String(localized: "duration.unit.day"),
                             hour: String(localized: "duration.unit.hour"),
                             minute: String(localized: "duration.unit.minute"))
    }
    static func clock(_ resetAt: Date?) -> String? {
        guard let resetAt else { return nil }
        return clockFormatter.string(from: resetAt)
    }
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}
