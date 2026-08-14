import AppKit
import MimirShared
import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: UsageStore
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
                        notificationBanner
                        contentView(now: context.date)
                        BrandingFooter(checkForUpdates: checkForUpdates)
                    }
                    .padding(.vertical, 4)
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

    /// Show live services and stale snapshots; hide services that have no data at all.
    /// A stale Antigravity snapshot (isStale) survives the filter so the user still sees
    /// the last-known reading when the IDE is closed, instead of the card vanishing.
    @ViewBuilder
    private func contentView(now: Date) -> some View {
        // Shared with the menu-bar dots so a dot can never line up with the wrong card.
        let visible = store.services
            .filter { ($0.isAvailable || $0.isStale) && !$0.dataUnavailable }
            .sortedByDisplayOrder()
        if !visible.isEmpty {
            // Each provider is its own card — the card border carries the hierarchy, so there are
            // no dividers or rails between them (design v2.9).
            VStack(spacing: 11) {
                ForEach(visible) { service in
                    ServiceCard(service: service, now: now)
                }
            }
            .padding(.horizontal, 11)
            .padding(.top, 11)
            .padding(.bottom, 4)
        } else if store.isRefreshing {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .frame(minHeight: PopoverMetrics.placeholderHeight)
        } else {
            emptyState
        }
    }

    /// General alert area (not tied to a model row): surfaces providers whose live source has been
    /// unreachable too long, with the actionable hint. Hidden when there's nothing to report.
    @ViewBuilder
    private var notificationBanner: some View {
        let down = store.services
            .filter(\.dataUnavailable)
            .sortedByDisplayOrder()
        if !down.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(down) { svc in
                    Text(String(format: String(localized: "popover.unavailable"), svc.name))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { AppTarget.open(svc.name) }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            .padding(.horizontal, 13).padding(.top, 11).padding(.bottom, 2)
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
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.55))

            Button { checkForUpdates() } label: {
                Text(Self.version)
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
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

            Button {
                Telemetry.signal("link.tapped", parameters: ["target": "milowda"])
                NSWorkspace.shared.open(URL(string: "https://milowda.com/apps/mimir")!)
            } label: {
                Text("milowda")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
        // Line the footer up with the cards above it: "mimir" starts under the card's brand icon
        // (panel inset 11 + card padding 11), and "milowda" keeps the same margin on the right.
        .padding(.horizontal, 22)
        .padding(.vertical, 11)
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

/// One provider = one card (design v2.9): brand header, its quota block(s), then any
/// value rows (credit balance, reset credits) below a hairline.
struct ServiceCard: View {
    let service: ServiceStatus
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Provider name as a small uppercase eyebrow — the card frame carries the emphasis,
            // so the header stays quiet and the quota block is the loudest thing on the card.
            HStack(spacing: 6) {
                BrandIconView(iconName: service.iconName, size: 11)
                    .foregroundStyle(Color.primary.opacity(0.45))
                    .frame(width: 11, height: 11)
                Text(cardTitle.uppercased())
                    .font(.system(size: 10, weight: .medium))
                    .tracking(0.9)
                    .foregroundStyle(Color.primary.opacity(0.5))
                    .lineLimit(1)
            }
            .padding(.bottom, 9)

            cardBody
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
        // Dim a stale snapshot so it reads as "last known, not live".
        .opacity(service.isStale ? 0.66 : 1)
    }

    /// Everything under the header, inset from the card edge (design: 11px, no rail).
    @ViewBuilder
    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasServiceQuotas {
                // Claude / Codex: one quota block, then the per-model rows under it.
                if let hero = sessionHero {
                    QuotaBlock(label: hero.label, percent: hero.percent, resetAt: hero.resetAt, now: now,
                               gated: hero.gated, windowFallback: hero.fallback)
                }
                if !weeklyEntries.isEmpty {
                    VStack(spacing: 5) {
                        ForEach(Array(weeklyEntries.enumerated()), id: \.offset) { _, entry in
                            modelRow(entry)
                        }
                    }
                    .padding(.top, 9)
                }
            } else {
                // Antigravity: one card, one section per family, separated by a hairline so a
                // family's model row sits under its own block — not the next family's.
                ForEach(Array(antigravityFamilies.enumerated()), id: \.offset) { index, family in
                    VStack(alignment: .leading, spacing: 0) {
                        if index > 0 {
                            cardDivider.padding(.top, 13).padding(.bottom, 13)
                        }
                        if let session = family.session {
                            QuotaBlock(label: family.name, percent: session.percent, resetAt: session.resetAt,
                                       now: now, gated: family.weekly?.percent == 0)
                        }
                        if let weekly = family.weekly {
                            modelRow((label: family.name, percent: weekly.percent, resetAt: weekly.resetAt))
                                .padding(.top, family.session != nil ? 9 : 0)
                        }
                    }
                }
            }

            if !valueRows.isEmpty {
                cardDivider.padding(.top, 11).padding(.bottom, 9)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(valueRows) { row in
                        valueRow(row)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
    }

    private var cardDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 1)
    }

    /// A secondary quota row: status dot + "Name: %X" + its remaining time on the right.
    private func modelRow(_ entry: (label: String, percent: Int, resetAt: Date?)) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(quotaStatusColor(entry.percent))
                .frame(width: 7, height: 7)
            Text("\(entry.label): ").font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.72))
                + Text("%\(clampPct(entry.percent))").font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.primary.opacity(0.9))
            Spacer(minLength: 6)
            Text(relDuration(entry.resetAt, now) ?? "—")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.primary.opacity(0.42))
                .fixedSize()
        }
        .lineLimit(1)
    }

    /// A value row (credit balance, reset credits): icon + label left, value right, optional caption.
    private func valueRow(_ row: ModelStatus) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                HStack(spacing: 5) {
                    if let symbol = row.symbol {
                        Image(systemName: symbol).font(.system(size: 11, weight: .regular))
                    }
                    Text(row.name)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.58))
                Spacer(minLength: 6)
                Text(row.valueText ?? "")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.primary.opacity(0.9))
            }
            if let caption = row.caption {
                Text(caption)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.primary.opacity(0.42))
            }
        }
        .lineLimit(1)
    }

    // MARK: Data shaping

    /// Codex is branded "ChatGPT" on the card — that's the account the quota belongs to.
    private var cardTitle: String {
        service.name == "Codex" ? "ChatGPT" : service.name
    }

    /// Model rows under the quota block. Claude/Codex: the account weekly ("All models") plus any
    /// per-model weekly (e.g. Fable). Antigravity groups its own, per family.
    private var weeklyEntries: [(label: String, percent: Int, resetAt: Date?)] {
        var out: [(label: String, percent: Int, resetAt: Date?)] = []
        // The account weekly is a row only when there IS a 5h block above it; with no session the
        // weekly is promoted into the block (see sessionHero), so don't repeat it here.
        if service.sessionRemainingPercent != nil, let weekly = service.weeklyRemainingPercent {
            out.append((String(localized: "All models"), weekly, service.weeklyResetAt))
        }
        for model in service.models where model.valueText == nil {
            out.append((model.name, model.remainingPercent, model.resetAt))
        }
        return out
    }

    /// The card's prominent block (Claude/Codex). Normally the 5-hour session; when a service has no
    /// 5h window (Codex since OpenAI's July 2026 removal) the weekly reading is promoted here, under
    /// a label that says so, rather than leaving the card without a headline number.
    private var sessionHero: (label: String, percent: Int, resetAt: Date?, fallback: TimeInterval, gated: Bool)? {
        if let session = service.sessionRemainingPercent {
            return (String(localized: "Current session"), session, service.sessionResetAt,
                    5 * 3600, service.weeklyRemainingPercent == 0)
        }
        if let weekly = service.weeklyRemainingPercent {
            return (String(localized: "Usage limits"), weekly, service.weeklyResetAt,
                    service.weeklyWindowSeconds ?? 7 * 24 * 3600, false)
        }
        return nil
    }

    /// Credit / reset-credit rows, in provider order. Empty → the whole section is skipped.
    private var valueRows: [ModelStatus] {
        service.models.filter { $0.valueText != nil }
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

    private var hasServiceQuotas: Bool {
        service.name == "Claude" || service.name == "Codex"
    }
}

// Color(hex:) now lives in MimirShared (shared with the widget); imported via `import MimirShared`.

func clampPct(_ percent: Int) -> Int { max(0, min(100, percent)) }

/// A model whose weekly (7g) quota is spent is unusable until it resets — its session number, bar,
/// and 7g dot drop to this muted grey so a fresh 5h window can't read as "available" when the week
/// is gone (the "green even though I can't use it" case).
let lockedQuotaColor = Color.primary.opacity(0.4)

func relDuration(_ resetAt: Date?, _ now: Date) -> String? {
    guard let resetAt, resetAt.timeIntervalSince(now) > 0 else { return nil }
    return TimeFormatter.duration(from: resetAt.timeIntervalSince(now))
}

/// A quota block: window label + status-coloured percent on one line, a thin status-coloured
/// bar, then remaining time (left) and reset clock (right).
struct QuotaBlock: View {
    let label: String
    let percent: Int
    let resetAt: Date?
    let now: Date
    /// True when this model's weekly quota is spent — grey the figure + bar so a full 5h window
    /// can't masquerade as usable while the week is locked.
    var gated: Bool = false
    /// Reset-countdown fallback length shown when there's no `resetAt`, matching this window (5h vs 7d).
    var windowFallback: TimeInterval = 5 * 3600

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("%\(clampPct(percent))")
                    .font(.system(size: 13.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(gated ? lockedQuotaColor : quotaStatusColor(percent))
            }

            QuotaBar(percent: percent, colorOverride: gated ? lockedQuotaColor : nil)
                .padding(.top, 8)

            HStack(spacing: 8) {
                Label {
                    // No reset scheduled (window full / not yet counting down) → show the
                    // full window length rather than a bare dash.
                    Text(relDuration(resetAt, now) ?? TimeFormatter.duration(from: windowFallback))
                } icon: {
                    Image(systemName: "hourglass")
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
            .foregroundStyle(Color.primary.opacity(0.5))
            .labelStyle(.titleAndIcon)
            .padding(.top, 7)
        }
    }

    private var resetClock: String? {
        guard let resetAt, resetAt.timeIntervalSince(now) > 0 else { return nil }
        return Self.clockFormatter.string(from: resetAt)
    }
}

struct QuotaBar: View {
    let percent: Int
    var colorOverride: Color? = nil   // grey for a weekly-locked model; else the status colour

    var body: some View {
        let color = colorOverride ?? quotaStatusColor(percent)
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

/// Status colour for a remaining-quota level, per the design spec's thresholds: green ≥50%,
/// amber 15–49%, red ≤14% — one set of bands for every window. Returns a dynamic colour that
/// darkens in light mode so it stays legible on the light panel.
func quotaStatusColor(_ percent: Int) -> Color {
    let darkHex: UInt32, lightHex: UInt32
    switch clampPct(percent) {
    case 50...100: darkHex = 0x3FB984; lightHex = 0x1FA45E  // green
    case 15...49:  darkHex = 0xE0A93C; lightHex = 0xB07D0A  // amber
    default:       darkHex = 0xE5564E; lightHex = 0xC9403A  // red
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
