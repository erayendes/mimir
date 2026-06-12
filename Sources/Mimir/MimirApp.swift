import AppKit
import Combine
import Sentry
import SwiftUI
import UserNotifications

@main
struct MimirApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []
    // Per-window notification state, keyed "<service>-5h" / "<service>-weekly".
    private var lowNotified: Set<String> = []     // window is below its low threshold (until it resets)
    private var depleted5h: Set<String> = []      // service's 5h window hit 0% since its last refill
    private var lastWindowPercent: [String: Int] = [:]  // previous reading, for refill edge detection
    private var cachedIconNormal: NSImage?
    private var cachedIconLow: NSImage?

    func applicationDidFinishLaunching(_ notification: Notification) {
        SentrySDK.start { options in
            options.dsn = "https://66d3b6b50b79ba45dc89e86329579302@o4511381595291648.ingest.us.sentry.io/4511537599086592"
            #if DEBUG
            options.debug = true
            #else
            options.debug = false
            #endif
            options.sendDefaultPii = false
            options.tracesSampleRate = 0.1
            // SentryBreadcrumbTracker swizzles AppKit from a background queue, which
            // trips macOS 26's strict main-thread assertions (MIMIR-2). We only use
            // manual breadcrumbs, so the automatic tracker is safe to disable.
            options.enableAutoBreadcrumbTracking = false
        }

        NSApp.setActivationPolicy(.accessory)

        if let source = Bundle.main.url(forResource: "MenuIcon", withExtension: "png")
            .flatMap({ NSImage(contentsOf: $0) }) {
            cachedIconNormal = buildStatusIcon(source: source, isLow: false)
            cachedIconLow    = buildStatusIcon(source: source, isLow: true)
        }

        NSApp.publisher(for: \.effectiveAppearance)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStatusTitle() }
            .store(in: &cancellables)

        UNUserNotificationCenter.current().getNotificationSettings { @Sendable settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        popover.behavior = .transient
        popover.contentSize = NSSize(width: PopoverMetrics.width, height: PopoverMetrics.maxHeight)
        // Height is driven manually from the measured SwiftUI content (see
        // onContentHeightChange): preference-based plumbing silently drops
        // updates inside this TimelineView/ScrollView hierarchy, so the view
        // reports its size through a plain callback instead.
        let hosting = NSHostingController(
            rootView: PopoverView(
                store: store,
                onDismiss: { [weak self] in self?.closePopover(nil) },
                onContentHeightChange: { [weak self] height in
                    guard let self else { return }
                    let clamped = min(max(height, 80), PopoverMetrics.maxHeight)
                    guard abs(self.popover.contentSize.height - clamped) > 0.5 else { return }
                    self.popover.contentSize = NSSize(width: PopoverMetrics.width, height: clamped)
                }
            )
        )
        hosting.sizingOptions = []
        popover.contentViewController = hosting

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item

        store.refresh()
        refreshStatusTitle()
        store.$services
            .receive(on: RunLoop.main)
            .sink { [weak self] services in
                let crumb = Breadcrumb()
                crumb.category = "services.refresh"
                crumb.message = services
                    .map { "\($0.name): \($0.isAvailable ? "ok" : "unavailable")" }
                    .joined(separator: ", ")
                crumb.level = services.contains(where: { !$0.isAvailable }) ? .warning : .info
                SentrySDK.addBreadcrumb(crumb)
                self?.refreshStatusTitle()
            }
            .store(in: &cancellables)
        store.checkForUpdate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.store.refresh()
                self?.refreshStatusTitle()
                self?.store.checkForUpdate()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        stopPopoverDismissMonitors()
        SentrySDK.flush(timeout: 2)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }

        if popover.isShown {
            closePopover(sender)
        } else {
            store.refresh()
            refreshStatusTitle()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            startPopoverDismissMonitors()
        }
    }

    private func closePopover(_ sender: Any?) {
        popover.performClose(sender)
        stopPopoverDismissMonitors()
    }

    private func startPopoverDismissMonitors() {
        stopPopoverDismissMonitors()

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            guard self.popover.isShown else { return event }

            if event.window === self.popover.contentViewController?.view.window {
                return event
            }

            if event.window === self.statusItem?.button?.window {
                return event
            }

            self.closePopover(event)
            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.closePopover(nil)
            }
        }
    }

    private func stopPopoverDismissMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }

        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    private func refreshStatusTitle() {
        let isLow = isQuotaLow
        if let icon = isLow ? cachedIconLow : cachedIconNormal {
            statusItem?.button?.image = icon
        } else {
            let size = NSSize(width: 18, height: 18)
            let fallback = NSImage(size: size, flipped: false) { [isLow] rect in
                (isLow ? NSColor.systemRed : NSColor.labelColor).setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
                return true
            }
            fallback.isTemplate = false
            statusItem?.button?.image = fallback
        }
        statusItem?.button?.contentTintColor = nil
        statusItem?.button?.title = ""
        statusItem?.button?.imagePosition = .imageOnly
        statusItem?.button?.toolTip = store.services.isEmpty
            ? "Loading..."
            : store.services.map(\.name).joined(separator: " | ")
        checkNotifications()
    }

    private func buildStatusIcon(source: NSImage, isLow: Bool) -> NSImage {
        let iconSize = NSSize(width: 22, height: 22)
        let img = NSImage(size: iconSize, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current else { return true }
            ctx.imageInterpolation = .high
            NSBezierPath(ovalIn: rect).addClip()
            source.draw(in: rect, from: NSRect(origin: .zero, size: source.size),
                        operation: .sourceOver, fraction: 1.0)
            let isDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if !isDark {
                ctx.compositingOperation = .sourceAtop
                NSColor.black.setFill()
                NSBezierPath(ovalIn: rect).fill()
                ctx.compositingOperation = .sourceOver
            }
            if isLow {
                let d: CGFloat = 6
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - 8, y: rect.minY + 1, width: d, height: d)).fill()
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    private var isQuotaLow: Bool {
        store.services.filter(\.isAvailable).contains { svc in
            let percents: [Int?] = [svc.sessionRemainingPercent, svc.weeklyRemainingPercent]
                + svc.models.map { Optional($0.remainingPercent) }
            return percents.compactMap { $0 }.contains { $0 < 20 }
        }
    }

    private enum QuotaWindow {
        case fiveHour, weekly
        var suffix: String { self == .fiveHour ? "5h" : "weekly" }
        var lowThreshold: Int { self == .fiveHour ? 20 : 10 }
    }

    private func checkNotifications() {
        // Only the account-level 5h + weekly windows of live services notify here. Antigravity is
        // excluded: it has no service-level windows (it uses per-group model rows) and its usage
        // data is only live while the IDE is open — stale snapshots must not fire false alerts.
        for service in store.services where service.isAvailable && service.name != "Antigravity" {
            evaluateWindow(service: service, window: .fiveHour,
                           percent: service.sessionRemainingPercent, resetAt: service.sessionResetAt)
            evaluateWindow(service: service, window: .weekly,
                           percent: service.weeklyRemainingPercent, resetAt: service.weeklyResetAt)
        }
        checkAntigravityWeeklyRefill()
    }

    private static let agyResetTargetKey = "agyWeeklyResetTarget"      // armed reset we're waiting on
    private static let agyResetNotifiedKey = "agyWeeklyResetNotified"  // reset we've already announced

    /// Antigravity's one reliable notification: the weekly quota refill. Its weekly reset time is
    /// deterministic and known in advance, and the quota can't be spent while the IDE is closed —
    /// so once we've seen the reset time, we can fire "refilled" exactly when it passes, with no
    /// live data. (Low / 5h alerts stay off: those depend on usage we can't observe reliably.)
    private func checkAntigravityWeeklyRefill() {
        let defaults = UserDefaults.standard
        let now = Date()

        // Fire when the armed reset has passed, then disarm so the next reset can arm cleanly.
        let armed = defaults.double(forKey: Self.agyResetTargetKey)
        if armed > 0, now.timeIntervalSince1970 >= armed {
            if defaults.double(forKey: Self.agyResetNotifiedKey) != armed {
                sendNotification(
                    identifier: "Antigravity-weekly-refilled",
                    title: "🚀 Antigravity weekly quota refilled",
                    body: "Back to 100% for the week."
                )
                defaults.set(armed, forKey: Self.agyResetNotifiedKey)
            }
            defaults.removeObject(forKey: Self.agyResetTargetKey)
        }

        // Arm the next future weekly reset (both weekly buckets share one time → take the earliest).
        // Only when nothing is armed and only a reset we haven't already announced, so the data
        // jumping to next week at reset time can't clobber the reset we still owe a notification for.
        guard defaults.double(forKey: Self.agyResetTargetKey) == 0,
              let antigravity = store.services.first(where: { $0.name == "Antigravity" }) else {
            return
        }
        let upcoming = antigravity.models
            .filter { $0.name.contains("Weekly") }
            .compactMap(\.resetAt)
            .filter { $0 > now }
            .min()
        if let upcoming, upcoming.timeIntervalSince1970 != defaults.double(forKey: Self.agyResetNotifiedKey) {
            defaults.set(upcoming.timeIntervalSince1970, forKey: Self.agyResetTargetKey)
        }
    }

    private func evaluateWindow(service: ServiceStatus, window: QuotaWindow, percent: Int?, resetAt: Date?) {
        guard let percent else { return }
        let key = "\(service.name)-\(window.suffix)"
        let previous = lastWindowPercent[key]
        lastWindowPercent[key] = percent

        // A fully drained 5h window is the only thing that earns a 5h refill notice later.
        if window == .fiveHour, percent == 0 {
            depleted5h.insert(service.name)
        }

        // Refill: the window jumped back to 100 (a reset). Edge-triggered on the <100 → 100
        // crossing so it fires once per reset, never on the first reading (previous == nil).
        if percent == 100, let previous, previous < 100 {
            switch window {
            case .fiveHour:
                if depleted5h.contains(service.name) {
                    sendNotification(
                        identifier: "\(key)-refilled",
                        title: "🔋 \(service.name) 5-hour quota refilled",
                        body: "You're back to 100% — pick up where you left off."
                    )
                }
                depleted5h.remove(service.name)
            case .weekly:
                sendNotification(
                    identifier: "\(key)-refilled",
                    title: "🚀 \(service.name) weekly quota refilled",
                    body: "Back to 100% for the week."
                )
            }
            lowNotified.remove(key)
            return
        }

        // Low: crossed below the threshold. Warn once, then stay quiet until the window resets.
        if percent < window.lowThreshold, !lowNotified.contains(key) {
            let resets = resetAt.map { "Resets in ~\(TimeFormatter.duration(from: $0.timeIntervalSinceNow))." }
            switch window {
            case .fiveHour:
                sendNotification(
                    identifier: key,
                    title: "🪫 \(service.name) 5-hour quota low — \(percent)%",
                    body: resets ?? "Your 5-hour limit is running out."
                )
            case .weekly:
                sendNotification(
                    identifier: key,
                    title: "🚨 \(service.name) weekly quota low — \(percent)%",
                    body: resets ?? "Your weekly limit is running out."
                )
            }
            lowNotified.insert(key)
        }
    }

    private func sendNotification(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

private struct PopoverView: View {
    @ObservedObject var store: UsageStore
    let onDismiss: () -> Void
    /// Reports the measured content height so AppKit can size the popover.
    /// Plain callback on purpose — see the note at the construction site.
    let onContentHeightChange: (CGFloat) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ZStack {
                PopoverBackdrop()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: PopoverMetrics.edgeInset) {
                        if let update = store.availableUpdate {
                            UpdateBanner(update: update)
                        }
                        contentView(now: context.date)

                        BrandingFooter()
                    }
                    .padding(.vertical, PopoverMetrics.contentInset)
                    .padding(.horizontal, PopoverMetrics.edgeInset)
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
                // Scrolled cards dissolve in a gradient band and never reach the
                // popover edge: the outer `edgeClearZone` stays permanently empty,
                // so content can't appear to escape the background area. At rest
                // the cards sit exactly below/above the bands, so nothing is dimmed.
                .mask {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: PopoverMetrics.edgeClearZone)
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: PopoverMetrics.contentInset - PopoverMetrics.edgeClearZone)
                        Rectangle().fill(Color.black)
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: PopoverMetrics.contentInset - PopoverMetrics.edgeClearZone)
                        Color.clear.frame(height: PopoverMetrics.edgeClearZone)
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
        let visible = store.services.filter { $0.isAvailable || $0.isStale }
        if !visible.isEmpty {
            ForEach(visible) { service in
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

/// Quiet identity mark under the last card: logo, name, version.
/// Deliberately low-contrast — branding should be findable, never loud.
private struct BrandingFooter: View {
    private static let logo: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }()

    private static let version: String =
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { "v\($0)" } ?? "dev"

    var body: some View {
        // Logo spans both text lines; the name line mirrors the card headers
        // (15pt semibold) and the version/byline use the relative-time label size.
        HStack(spacing: 10) {
            if let logo = Self.logo {
                // MenuIcon's glyph fills only ~60% of its canvas; oversize the
                // drawn frame so the visible face spans the two text lines, while
                // the layout frame stays at the two-line height.
                Image(nsImage: logo)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 46, height: 46)
                    .frame(width: 30, height: 30)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("Mimir")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .tracking(0.05)

                    Text(Self.version)
                        .font(.system(size: 11, weight: .regular).monospacedDigit())
                        .opacity(0.8)
                }

                Text("milowda")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .opacity(0.8)
            }
        }
        .foregroundStyle(Color.secondary.opacity(0.7))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
        .padding(.top, 1)
    }
}

private enum PopoverMetrics {
    static let edgeInset: CGFloat = 15
    /// Resting top/bottom padding; scrolled cards dissolve inside its inner part.
    static let contentInset: CGFloat = 25
    /// Outer band that always stays empty — content never appears this close to the edge.
    static let edgeClearZone: CGFloat = 12
    static let width: CGFloat = 360
    static let maxHeight: CGFloat = 500
    static let placeholderHeight: CGFloat = 200
}

private struct UpdateBanner: View {
    let update: AvailableUpdate

    var body: some View {
        Button {
            NSWorkspace.shared.open(update.url)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 1) {
                    Text("New version available")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.primary.opacity(0.86))
                    Text("v\(update.version)")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(Color.secondary.opacity(0.72))
                }

                Spacer(minLength: 6)

                HStack(spacing: 3) {
                    Text("Download")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.28), lineWidth: 1)
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Subtle press feedback — the row scales down slightly while held, so it feels
/// responsive to the click rather than static. (Emil: buttons must feel pressed.)
private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct PopoverBackdrop: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)

            RadialGradient(
                colors: [
                    Color(nsColor: .systemGreen).opacity(0.10),
                    Color.clear
                ],
                center: .topTrailing,
                startRadius: 10,
                endRadius: 260
            )

            RadialGradient(
                colors: [
                    Color(nsColor: .systemYellow).opacity(0.08),
                    Color.clear
                ],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 280
            )

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.035),
                            Color.primary.opacity(0.012),
                            Color.black.opacity(0.07)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            LinearGradient(
                colors: [
                    Color.white.opacity(0.06),
                    Color.clear,
                    Color.black.opacity(0.10)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .blendMode(.softLight)
        }
        .ignoresSafeArea()
    }
}

private struct ServiceCard: View {
    let service: ServiceStatus
    let now: Date
    @State private var showInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                BrandIconView(iconName: service.iconName, size: 18)
                    .frame(width: 18)

                Text(service.name)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .tracking(0.05)
                    .foregroundStyle(Color.primary.opacity(0.86))

                if let info = service.infoText {
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { showInfo.toggle() }
                    } label: {
                        Image(systemName: showInfo ? "info.circle.fill" : "info.circle")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(Color.secondary.opacity(showInfo ? 0.95 : 0.6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(info)
                    .accessibilityLabel(Text(info))
                }

                if !service.isAvailable {
                    Text(service.statusNote ?? "unavailable")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(Color.secondary.opacity(0.72))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }

            if showInfo, let info = service.infoText {
                Text(info)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.secondary.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            VStack(alignment: .leading, spacing: 10) {
                limitRows
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.thinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.035))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.primary.opacity(0.075), lineWidth: 1)
                }
        }
        // Dim a stale snapshot so it reads as "last known, not live".
        .opacity(service.isStale ? 0.66 : 1)
    }

    @ViewBuilder
    private var limitRows: some View {
        if hasServiceQuotas {
            LimitMetricRow(title: "5h Session", percent: service.sessionRemainingPercent, resetAt: service.sessionResetAt, now: now)
            LimitMetricRow(title: "Weekly", percent: service.weeklyRemainingPercent, resetAt: service.weeklyResetAt, now: now)

            if !service.models.isEmpty {
                Divider().opacity(0.4)
            }
        }

        ForEach(service.models) { model in
            LimitMetricRow(
                title: model.name,
                percent: model.valueText == nil ? model.remainingPercent : nil,
                resetAt: model.resetAt,
                valueText: model.valueText,
                now: now
            )
        }
    }

    private var hasServiceQuotas: Bool {
        service.name == "Claude" || service.name == "Codex"
    }
}

private struct LimitMetricRow: View {
    let title: String
    let percent: Int?
    let resetAt: Date?
    var valueText: String?
    let now: Date

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.78))

                if !percentLabel.isEmpty {
                    Text(percentLabel)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.secondary.opacity(0.62))
                }

                Spacer(minLength: 6)

                if let clock = clockStr, let rel = relativeStr {
                    Text(clock)
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(valueColor)
                    Text("(\(rel))")
                        .font(.system(size: 11, weight: .regular).monospacedDigit())
                        .foregroundStyle(Color.secondary.opacity(0.58))
                } else if let valueText {
                    Text(valueText)
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.primary.opacity(0.80))
                }
            }

            if let percent {
                LineGauge(percent: percent, tint: metricTint)
            }
        }
        .padding(.vertical, 1)
    }

    private var percentLabel: String {
        guard let percent else { return "" }
        return "(\(max(0, min(100, percent)))% left)"
    }

    private var clockStr: String? {
        guard let resetAt, resetAt.timeIntervalSince(now) > 0 else { return nil }
        return Self.clockFormatter.string(from: resetAt)
    }

    private var relativeStr: String? {
        guard let resetAt, resetAt.timeIntervalSince(now) > 0 else { return nil }
        return TimeFormatter.duration(from: resetAt.timeIntervalSince(now))
    }

    private var valueColor: Color {
        guard percent != nil else { return Color.primary.opacity(0.82) }
        return metricTint.opacity(0.90)
    }

    private var metricTint: Color {
        guard let percent else { return Color.primary.opacity(0.58) }
        switch max(0, min(100, percent)) {
        case 0...25:  return Color(nsColor: .systemRed)
        case 26...60: return Color(nsColor: .systemYellow)
        default:      return Color(nsColor: .systemGreen)
        }
    }
}

private struct LineGauge: View {
    let percent: Int
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let ratio = CGFloat(max(0, min(100, percent))) / 100

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.09))

                Capsule()
                    .fill(tint.opacity(0.74))
                    .frame(width: max(3, proxy.size.width * ratio))
            }
        }
        .frame(height: 3)
    }
}

private struct BrandIconView: View {
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
