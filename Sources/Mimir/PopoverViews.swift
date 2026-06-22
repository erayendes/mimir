import AppKit
import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.colorScheme) private var colorScheme
    let onDismiss: () -> Void
    /// Reports the measured content height so AppKit can size the popover.
    /// Plain callback on purpose — see the note at the construction site.
    let onContentHeightChange: (CGFloat) -> Void
    let checkForUpdates: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ZStack {
                PopoverBackdrop()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        contentView(now: context.date)

                        sectionDivider
                        BrandingFooter(checkForUpdates: checkForUpdates)
                    }
                    .padding(.vertical, 8)
                    .background(innerPanel)
                    .padding(10)
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { onContentHeightChange(proxy.size.height) }
                                .onChange(of: proxy.size.height) { _, height in
                                    onContentHeightChange(height)
                                }
                        }
                    }
                }
            }
        }
    }

    /// The single panel. Kept very translucent so the frosted desktop reads through it
    /// like glass — just a faint tint for legibility plus a hairline glass edge.
    @ViewBuilder
    private var innerPanel: some View {
        let dark = colorScheme == .dark
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill((dark ? Color(hex: 0x14141C) : Color(hex: 0xFFFFFF)).opacity(dark ? 0.10 : 0.16))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(dark ? 0.16 : 0.12), lineWidth: 1)
            }
    }

    /// A hairline divider between the inner panel's sections, inset from the edges.
    private var sectionDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 1)
            .padding(.horizontal, 13)
    }

    /// Show live services and stale snapshots; hide services that have no data at all.
    /// A stale Antigravity snapshot (isStale) survives the filter so the user still sees
    /// the last-known reading when the IDE is closed, instead of the card vanishing.
    @ViewBuilder
    private func contentView(now: Date) -> some View {
        // Shared with the menu-bar dots so a dot can never line up with the wrong card.
        let order = serviceDisplayOrder
        let visible = store.services
            .filter { $0.isAvailable || $0.isStale }
            .sorted { (order.firstIndex(of: $0.name) ?? 99) < (order.firstIndex(of: $1.name) ?? 99) }
        if !visible.isEmpty {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, service in
                if index > 0 { sectionDivider }
                ServiceCard(service: service, now: now)
            }
        } else if store.isRefreshing {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .frame(minHeight: PopoverMetrics.placeholderHeight)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "gauge.with.dots.needle.0percent")
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(.secondary)
            Text("No active services detected.\nMake sure Claude Code, Codex, or Antigravity is running.")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: PopoverMetrics.placeholderHeight)
        .padding(.horizontal, 8)
    }
}

/// Footer: "mimir" + version badge (tap to check for updates) on the left, the
/// milowda link on the right. Version comes from the bundle, not hardcoded.
struct BrandingFooter: View {
    let checkForUpdates: () -> Void

    private static let version: String =
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { "v\($0)" } ?? "dev"

    var body: some View {
        HStack(spacing: 7) {
            Text("mimir")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.55))

            Button { checkForUpdates() } label: {
                Text(Self.version)
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.primary.opacity(0.4))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(String(localized: "Check for updates"))

            Spacer(minLength: 6)

            Link("milowda", destination: URL(string: "https://milowda.com/apps/mimir")!)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.4))
                .pointingHandCursor()
        }
        .padding(13)
    }
}

extension View {
    /// Show the link/pointing-hand cursor while hovering — the default cursor behaviour
    /// for clickable text, which SwiftUI doesn't apply on its own here.
    func pointingHandCursor() -> some View {
        onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

enum PopoverMetrics {
    static let edgeInset: CGFloat = 14
    /// Resting top/bottom padding.
    static let contentInset: CGFloat = 18
    static let width: CGFloat = 288
    /// Safety ceiling only; the popover otherwise grows to fit all content (no inner scroll).
    static let maxHeight: CGFloat = 1400
    static let placeholderHeight: CGFloat = 200
}

/// Subtle press feedback — the row scales down slightly while held, so it feels
/// responsive to the click rather than static. (Emil: buttons must feel pressed.)
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

/// Behind-window blur: blurs the actual desktop behind the popover (not just the
/// window's own content like SwiftUI's `.ultraThinMaterial`). This is what makes
/// the panel read as transparent glass over the wallpaper.
struct DesktopBlur: NSViewRepresentable {
    let dark: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        apply(view)
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) { apply(nsView) }

    private func apply(_ view: NSVisualEffectView) {
        // hudWindow is a dark vibrant blur; popover is the light counterpart.
        view.material = dark ? .hudWindow : .popover
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }
}

/// Outer ambient layer behind the inner panel: behind-window desktop blur, a dark
/// base, and faint brand-tinted glows in the corners (the v4 showcase frame). The
/// inner panel sits inset on top of this, giving the panel-in-panel depth.
struct PopoverBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    var body: some View {
        ZStack {
            DesktopBlur(dark: dark)

            // Tint kept minimal so the behind-window blur (the desktop) carries the
            // look — frosted glass rather than a solid panel.
            LinearGradient(
                colors: dark
                    ? [Color(hex: 0x12121A), Color(hex: 0x0C0D14), Color(hex: 0x08090E)]
                    : [Color(hex: 0xF4F4F7), Color(hex: 0xECECEF), Color(hex: 0xE6E6EA)],
                startPoint: .top, endPoint: .bottom
            )
            .opacity(dark ? 0.05 : 0.04)

            RadialGradient(colors: [Color(hex: 0x7E8BF2).opacity(dark ? 0.10 : 0.07), .clear],
                           center: .topTrailing, startRadius: 8, endRadius: 280)
            RadialGradient(colors: [Color(hex: 0xE6885B).opacity(dark ? 0.08 : 0.06), .clear],
                           center: .bottomLeading, startRadius: 8, endRadius: 280)
        }
        .ignoresSafeArea()
    }
}

struct ServiceCard: View {
    let service: ServiceStatus
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: white brand glyph + service name.
            HStack(spacing: 8) {
                BrandIconView(iconName: service.iconName, size: 15)
                    .foregroundStyle(Color.primary.opacity(0.92))
                    .frame(width: 15, height: 15)
                Text(service.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.92))
                    .lineLimit(1)
            }

            if hasServiceQuotas {
                // Claude / Codex: a single session block, then the weekly rows.
                ForEach(Array(sessionHeroes.enumerated()), id: \.offset) { index, hero in
                    SessionRow(label: hero.label, percent: hero.percent, resetAt: hero.resetAt, now: now)
                        .padding(.top, index == 0 ? 11 : 13)
                }
                if !weeklyEntries.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(Array(weeklyEntries.enumerated()), id: \.offset) { _, entry in
                            weeklyRow(entry)
                        }
                    }
                    .padding(.top, 11)
                }
            } else {
                // Antigravity: group each family's session and weekly together, so a
                // family's weekly row sits under its own session — not the next family's.
                ForEach(Array(antigravityFamilies.enumerated()), id: \.offset) { index, family in
                    VStack(alignment: .leading, spacing: 0) {
                        if let session = family.session {
                            SessionRow(label: family.name, percent: session.percent, resetAt: session.resetAt, now: now)
                        }
                        if let weekly = family.weekly {
                            weeklyRow((label: family.name, percent: weekly.percent, resetAt: weekly.resetAt))
                                .padding(.top, family.session != nil ? 8 : 0)
                        }
                    }
                    .padding(.top, index == 0 ? 11 : 13)
                }
            }

            if let credit = creditEntry {
                HStack {
                    Text(credit.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.4))
                    Spacer()
                    Text(credit.value)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.primary.opacity(0.7))
                }
                .padding(.top, 11)
            }
        }
        .padding(13)
        // Dim a stale snapshot so it reads as "last known, not live".
        .opacity(service.isStale ? 0.66 : 1)
    }

    private func weeklyRow(_ entry: (label: String, percent: Int, resetAt: Date?)) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(quotaStatusColor(entry.percent))
                .frame(width: 7, height: 7)
            Text(entry.label)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.primary.opacity(0.62))
                .lineLimit(1)
            QuotaBadge(text: String(localized: "7g"))
            Spacer(minLength: 6)
            Text("%\(clampPct(entry.percent))")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.primary.opacity(0.62))
            Text(relDuration(entry.resetAt, now) ?? "—")
                .font(.system(size: 11, weight: .regular).monospacedDigit())
                .foregroundStyle(Color.primary.opacity(0.38))
                .frame(width: 52, alignment: .trailing)
        }
    }

    // MARK: Data shaping

    /// Weekly rows. Claude/Codex: the all-models weekly (labelled with the service name)
    /// plus any per-model weekly (e.g. Sonnet). Antigravity: its grouped weekly buckets.
    private var weeklyEntries: [(label: String, percent: Int, resetAt: Date?)] {
        if hasServiceQuotas {
            var out: [(label: String, percent: Int, resetAt: Date?)] = []
            if let weekly = service.weeklyRemainingPercent {
                out.append((service.name, weekly, service.weeklyResetAt))
            }
            for model in service.models where model.valueText == nil {
                out.append((model.name, model.remainingPercent, model.resetAt))
            }
            return out
        }
        return service.models
            .filter { $0.window == .weekly && $0.valueText == nil }
            .map { (label: $0.name, percent: $0.remainingPercent, resetAt: $0.resetAt) }
    }

    /// The prominent 5-hour session block (Claude/Codex only — one each).
    private var sessionHeroes: [(label: String, percent: Int, resetAt: Date?)] {
        guard let session = service.sessionRemainingPercent else { return [] }
        return [(service.name, session, service.sessionResetAt)]
    }

    /// Antigravity grouped by family, preserving first-seen order, each family carrying
    /// its own session (5h) and weekly (7g) so they render together.
    private var antigravityFamilies: [(name: String, session: (percent: Int, resetAt: Date?)?, weekly: (percent: Int, resetAt: Date?)?)] {
        var order: [String] = []
        var sessions: [String: (Int, Date?)] = [:]
        var weeklies: [String: (Int, Date?)] = [:]
        for model in service.models where model.valueText == nil {
            if !order.contains(model.name) { order.append(model.name) }
            switch model.window {
            case .session: sessions[model.name] = (model.remainingPercent, model.resetAt)
            case .weekly:  weeklies[model.name] = (model.remainingPercent, model.resetAt)
            case .none:    sessions[model.name] = (model.remainingPercent, model.resetAt)
            }
        }
        return order.map { name in
            (name: name,
             session: sessions[name].map { (percent: $0.0, resetAt: $0.1) },
             weekly: weeklies[name].map { (percent: $0.0, resetAt: $0.1) })
        }
    }

    private var creditEntry: (label: String, value: String)? {
        guard let model = service.models.first(where: { $0.valueText != nil }),
              let value = model.valueText else { return nil }
        return (String(localized: "Usage credit"), value)
    }

    private var hasServiceQuotas: Bool {
        service.name == "Claude" || service.name == "Codex"
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

func clampPct(_ percent: Int) -> Int { max(0, min(100, percent)) }

func relDuration(_ resetAt: Date?, _ now: Date) -> String? {
    guard let resetAt, resetAt.timeIntervalSince(now) > 0 else { return nil }
    return TimeFormatter.duration(from: resetAt.timeIntervalSince(now))
}

/// A small grey pill badge (e.g. "5s" for the 5-hour session, "7g" for the weekly window).
struct QuotaBadge: View {
    let text: String
    var prominent = false

    var body: some View {
        Text(text)
            .font(.system(size: prominent ? 10 : 9.5, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(0.34))
            .padding(.horizontal, prominent ? 5 : 4.5)
            .padding(.vertical, prominent ? 1.5 : 1)
            .background(
                RoundedRectangle(cornerRadius: prominent ? 5 : 4, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
    }
}

/// The prominent session block: model name + "5s" badge + big status-coloured percent,
/// a thin status-coloured bar, then remaining time (left) and reset clock (right).
struct SessionRow: View {
    let label: String
    let percent: Int
    let resetAt: Date?
    let now: Date

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.88))
                    .lineLimit(1)
                QuotaBadge(text: String(localized: "5s"), prominent: true)
                Spacer(minLength: 6)
                Text("%\(clampPct(percent))")
                    .font(.system(size: 18, weight: .semibold).monospacedDigit())
                    .foregroundStyle(quotaStatusColor(percent))
            }

            QuotaBar(percent: percent)
                .padding(.top, 9)

            HStack(spacing: 8) {
                Label {
                    // No reset scheduled (window full / not yet counting down) → show the
                    // full 5-hour window rather than a bare dash.
                    Text(relDuration(resetAt, now) ?? TimeFormatter.duration(from: 5 * 3600))
                } icon: {
                    Image(systemName: "gauge.medium")
                }
                Spacer(minLength: 4)
                if let resetClock {
                    Label {
                        Text(resetClock)
                    } icon: {
                        Image(systemName: "clock")
                    }
                }
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(Color.primary.opacity(0.42))
            .labelStyle(.titleAndIcon)
            .padding(.top, 6)
        }
    }

    private var resetClock: String? {
        guard let resetAt, resetAt.timeIntervalSince(now) > 0 else { return nil }
        return Self.clockFormatter.string(from: resetAt)
    }
}

struct QuotaBar: View {
    let percent: Int

    var body: some View {
        let color = quotaStatusColor(percent)
        GeometryReader { proxy in
            let ratio = CGFloat(clampPct(percent)) / 100
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(color)
                    .frame(width: max(5, proxy.size.width * ratio))
            }
        }
        .frame(height: 5)
    }
}

/// Single status colour for a quota level (applies to every model, its percentage, and
/// its weekly dot): green ≥50%, amber 15–50%, red <15%. Returns a dynamic colour that
/// darkens in light mode so it stays legible on the light panel.
func quotaStatusColor(_ percent: Int) -> Color {
    let darkHex: UInt32, lightHex: UInt32
    switch clampPct(percent) {
    case 50...100: darkHex = 0x3FB984; lightHex = 0x1F9E63  // green
    case 15..<50:  darkHex = 0xE0A93C; lightHex = 0xB07E1C  // amber
    default:       darkHex = 0xE5564E; lightHex = 0xCF3A33  // red
    }
    return Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(hex: isDark ? darkHex : lightHex)
    })
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}


struct BrandIconView: View {
    let iconName: String
    let size: CGFloat

    var body: some View {
        if let image = BrandIconLoader.image(named: iconName) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "circle")
                .symbolRenderingMode(.monochrome)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(.primary.opacity(0.5))
                .accessibilityHidden(true)
        }
    }
}
