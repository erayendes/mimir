import AppKit
import Combine
import Sentry
import ServiceManagement
import Sparkle
import SwiftUI
import UserNotifications
import WidgetKit

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
    /// Borderless translucent panel instead of NSPopover: NSPopover paints an opaque
    /// system background that blocks behind-window blur, so the desktop can never read
    /// through. A custom NSPanel lets our `.behindWindow` glass show the desktop.
    private let panel: NSPanel = {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: PopoverMetrics.width, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.isMovableByWindowBackground = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        return p
    }()
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []
    private var updaterController: SPUStandardUpdaterController?
    // Per-window notification state, keyed "<service>-5h" / "<service>-weekly".
    private var lowNotified: Set<String> = []     // window is below its low threshold (until it resets)
    private var depleted5h: Set<String> = []      // service's 5h window hit 0% since its last refill
    private var lastWindowPercent: [String: Int] = [:]  // previous reading, for refill edge detection
    private var iconSource: NSImage?
    private var refreshCount = 0              // refreshes seen this session (for the provider signal)
    private var sentProviderSignal = false   // provider.active is emitted once per session

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

        // Anonymous, opt-out usage telemetry (no-op for dev builds / opted-out users). The
        // widget-usage snapshot is read here since WidgetCenter is local and immediate.
        Telemetry.start()
        WidgetCenter.shared.getCurrentConfigurations { result in
            let families = (try? result.get())?.map { "\($0.family)" } ?? []
            // getCurrentConfigurations' completion runs on an arbitrary queue; hop to main so the
            // telemetry state (started flag) is only ever touched there.
            DispatchQueue.main.async {
                Telemetry.signal("widget.installed", parameters: Telemetry.widgetParameters(families: families))
            }
        }

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        NSApp.setActivationPolicy(.accessory)

        iconSource = Bundle.main.url(forResource: "MenuIcon", withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) }

        NSApp.publisher(for: \.effectiveAppearance)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStatusTitle() }
            .store(in: &cancellables)

        UNUserNotificationCenter.current().getNotificationSettings { @Sendable settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        // Height is driven manually from the measured SwiftUI content (see
        // onContentHeightChange): the panel grows to fit ALL content (no inner
        // scroll), capped only by the screen so it can't run off-screen.
        let host = NSHostingView(
            rootView: PopoverView(
                store: store,
                onDismiss: { [weak self] in self?.hidePanel() },
                onContentHeightChange: { [weak self] height in
                    guard let self else { return }
                    // Cap against the screen the panel actually opens on (the menu-bar
                    // button's screen), not necessarily the main display — otherwise a
                    // short secondary display could let the panel run off its bottom.
                    let panelScreen = self.statusItem?.button?.window?.screen ?? NSScreen.main
                    let screenCap = (panelScreen?.visibleFrame.height ?? 900) - 60
                    let ceiling = min(PopoverMetrics.maxHeight, screenCap)
                    self.resizePanel(toHeight: min(max(height, 80), ceiling))
                },
                checkForUpdates: { [weak self] in
                    self?.updaterController?.checkForUpdates(nil)
                }
            )
        )
        host.wantsLayer = true
        host.layer?.cornerRadius = 22
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        panel.contentView = host

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
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
                self?.noteRefreshForTelemetry(services)
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

    /// Right-click menu: opt-out toggle, update check, and quit (the app has no other quit path).
    /// `statusItem.menu` is set only transiently so a left click still toggles the panel.
    private func showStatusMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()

        let toggle = NSMenuItem(title: String(localized: "Send anonymous statistics"),
                                action: #selector(toggleTelemetry), keyEquivalent: "")
        toggle.target = self
        toggle.state = Telemetry.enabled ? .on : .off
        menu.addItem(toggle)
        menu.addItem(.separator())

        let update = NSMenuItem(title: String(localized: "Check for updates"),
                                action: #selector(menuCheckForUpdates), keyEquivalent: "")
        update.target = self
        menu.addItem(update)

        let quit = NSMenuItem(title: String(localized: "Quit Mimir"),
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func toggleTelemetry() {
        Telemetry.setEnabled(!Telemetry.enabled)
        if Telemetry.enabled { Telemetry.signal("telemetry.enabled") }
    }

    @objc private func menuCheckForUpdates() {
        updaterController?.checkForUpdates(nil)
        Telemetry.signal("update.checkRequested")
    }

    /// Emit the provider-usage signal once per session, on the 3rd refresh — Antigravity is only
    /// visible while its IDE runs, so sampling at launch would undercount it. ~3 min (60s × 3) in,
    /// the picture has usually settled; if not, it's caught next session.
    private func noteRefreshForTelemetry(_ services: [ServiceStatus]) {
        guard !sentProviderSignal else { return }
        refreshCount += 1
        guard refreshCount >= 3 else { return }
        sentProviderSignal = true
        Telemetry.signal("provider.active", parameters: Telemetry.providerParameters(from: services))
    }

    @objc private func togglePopover(_ sender: Any?) {
        // Right-click opens the menu instead of the panel.
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
            return
        }
        if panel.isVisible {
            hidePanel()
        } else {
            // Opening the panel is a deliberate user action, so this refresh is allowed to read
            // Claude Code's keychain item if needed (the only path that can prompt). The 60s
            // background timer and the launch refresh stay prompt-free (userInitiated: false).
            store.refresh(userInitiated: true)
            refreshStatusTitle()
            showPanel()
        }
    }

    /// Position the panel just below the menu-bar button, clamped to the screen, and show it.
    private func showPanel() {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        let onScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let width = PopoverMetrics.width
        let height = panel.frame.height > 80 ? panel.frame.height : 400
        let topY = onScreen.minY - 6
        var x = onScreen.midX - width / 2
        if let screen = buttonWindow.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            x = min(max(x, vf.minX + 8), vf.maxX - width - 8)
        }
        panel.setFrame(NSRect(x: x, y: topY - height, width: width, height: height), display: true)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
        startPopoverDismissMonitors()
    }

    private func hidePanel() {
        panel.orderOut(nil)
        stopPopoverDismissMonitors()
    }

    /// Grow/shrink to fit content, keeping the top edge fixed so the panel hangs down
    /// from the menu bar rather than drifting.
    private func resizePanel(toHeight h: CGFloat) {
        var frame = panel.frame
        guard abs(frame.height - h) > 0.5 else { return }
        frame.origin.y = frame.maxY - h
        frame.size.height = h
        panel.setFrame(frame, display: true)
    }

    private func startPopoverDismissMonitors() {
        stopPopoverDismissMonitors()

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            guard self.panel.isVisible else { return event }

            // Escape closes the panel and the keystroke is swallowed.
            if event.type == .keyDown {
                if event.keyCode == 53 { self.hidePanel(); return nil }
                return event
            }

            if event.window === self.panel { return event }
            if event.window === self.statusItem?.button?.window { return event }

            self.hidePanel()
            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.hidePanel()
            }
        }

        // Unlike the old transient NSPopover, a bare NSPanel won't auto-close when the
        // app loses focus. Mouse-driven switches are caught by the global monitor above;
        // this covers the keyboard/Spaces paths (Cmd-Tab, Mission Control) that produce
        // no outside mouse-down, so the panel can't be left floating across Spaces.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.hidePanel() }
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

        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }

    private func refreshStatusTitle() {
        let image = buildMenuBarImage(dotColors: menuBarDotColors())
        statusItem?.button?.image = image
        statusItem?.button?.contentTintColor = nil
        statusItem?.button?.title = ""
        statusItem?.button?.imagePosition = .imageOnly
        statusItem?.button?.toolTip = "mimir by milowda"
        statusItem?.length = image.size.width + 8
        checkNotifications()
    }

    /// One colour per dot from `menuBarDots` (the popover-matching service set, ordered by the shared
    /// `serviceDisplayOrder`: Claude, Codex, Antigravity). The selection logic lives in that pure helper so it
    /// can be unit-tested; here we only colour each: a 5-hour percent → its status colour, `nil`
    /// (no 5h reading yet, or the fetch hasn't landed) → a neutral grey placeholder. It recolours on
    /// the next refresh.
    private func menuBarDotColors() -> [NSColor] {
        menuBarDots(from: store.services).map { $0.map(statusNSColor) ?? Self.noDataDotColor }
    }

    /// Grey "no data yet" dot for a visible service whose 5-hour reading is missing. Appearance-
    /// aware (resolved at `setFill` time inside the menu-bar draw pass): a darker grey on the light
    /// menu bar, a lighter grey on the dark one, so it stays legible either way — unlike the
    /// saturated status colours, a single fixed grey washes out against one of the two backgrounds.
    private static let noDataDotColor = NSColor(name: "mimirNoData") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(hex: 0x9A9AA0)   // lighter grey for the dark menu bar
            : NSColor(hex: 0x6E6E73)   // darker grey for the light menu bar
    }

    private func statusNSColor(_ percent: Int) -> NSColor {
        switch max(0, min(100, percent)) {
        case 50...100: return NSColor(hex: 0x3FB984)  // green
        case 15..<50:  return NSColor(hex: 0xE0A93C)  // amber
        default:       return NSColor(hex: 0xE5564E)  // red
        }
    }

    /// Menu-bar image: the Mimir glyph plus a grid of status dots — one per 5-hour session window
    /// (Claude, Codex, then each Antigravity family), coloured by its 5-hour quota or grey when the
    /// reading is missing. The grid is `menuBarColumnCount` wide (a single column up to 3 dots, 2
    /// columns from 4 on so four land as a 2×2), filled row-major, and is dropped entirely when there
    /// are none so the glyph stays centred. Non-template so the dots keep their colour; in light mode
    /// the glyph is filled black for contrast, in dark mode the source artwork is drawn as-is.
    private func buildMenuBarImage(dotColors: [NSColor]) -> NSImage {
        let iconW: CGFloat = 22
        let height: CGFloat = 22
        let gap: CGFloat = 3.5
        let dot: CGFloat = 3.5
        let dotGapV: CGFloat = 2.2
        let dotGapH: CGFloat = 2.2
        let n = dotColors.count
        let cols = menuBarColumnCount(for: n)
        let rows = n > 0 ? (n + cols - 1) / cols : 0
        let gridW = dot * CGFloat(cols) + dotGapH * CGFloat(cols - 1)
        let totalW = n > 0 ? iconW + gap + gridW : iconW

        let img = NSImage(size: NSSize(width: totalW, height: height), flipped: false) { [iconSource] _ in
            guard let ctx = NSGraphicsContext.current else { return true }
            ctx.imageInterpolation = .high

            if let source = iconSource {
                let iconRect = NSRect(x: 0, y: (height - iconW) / 2, width: iconW, height: iconW)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(ovalIn: iconRect).addClip()
                source.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                let isDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                if !isDark {
                    ctx.compositingOperation = .sourceAtop
                    NSColor.black.setFill()
                    NSBezierPath(ovalIn: iconRect).fill()
                    ctx.compositingOperation = .sourceOver
                }
                NSGraphicsContext.restoreGraphicsState()
            }

            if n > 0 {
                let dotsX = iconW + gap
                let gridH = dot * CGFloat(rows) + dotGapV * CGFloat(rows - 1)
                let topY = (height + gridH) / 2 - dot   // y of the top row
                for (i, color) in dotColors.enumerated() {
                    let col = i % cols
                    let row = i / cols
                    let x = dotsX + CGFloat(col) * (dot + dotGapH)
                    let y = topY - CGFloat(row) * (dot + dotGapV)
                    color.setFill()
                    NSBezierPath(ovalIn: NSRect(x: x, y: y, width: dot, height: dot)).fill()
                }
            }
            return true
        }
        img.isTemplate = false
        return img
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
