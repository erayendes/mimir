import AppKit
import Combine
import Sentry
import ServiceManagement
import Sparkle
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
    private var updaterController: SPUStandardUpdaterController?
    // Per-window notification state, keyed "<service>-5h" / "<service>-weekly".
    private var lowNotified: Set<String> = []     // window is below its low threshold (until it resets)
    private var depleted5h: Set<String> = []      // service's 5h window hit 0% since its last refill
    private var lastWindowPercent: [String: Int] = [:]  // previous reading, for refill edge detection
    private var cachedIconNormal: NSImage?
    private var cachedIconLow: NSImage?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dev builds (com.erayendes.mimir.dev) must not report to the production
        // Sentry project — their crashes/hangs are just local development noise (MIMIR-7).
        let isDevBuild = Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false
        if !isDevBuild {
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
                // App-hang detection can't distinguish a modal dialog waiting for input
                // (Sparkle's update sheet, the launch-at-login prompt) from a real freeze,
                // so it fires false positives whenever a modal is open (MIMIR-4/5/6/7).
                // Crash and error reporting stay on.
                options.enableAppHangTracking = false
            }
        }

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

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
        popover.contentSize = NSSize(width: PopoverMetrics.width, height: 400)
        // Height is driven manually from the measured SwiftUI content (see
        // onContentHeightChange): the popover grows to fit ALL content (no inner
        // scroll), capped only by the screen so it can't run off-screen.
        let hosting = NSHostingController(
            rootView: PopoverView(
                store: store,
                onDismiss: { [weak self] in self?.closePopover(nil) },
                onContentHeightChange: { [weak self] height in
                    guard let self else { return }
                    let screenCap = (NSScreen.main?.visibleFrame.height ?? 900) - 60
                    let ceiling = min(PopoverMetrics.maxHeight, screenCap)
                    let clamped = min(max(height, 80), ceiling)
                    guard abs(self.popover.contentSize.height - clamped) > 0.5 else { return }
                    self.popover.contentSize = NSSize(width: PopoverMetrics.width, height: clamped)
                },
                checkForUpdates: { [weak self] in
                    self?.updaterController?.checkForUpdates(nil)
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
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.store.refresh()
                self?.refreshStatusTitle()
            }
        }

        maybePromptLaunchAtLogin()
    }

    // MARK: - Launch at login

    private static let didPromptLaunchAtLoginKey = "didPromptLaunchAtLogin"

    /// On first launch only, ask whether Mimir should open automatically at login.
    /// Deferred briefly so the menu-bar icon is up before the dialog appears.
    private func maybePromptLaunchAtLogin() {
        guard !UserDefaults.standard.bool(forKey: Self.didPromptLaunchAtLoginKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.didPromptLaunchAtLoginKey)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            Task { @MainActor in self?.presentLaunchAtLoginPrompt() }
        }
    }

    private func presentLaunchAtLoginPrompt() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Launch Mimir at login?")
        alert.informativeText = String(localized: "Mimir can open automatically each time you log in, so your usage is always in the menu bar. You can change this later in System Settings › General › Login Items.")
        alert.addButton(withTitle: String(localized: "Launch at Login"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            setLaunchAtLogin(true)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let crumb = Breadcrumb(level: .warning, category: "launch-at-login")
            crumb.message = "\(enabled ? "register" : "unregister") failed: \(error.localizedDescription)"
            SentrySDK.addBreadcrumb(crumb)
            SentrySDK.capture(error: error)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        stopPopoverDismissMonitors()
        // Keep this strictly below Sentry's 2000 ms app-hang threshold: flushing on the
        // main thread at quit otherwise trips its own AppHang detector (MIMIR-4).
        SentrySDK.flush(timeout: 1)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }

        if popover.isShown {
            closePopover(sender)
        } else {
            store.refresh()
            refreshStatusTitle()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            makePopoverTransparent()
            NSApp.activate(ignoringOtherApps: true)
            startPopoverDismissMonitors()
        }
    }

    /// NSPopover paints an opaque system background bubble; clear it (and the hosting
    /// view chain) so our behind-window blur reaches the desktop and the panel reads
    /// as transparent glass rather than a solid dark card.
    private func makePopoverTransparent() {
        guard let host = popover.contentViewController?.view,
              let window = host.window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        // Walk up to the popover frame view and clear any opaque fill it draws.
        var view: NSView? = host
        while let current = view {
            current.wantsLayer = true
            current.layer?.backgroundColor = NSColor.clear.cgColor
            view = current.superview
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
        statusItem?.button?.toolTip = "mimir by milowda"
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
            // Percentage windows + percentage model rows (skip valueText rows — a credit balance
            // isn't a 0–100 percent, and its `remainingPercent` is a placeholder 0).
            let percents: [Int?] = [svc.sessionRemainingPercent, svc.weeklyRemainingPercent]
                + svc.models.filter { $0.valueText == nil }.map { Optional($0.remainingPercent) }
            // A model in the red status band (< 15%) raises the menu-bar dot.
            if percents.compactMap({ $0 }).contains(where: { $0 < 15 }) { return true }
            // Credit/billing rows flag themselves via `isLow` (below their own threshold).
            return svc.models.contains { $0.isLow }
        }
    }

    private enum QuotaWindow {
        case fiveHour, weekly
        var suffix: String { self == .fiveHour ? "5h" : "weekly" }
        var lowThreshold: Int { self == .fiveHour ? 20 : 10 }
    }

    private func checkNotifications() {
        // Only the account-level 5h + weekly windows of LIVE services notify here. The
        // `isAvailable` guard is load-bearing: a service served from a stale snapshot is
        // `isAvailable == false`, so it never fires a low/refill alert on cached numbers — this
        // holds for Claude/Codex snapshots too, not just Antigravity. Antigravity is additionally
        // excluded by name (it has no service-level windows; it uses per-group model rows).
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
                    title: String(format: String(localized: "🚀 %@ weekly quota refilled"), "Antigravity"),
                    body: String(localized: "Back to 100%% for the week.")
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
            .filter { $0.window == .weekly }
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
                        title: String(format: String(localized: "🔋 %@ 5-hour quota refilled"), service.name),
                        body: String(localized: "You're back to 100%% — pick up where you left off.")
                    )
                }
                depleted5h.remove(service.name)
            case .weekly:
                sendNotification(
                    identifier: "\(key)-refilled",
                    title: String(format: String(localized: "🚀 %@ weekly quota refilled"), service.name),
                    body: String(localized: "Back to 100%% for the week.")
                )
            }
            lowNotified.remove(key)
            return
        }

        // Low: crossed below the threshold. Warn once, then stay quiet until the window resets.
        if percent < window.lowThreshold, !lowNotified.contains(key) {
            let resets = resetAt.map { String(format: String(localized: "Resets in ~%@."), TimeFormatter.duration(from: $0.timeIntervalSinceNow)) }
            switch window {
            case .fiveHour:
                sendNotification(
                    identifier: key,
                    title: String(format: String(localized: "🪫 %@ 5-hour quota low — %d%%"), service.name, percent),
                    body: resets ?? String(localized: "Your 5-hour limit is running out.")
                )
            case .weekly:
                sendNotification(
                    identifier: key,
                    title: String(format: String(localized: "🚨 %@ weekly quota low — %d%%"), service.name, percent),
                    body: resets ?? String(localized: "Your weekly limit is running out.")
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

    /// The inner panel: a distinct card with a hairline border that floats on the outer
    /// ambient backdrop, giving the panel-in-panel depth. Adapts to light/dark.
    @ViewBuilder
    private var innerPanel: some View {
        let dark = colorScheme == .dark
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill((dark ? Color(hex: 0x14141C) : Color(hex: 0xFFFFFF)).opacity(dark ? 0.86 : 0.80))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(dark ? 0.10 : 0.08), lineWidth: 1)
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
        let order = ["Claude", "Codex", "Antigravity"]
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
private struct BrandingFooter: View {
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

private extension View {
    /// Show the link/pointing-hand cursor while hovering — the default cursor behaviour
    /// for clickable text, which SwiftUI doesn't apply on its own here.
    func pointingHandCursor() -> some View {
        onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

private enum PopoverMetrics {
    static let edgeInset: CGFloat = 14
    /// Resting top/bottom padding.
    static let contentInset: CGFloat = 18
    static let width: CGFloat = 300
    /// Safety ceiling only; the popover otherwise grows to fit all content (no inner scroll).
    static let maxHeight: CGFloat = 1400
    static let placeholderHeight: CGFloat = 200
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

/// Behind-window blur: blurs the actual desktop behind the popover (not just the
/// window's own content like SwiftUI's `.ultraThinMaterial`). This is what makes
/// the panel read as transparent glass over the wallpaper.
private struct DesktopBlur: NSViewRepresentable {
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
private struct PopoverBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    var body: some View {
        ZStack {
            DesktopBlur(dark: dark)

            LinearGradient(
                colors: dark
                    ? [Color(hex: 0x12121A), Color(hex: 0x0C0D14), Color(hex: 0x08090E)]
                    : [Color(hex: 0xF4F4F7), Color(hex: 0xECECEF), Color(hex: 0xE6E6EA)],
                startPoint: .top, endPoint: .bottom
            )
            .opacity(dark ? 0.82 : 0.72)

            RadialGradient(colors: [Color(hex: 0x7E8BF2).opacity(dark ? 0.18 : 0.12), .clear],
                           center: .topTrailing, startRadius: 8, endRadius: 280)
            RadialGradient(colors: [Color(hex: 0xE6885B).opacity(dark ? 0.14 : 0.10), .clear],
                           center: .bottomLeading, startRadius: 8, endRadius: 280)
        }
        .ignoresSafeArea()
    }
}

private struct ServiceCard: View {
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

            // One prominent block per session (Claude/Codex: one; Antigravity: two).
            ForEach(Array(sessionHeroes.enumerated()), id: \.offset) { index, hero in
                SessionRow(label: hero.label, percent: hero.percent, resetAt: hero.resetAt, now: now)
                    .padding(.top, index == 0 ? 11 : 13)
            }

            // Weekly rows: status dot + label + 7g badge + percent + reset countdown.
            if !weeklyEntries.isEmpty {
                VStack(spacing: 6) {
                    ForEach(Array(weeklyEntries.enumerated()), id: \.offset) { _, entry in
                        weeklyRow(entry)
                    }
                }
                .padding(.top, 11)
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

    /// The prominent 5-hour session block(s). Claude/Codex have one (labelled with the
    /// service name); Antigravity has one per family (Gemini, Claude/GPT).
    private var sessionHeroes: [(label: String, percent: Int, resetAt: Date?)] {
        if hasServiceQuotas {
            guard let session = service.sessionRemainingPercent else { return [] }
            return [(service.name, session, service.sessionResetAt)]
        }
        return service.models
            .filter { $0.window == .session }
            .map { (label: $0.name, percent: $0.remainingPercent, resetAt: $0.resetAt) }
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

private extension Color {
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

private func clampPct(_ percent: Int) -> Int { max(0, min(100, percent)) }

private func relDuration(_ resetAt: Date?, _ now: Date) -> String? {
    guard let resetAt, resetAt.timeIntervalSince(now) > 0 else { return nil }
    return TimeFormatter.duration(from: resetAt.timeIntervalSince(now))
}

/// A small grey pill badge (e.g. "5s" for the 5-hour session, "7g" for the weekly window).
private struct QuotaBadge: View {
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
private struct SessionRow: View {
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
                    Text(relDuration(resetAt, now) ?? "—")
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

private struct QuotaBar: View {
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
private func quotaStatusColor(_ percent: Int) -> Color {
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

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: 1
        )
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
