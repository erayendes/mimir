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
    /// Everything the settings side needs. Passed in rather than reached for: the view stays a
    /// view, and AppKit keeps owning the login item, the hook and the quit.
    let settings: PopoverSettings

    /// Which face is up. The settings live on the back of the same card — flipping to them keeps
    /// the popover one surface instead of dropping a second window on top of it.
    @State private var showingSettings = false
    /// Each face's natural height. The panel takes the height of the face that's up, so the
    /// settings are never clipped under a short quota face nor padded out under a tall one.
    @State private var quotaHeight: CGFloat = 0
    @State private var settingsHeight: CGFloat = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ZStack {
                PopoverBackdrop()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)

                // Both faces stay mounted so each keeps its state; only the one up is shown. Each is
                // its own scroll view, so neither can push the other out of the panel — a fixed-height
                // settings list in a ZStack with the quotas once overflowed a short panel and was
                // centred into it, clipping the header off the top.
                ZStack(alignment: .top) {
                    quotaFace(now: context.date)
                        .opacity(showingSettings ? 0 : 1)
                        .allowsHitTesting(!showingSettings)
                    ScrollView(showsIndicators: false) {
                        SettingsFace(settings: settings, onBack: { flip() })
                            .measuringHeight { settingsHeight = $0; reportHeight() }
                    }
                    .opacity(showingSettings ? 1 : 0)
                    .allowsHitTesting(showingSettings)
                }
            }
        }
    }

    /// Straight swap, no animation: the settings are a place you go, not a trick the card does.
    private func flip() { showingSettings.toggle(); reportHeight() }

    private func reportHeight() {
        onContentHeightChange(showingSettings ? settingsHeight : quotaHeight)
    }

    @ViewBuilder
    private func quotaFace(now: Date) -> some View {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        BrandingHeader(onGear: { flip() }, refreshing: store.isRefreshing)
                        notificationBanner
                        contentView(now: now)
                        MilowdaMark(checkForUpdates: settings.checkForUpdates)
                    }
                    .padding(.vertical, 4)
                    .measuringHeight { quotaHeight = $0; reportHeight() }
                }
    }

    /// Local builds only: `open --env MIMIR_DEMO_ONLY=Codex /Applications/Mimir.app` shows just
    /// that card, to try the one-provider panel on a machine that tracks several.
    private static func demoOnly(_ service: ServiceStatus) -> Bool {
        guard Telemetry.isDevBuild,
              let only = ProcessInfo.processInfo.environment["MIMIR_DEMO_ONLY"] else { return true }
        return service.name == only
    }

    /// Show live services and stale snapshots; hide services that have no data at all.
    /// A stale Antigravity snapshot (isStale) survives the filter so the user still sees
    /// the last-known reading when the IDE is closed, instead of the card vanishing.
    @ViewBuilder
    private func contentView(now: Date) -> some View {
        // Shared with the menu-bar dots so a dot can never line up with the wrong card.
        let visible = store.services
            .filter { ($0.isAvailable || $0.isStale) && !$0.dataUnavailable && Self.demoOnly($0) }
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
            .filter { $0.dataUnavailable && !store.dismissedUnavailable.contains($0.name) }
            .sortedByDisplayOrder()
        if !down.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(down) { svc in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(String(format: String(localized: "popover.unavailable"), svc.name))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { AppTarget.open(svc.name) }
                            .pointingHandCursor()
                        // Dismissing is per-service and lasts only until that service reports data
                        // again (see UsageStore.forgetRecoveredDismissals), so hiding this notice
                        // can't permanently mute a provider that is genuinely broken.
                        Button { store.dismissUnavailable(svc.name) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.primary.opacity(0.45))
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .help(String(localized: "popover.unavailable.dismiss"))
                        .accessibilityLabel(String(localized: "popover.unavailable.dismiss"))
                    }
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

/// What the settings face can do. Read the flags through closures rather than copying them in:
/// the login item, the hook and the telemetry flag all live outside SwiftUI, and a copy taken at
/// construction would show yesterday's answer.
struct PopoverSettings {
    var version: String
    var launchAtLogin: () -> Bool
    var toggleLaunchAtLogin: () -> Void
    var notifications: () -> Bool
    var toggleNotifications: () -> Void
    var claudeHook: () -> Bool
    var toggleClaudeHook: () -> Void
    var telemetry: () -> Bool
    var toggleTelemetry: () -> Void
    var betaChannel: () -> Bool
    var toggleBetaChannel: () -> Void
    var checkForUpdates: () -> Void
    var openIssues: () -> Void
    var openSupport: () -> Void
    var quit: () -> Void
}

/// The back of the card: every setting in one list, the way a menu-bar app's settings should read
/// — a row is an icon, what it does, and a line saying what that means. One card, not three: the
/// groups were separating things nobody needed separated.
struct SettingsFace: View {
    let settings: PopoverSettings
    let onBack: () -> Void

    /// Every flag here lives outside SwiftUI — a login item, a file on disk, a defaults key — so
    /// none of them can be observed. They're read into state when the face appears and after each
    /// toggle. An earlier attempt leaned on a counter the body merely mentioned (`let _ = tick`);
    /// the compiler is free to drop a read into `_`, so nothing depended on it and every row kept
    /// showing whatever it showed first — a checkmark beside a setting that was actually off.
    @State private var flags = Flags()
    @State private var hovered: String?

    private struct Flags {
        var launchAtLogin = false
        var notifications = true
        var claudeHook = false
        var telemetry = false
        var betaChannel = false
    }

    private func reload() {
        flags = Flags(launchAtLogin: settings.launchAtLogin(),
                      notifications: settings.notifications(),
                      claudeHook: settings.claudeHook(),
                      telemetry: settings.telemetry(),
                      betaChannel: settings.betaChannel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandingHeader(onGear: onBack)

            VStack(spacing: 0) {
                row("power", String(localized: "Open at login"),
                    String(localized: "Mimir opens when you sign in."),
                    checked: flags.launchAtLogin, action: settings.toggleLaunchAtLogin)
                row("bell", String(localized: "Notifications"),
                    String(localized: "When a quota is about to run out."),
                    checked: flags.notifications, action: settings.toggleNotifications)
                row("lock.open", String(localized: "Prompt-free Claude tracking"),
                    String(localized: "Reads Claude Code without a keychain prompt."),
                    checked: flags.claudeHook, action: settings.toggleClaudeHook)
                row("chart.bar", String(localized: "Send anonymous statistics"),
                    String(localized: "Usage counts only, never your data."),
                    checked: flags.telemetry, action: settings.toggleTelemetry)
                row("arrow.down.circle", String(localized: "Version"),
                    settings.version, action: settings.checkForUpdates)
                row("testtube.2", String(localized: "Join the beta"), nil,
                    checked: flags.betaChannel, action: settings.toggleBetaChannel)
                row("ladybug", String(localized: "Report an issue"), nil, action: settings.openIssues)
                row("heart", String(localized: "Support Mimir"), nil, action: settings.openSupport)
                row("xmark.circle", String(localized: "Quit Mimir"), nil,
                    shortcut: "⌘Q", action: settings.quit)
            }
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            )
            // Same insets as the quota cards (contentView), so the card edges line up across faces.
            .padding(.horizontal, 11)
            .padding(.top, 11)
            .padding(.bottom, 4)

            MilowdaMark(checkForUpdates: settings.checkForUpdates)
        }
        .padding(.vertical, 4)
        .onAppear(perform: reload)
    }

    /// One setting. `checked` present makes it a switch (a plain tick, not a control — the row is
    /// the control); absent makes it an action. `shortcut` shows the key that does the same thing
    /// without opening this screen.
    private func row(_ symbol: String, _ title: String, _ subtitle: String?,
                     checked: Bool? = nil, shortcut: String? = nil,
                     action: @escaping () -> Void) -> some View {
        Button {
            action()
            reload()
        } label: {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(Color.primary.opacity(0.6))
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.primary.opacity(0.92))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(Color.primary.opacity(0.45))
                    }
                }
                Spacer(minLength: 8)

                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Color.primary.opacity(0.35))
                }
                if checked == true {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.75))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered == title ? Color.primary.opacity(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovered = $0 ? title : (hovered == title ? nil : hovered) }
    }
}

/// The footer on both faces: which build this is on the left, who made it on the right. The badge
/// moved down here from the header — beside the wordmark it made "mimir" read as a caption to it.
struct MilowdaMark: View {
    let checkForUpdates: () -> Void

    /// The version — on a local build, the release it's heading for.
    private static let badge = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"

    var body: some View {
        HStack {
            Button(action: checkForUpdates) {
                Text(Self.badge)
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

            Spacer(minLength: 0)
            Button {
                Telemetry.signal("link.tapped", parameters: ["target": "milowda"])
                NSWorkspace.shared.open(URL(string: "https://milowda.com")!)
            } label: {
                Text("milowda")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
        .padding(.horizontal, 22)
        .padding(.top, 9)
        .padding(.bottom, 11)
    }
}

/// Header: "mimir" and its build badge on the left, the settings gear on the right. At the top
/// rather than the bottom because the gear is the only control in the popover — a control the eye
/// has to scroll past everything to find is one nobody finds.
struct BrandingHeader: View {
    /// The gear flips between the faces, both ways.
    let onGear: () -> Void
    /// While a refresh is out, a wave runs through the wordmark left to right, letter by letter; it
    /// settles when the numbers are in. Opening the popover is itself the refresh, so this is the
    /// whole of the refresh UI — no button, no timestamp.
    var refreshing = false

    var body: some View {
        HStack(spacing: 7) {
            TimelineView(.animation(paused: !refreshing)) { context in
                HStack(spacing: 0) {
                    ForEach(Array("mimir".enumerated()), id: \.offset) { index, letter in
                        Text(String(letter))
                            .opacity(refreshing ? Self.wave(context.date, index) : 1)
                    }
                }
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color.primary.opacity(0.55))
            .animation(.easeOut(duration: 0.25), value: refreshing)

            Spacer(minLength: 6)

            Button(action: onGear) {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(String(localized: "Settings"))
        }
        // Line the header up with the cards below it: "mimir" starts where a card's brand icon does.
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// Opacity of letter `index` at `date`: one dip per 1.2s cycle, each letter 0.12s behind the
    /// one on its left, so the dip travels m → i → m → i → r.
    static func wave(_ date: Date, _ index: Int) -> Double {
        let phase = date.timeIntervalSinceReferenceDate / 1.2 - Double(index) * 0.1
        return 0.3 + 0.7 * (0.5 + 0.5 * cos(2 * .pi * phase))
    }
}

extension View {
    /// Show the link/pointing-hand cursor while hovering — the default cursor behaviour
    /// for clickable text, which SwiftUI doesn't apply on its own here.
    /// Calls `onChange` with this view's laid-out height, now and whenever it changes.
    func measuringHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { onChange(proxy.size.height) }
                    .onChange(of: proxy.size.height) { _, height in onChange(height) }
            }
        }
    }

    /// Set, not pushed: the panel never becomes key, so AppKit keeps resetting the cursor to the
    /// arrow and a one-off push on entry was lost straight away. Setting it on every move holds.
    func pointingHandCursor() -> some View {
        onContinuousHover { phase in
            switch phase {
            case .active: NSCursor.pointingHand.set()
            case .ended: NSCursor.arrow.set()
            }
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

/// One provider = one card. The card is the widget: each quota pair is drawn as the medium
/// widget's face — the five-hour window tints that share of the panel from the left, its number
/// sits top right with the reset clock and countdown, and the long window rides a capsule below.
/// Popover and widget then say the same thing the same way. A provider with independent families
/// (Antigravity) gets one panel per family; everyone else gets one.
///
/// Under the panels: the renewal passes as a single chip that opens into its own list, then the
/// money and balance rows, which are always visible — they're short, they're one per provider, and
/// hiding a number behind a disclosure only makes it a number nobody checks.
struct ServiceCard: View {
    let service: ServiceStatus
    let now: Date

    /// Opens the renewal-pass list. The chip already carries the count and the nearest expiry, so
    /// the list is for the dates behind them; collapsed is the resting state.
    @State private var passesOpen = ProcessInfo.processInfo.environment["MIMIR_DEMO_OPEN"] != nil

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(panels.enumerated()), id: \.offset) { _, panel in
                ProviderPanel(panel: panel.promotingLoneWindow(), now: now)
            }

            if !renewalRows.isEmpty {
                renewalChip
                if passesOpen && passes.count > 1 {
                    // The rest of the passes, each a pill like the chip, counting down to 1.
                    ForEach(Array(passes.dropFirst().enumerated()), id: \.offset) { i, row in
                        renewalPill(count: passes.count - 1 - i, expiry: row.resetAt,
                                    fallback: row.valueText)
                    }
                }
            }

            if !alwaysRows.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(alwaysRows) { row in
                        valueRow(row)
                    }
                }
                .padding(.leading, Self.chipInset)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Down to one pass there's nothing left to open; close so a later second pass starts shut.
        .onChange(of: passes.count) { _, count in if count < 2 { passesOpen = false } }
        .padding(9)
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

    // MARK: Renewal passes

    /// The chip: how many passes you hold and how long the nearest one has left. With more than
    /// one it carries a chevron and opens the rest; a single pass has nothing behind it to show.
    private var renewalChip: some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) { passesOpen.toggle() }
        } label: {
            renewalPill(count: passes.count, expiry: soonestPass, fallback: passes.first?.valueText,
                        chevron: passes.count > 1)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(passes.count > 1)
        .pointingHandCursor()
        .help(passesOpen ? "" : String(localized: "Renewal credit"))
    }

    /// One pill: the count badge, the label, how long until it lapses. Its text takes the urgency
    /// colour of that expiry — a pass you lose tomorrow should not read the same as one with a
    /// month on it.
    private func renewalPill(count: Int, expiry: Date?, fallback: String?, chevron: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text("\(count)")
                .monospacedDigit()
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.10)))
            Text(String(localized: "Renewal credit"))
            Text("|").foregroundStyle(Color.primary.opacity(0.18))
            Text(relDuration(expiry, now) ?? fallback ?? "—").monospacedDigit()
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(passesOpen ? 90 : 0))
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(expiryColor(expiry))
        .padding(.horizontal, Self.chipInset).padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .contentShape(Capsule())
    }

    /// Under three days an expiry is worth noticing, under a day it's worth acting on. Above that
    /// it's just a date, and reads in the same quiet grey as everything else.
    private func expiryColor(_ at: Date?) -> Color {
        guard let at else { return Color.primary.opacity(0.42) }
        let left = at.timeIntervalSince(now)
        if left <= 24 * 3600 { return quotaStatusColor(0) }
        if left <= 3 * 86_400 { return quotaStatusColor(20) }
        return Color.primary.opacity(0.42)
    }

    /// A money or balance row. Deliberately identical to a renewal line — same icon column, same
    /// weight, same tone on both sides — because the two sit in one list under the chip and any
    /// difference reads as a distinction that isn't there. A spent balance is the one exception:
    /// it takes the red an empty quota would.
    private func valueRow(_ row: ModelStatus) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: row.symbol ?? "dollarsign.circle").font(.system(size: 11, weight: .regular))
                .frame(width: Self.iconColumn)
            Text(row.name)
            Spacer(minLength: 6)
            Text(row.valueText ?? "")
                .monospacedDigit()
                .fixedSize()
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(row.isLow ? quotaStatusColor(0) : Color.primary.opacity(0.42))
        .lineLimit(1)
    }

    // MARK: Data shaping

    /// Codex is branded "ChatGPT" on the card — that's the account the quota belongs to.
    private var cardTitle: String {
        service.name == "Codex" ? "ChatGPT" : service.name
    }

    /// One panel per quota pair. Antigravity's families are independent quotas that happen to
    /// share an account, so each gets its own panel under its own name; every other provider has
    /// exactly one pair and so exactly one panel.
    private var panels: [PanelData] {
        guard hasServiceQuotas else {
            return antigravityFamilies.map { family in
                PanelData(title: family.name, iconName: service.iconName,
                          session: family.session.map { ($0.percent, $0.resetAt) },
                          weekly: family.weekly.map { ($0.percent, $0.resetAt) },
                          weeklyLabel: "7\(TimeFormatter.dayUnit)",
                          sessionFallback: 5 * 3600, weeklyWindow: 7 * 86_400,
                          gated: family.weekly?.percent == 0)
            }
        }
        return [PanelData(title: cardTitle, iconName: service.iconName,
                          session: service.sessionRemainingPercent.map { ($0, service.sessionResetAt) },
                          weekly: service.weeklyRemainingPercent.map { ($0, service.weeklyResetAt) },
                          weeklyLabel: longWindowLabel ?? "7\(TimeFormatter.dayUnit)",
                          sessionFallback: 5 * 3600,
                          weeklyWindow: service.weeklyWindowSeconds ?? 7 * 86_400,
                          gated: service.weeklyRemainingPercent == 0 && service.sessionRemainingPercent != nil)]
            // A quota beside the plan's own (Codex's Luna Reserve) is a quota in its own right, so it
            // gets its own panel under its own name — the same treatment as an Antigravity family.
            + families(in: service.models.filter { $0.groupLabel == LiveUsageDataSource.codexExtraLimitGroup })
                .map { family in
                    PanelData(title: family.name, iconName: service.iconName,
                              session: family.session.map { ($0.percent, $0.resetAt) },
                              weekly: family.weekly.map { ($0.percent, $0.resetAt) },
                              weeklyLabel: "7\(TimeFormatter.dayUnit)",
                              sessionFallback: 5 * 3600, weeklyWindow: 7 * 86_400,
                              gated: family.weekly?.percent == 0)
                }
    }

    /// The renewal passes, soonest to lapse first.
    private var renewalRows: [ModelStatus] {
        service.models.filter { $0.groupLabel == String(localized: "Renewal credit") }
    }

    private var soonestPass: Date? {
        passes.first?.resetAt
    }

    /// The passes nearest expiry first; one with no date goes last.
    private var passes: [ModelStatus] {
        renewalRows.sorted { ($0.resetAt ?? .distantFuture) < ($1.resetAt ?? .distantFuture) }
    }

    /// Money and balances — always on the card.
    private var alwaysRows: [ModelStatus] {
        service.models.filter { $0.valueText != nil && $0.groupLabel != String(localized: "Renewal credit") }
    }

    /// Antigravity grouped by family, preserving first-seen order, each family carrying
    /// its own session (5h) and weekly (7g) so they render together.
    private var antigravityFamilies: [(name: String, session: (percent: Int, resetAt: Date?)?, weekly: (percent: Int, resetAt: Date?)?)] {
        families(in: service.models)
    }

    /// Rows grouped by name into session/weekly pairs, in the order they first appear.
    private func families(in models: [ModelStatus]) -> [(name: String, session: (percent: Int, resetAt: Date?)?, weekly: (percent: Int, resetAt: Date?)?)] {
        var order: [String] = []
        var bag: [String: (session: (percent: Int, resetAt: Date?)?, weekly: (percent: Int, resetAt: Date?)?)] = [:]
        for model in models where model.valueText == nil {
            if bag[model.name] == nil { order.append(model.name); bag[model.name] = (nil, nil) }
            if model.window == .weekly {
                bag[model.name]?.weekly = (model.remainingPercent, model.resetAt)
            } else {
                bag[model.name]?.session = (model.remainingPercent, model.resetAt)
            }
        }
        return order.map { (name: $0, session: bag[$0]?.session ?? nil, weekly: bag[$0]?.weekly ?? nil) }
    }

    /// True when the provider reports account-level windows (Claude/Codex) rather than per-family
    /// ones (Antigravity).
    private var hasServiceQuotas: Bool {
        service.sessionRemainingPercent != nil || service.weeklyRemainingPercent != nil
    }

    /// "7d" / "30d", from the window's REAL length. nil when the provider didn't report one.
    private var longWindowLabel: String? {
        quotaWindowDays(service.weeklyWindowSeconds).map { "\($0)\(TimeFormatter.dayUnit)" }
    }

    /// Width of the leading icon column, so a symbol and a status dot line up.
    static let iconColumn: CGFloat = 12
    /// The chip's horizontal padding. The lines under it are inset by the same amount so their
    /// icons sit directly below the chip's own, rather than a step to its left.
    static let chipInset: CGFloat = 8
}

/// One quota pair, ready to draw.
struct PanelData {
    let title: String
    let iconName: String
    let session: (percent: Int, resetAt: Date?)?
    let weekly: (percent: Int, resetAt: Date?)?
    let weeklyLabel: String
    let sessionFallback: TimeInterval
    let weeklyWindow: TimeInterval
    let gated: Bool

    /// A plan with one long window and no session (Codex Go's 30 days) shows it where the session
    /// sits — the big number, the clock and the face — instead of an empty corner above a capsule.
    func promotingLoneWindow() -> PanelData {
        guard session == nil, let weekly else { return self }
        return PanelData(title: title, iconName: iconName, session: weekly, weekly: nil,
                         weeklyLabel: weeklyLabel, sessionFallback: weeklyWindow,
                         weeklyWindow: weeklyWindow, gated: false)
    }
}

/// The medium widget, shrunk to fit a card. The panel's face IS the five-hour gauge: what's left
/// of that window tints the same share of the panel from the left, so the reading is the shape of
/// the thing, not a bar next to it. Its number sits top right with the reset clock above the
/// countdown; the long window runs along the bottom as a capsule carrying its own percent.
///
/// Deliberately the same geometry as `DetailedWidget`'s medium size — a user who has both on
/// screen should not have to learn two pictures of one quota.
struct ProviderPanel: View {
    let panel: PanelData
    let now: Date

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let weekly = panel.weekly {
                capsule(percent: weekly.percent, resetAt: weekly.resetAt)
            }
        }
        .padding(9)
        .background(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05))
                GeometryReader { geo in
                    // The wash, not a fill: 12% of the status colour, exactly as the widget paints
                    // it, so a full window reads as a tinted face rather than a solid block.
                    Rectangle()
                        .fill(faceColor.opacity(0.12))
                        .frame(width: geo.size.width * CGFloat(clampPct(panel.session?.percent ?? 0)) / 100)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        )
    }

    private var faceColor: Color {
        panel.gated ? lockedQuotaColor : quotaStatusColor(panel.session?.percent ?? 0)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            HStack(spacing: 6) {
                BrandIconView(iconName: panel.iconName, size: 13)
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .frame(width: 13, height: 13)
                Text(panel.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 6)
            if let session = panel.session {
                VStack(alignment: .trailing, spacing: 1) {
                    if let clock = clockText(session.resetAt) {
                        labelled("clock", clock)
                    }
                    labelled("timer", relDuration(session.resetAt, now)
                             ?? TimeFormatter.duration(from: panel.sessionFallback))
                }
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.primary.opacity(0.42))
                .fixedSize()

                // Caps at 99 like the widget: a third digit buys nothing, and nobody acts
                // differently on 100 versus 99.
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(min(99, clampPct(session.percent)))")
                        .font(.system(size: 30, weight: .semibold)).monospacedDigit().tracking(-0.5)
                    Text("%").font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(panel.gated ? lockedQuotaColor : quotaStatusColor(session.percent))
                .fixedSize()
                .offset(y: -6)
                .frame(height: 22, alignment: .top)
            }
        }
    }

    private func labelled(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9, weight: .regular))
            Text(text)
        }
    }

    /// The long window: a capsule with its percent riding the fill, and the countdown and reset
    /// clock underneath.
    private func capsule(percent: Int, resetAt: Date?) -> some View {
        let color = panel.gated ? lockedQuotaColor : quotaStatusColor(percent)
        return VStack(alignment: .leading, spacing: 9) {
            GeometryReader { geo in
                let fill = max(18, geo.size.width * CGFloat(clampPct(percent)) / 100)
                let number = Text("\(clampPct(percent))%")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    Capsule().fill(color).frame(width: fill)
                    // White on the fill while it's wide enough to hold the number; past the end
                    // otherwise, where the fill can't carry it.
                    if fill >= 46 {
                        number.foregroundStyle(.white.opacity(0.92)).padding(.leading, 9)
                    } else {
                        number.foregroundStyle(Color.primary.opacity(0.9)).padding(.leading, fill + 6)
                    }
                }
            }
            .frame(height: 18)

            HStack(spacing: 10) {
                labelled("timer", relDuration(resetAt, now)
                         ?? TimeFormatter.duration(from: panel.weeklyWindow))
                if let clock = dayClockText(resetAt) {
                    labelled("clock", clock)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(Color.primary.opacity(0.42))
        }
    }

    private func clockText(_ at: Date?) -> String? {
        guard let at, at.timeIntervalSince(now) > 0 else { return nil }
        // A clock alone can't say which day a reset more than a day out lands on; the date can.
        guard at.timeIntervalSince(now) > 86_400 else { return Self.clockFormatter.string(from: at) }
        return Self.dateFormatter.string(from: at)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("d MMM"); return f
    }()

    /// The long window resets days out, so the weekday is what makes the time mean anything.
    private func dayClockText(_ at: Date?) -> String? {
        guard let at, at.timeIntervalSince(now) > 0 else { return nil }
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("EEEE HH:mm")
        return f.string(from: at)
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

/// Status colour for a remaining-quota level, per the design spec's thresholds: green ≥40%,
/// amber 10–39%, red ≤9% — one set of bands for every window. Returns a dynamic colour that
/// darkens in light mode so it stays legible on the light panel.
func quotaStatusColor(_ percent: Int) -> Color {
    let darkHex: UInt32, lightHex: UInt32
    switch clampPct(percent) {
    case 40...100: darkHex = 0x3FB984; lightHex = 0x1FA45E  // green
    case 10...39:  darkHex = 0xE0A93C; lightHex = 0xB07D0A  // amber
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
