import AppKit
import Combine
import MimirShared
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
    /// Sleep/wake poll guard (see `WakeScheduling`): when the last poll ran, and when the
    /// repeating timer was due to fire next — a fire far past that means the machine slept.
    private var lastPoll: Date?
    private var nextExpectedFire: Date?
    private var wakeRefresh: DispatchWorkItem?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []
    private var updaterController: SPUStandardUpdaterController?
    // Per-window notification state lives in UserDefaults (see `notifState`), keyed
    // "<service>-5h" / "<service>-weekly" — a relaunch must not re-fire an alert already sent.
    private var iconSource: NSImage?
    private var refreshCount = 0              // refreshes seen this session (for the provider signal)
    private var sentProviderSignal = false   // provider.active is emitted once per session

    /// Handle `mimir://open?app=<provider>` — the deep link the data-unavailable widget/banner taps
    /// into. The widget extension is sandboxed and can't launch another app, so it hands the URL to
    /// this host, which opens the provider's app via `AppTarget`.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "mimir" && url.host == "open" {
            guard let app = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "app" })?.value else { continue }
            switch DeepLink.action(forApp: app) {
            case .openProvider(let provider):
                AppTarget.open(provider)
            case .openSelfAndRefresh:
                // A stale Claude/Codex widget was tapped: open our panel with a user-initiated
                // refresh — the only path allowed to read Claude Code's keychain and renew the token.
                // Force the resulting payload write to reload the widget at once, so the tapped widget
                // visibly refreshes even if the numbers come back unchanged.
                WidgetBridge.forceReloadOnNextUpdate()
                openPanelUserInitiated()
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let shot = ProcessInfo.processInfo.environment["MIMIR_DEMO_SHOT"] {
            DemoShot.render(to: shot)
            NSApp.terminate(nil)
            return
        }
        #endif
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
                // We poll third-party usage APIs (chatgpt.com, claude.ai) every minute;
                // their transient 5xx are expected and handled by the next poll's retry.
                // Sentry's auto HTTP-failure capture turned every one into an error
                // (MIMIR-3: 885 events of a 503 from chatgpt.com/backend-api/wham/usage).
                options.enableCaptureFailedRequests = false
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

        Telemetry.signal("app.launched")

        poll()
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
                WidgetBridge.update(services)
                self?.noteRefreshForTelemetry(services)
            }
            .store(in: &cancellables)
        nextExpectedFire = Date().addingTimeInterval(Self.pollInterval)
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = Date()
                let expected = self.nextExpectedFire
                self.nextExpectedFire = now.addingTimeInterval(Self.pollInterval)
                // The run loop delivers one immediate catch-up fire on wake. Polling then races the
                // half-up network and a token that expired mid-sleep, so skip it — the wake observer
                // schedules the real refresh after its grace delay.
                guard !WakeScheduling.isOverdueFire(now: now, expected: expected) else { return }
                self.poll()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleWakeRefresh() }
        }

        // Rewrite the statusLine hook script from current code when it's wired, so app upgrades take
        // effect (cheap; touches no settings).
        MimirStatusLineHook.refreshScript()

        maybePromptLaunchAtLogin()
        maybeOfferClaudeHook()
    }

    // MARK: - Prompt-free Claude offer

    private static let didOfferClaudeHookKey = "didOfferClaudeHook"

    /// Once, offer to enable prompt-free Claude tracking so Claude's usage updates without the macOS
    /// keychain prompt. Skipped when already wired. Deferred and guarded so it never stacks on the
    /// launch-at-login prompt — if a modal is up, we skip silently (the menu toggle still offers it).
    private func maybeOfferClaudeHook() {
        guard !UserDefaults.standard.bool(forKey: Self.didOfferClaudeHookKey) else { return }
        if MimirStatusLineHook.isWired() {
            UserDefaults.standard.set(true, forKey: Self.didOfferClaudeHookKey)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            Task { @MainActor in
                guard NSApp.modalWindow == nil else { return }   // don't stack on another prompt
                UserDefaults.standard.set(true, forKey: Self.didOfferClaudeHookKey)
                self?.presentClaudeHookOffer()
            }
        }
    }

    private func presentClaudeHookOffer() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Track Claude without the keychain prompt?")
        alert.informativeText = String(localized: "Mimir can read Claude Code's own usage through a small status-line hook — no keychain permission prompt. It preserves any status line you already use and can be turned off anytime from Mimir's menu.")
        alert.addButton(withTitle: String(localized: "Enable"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            toggleClaudeHook()
        }
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

        // Prompt-free Claude: a statusLine hook lets Mimir read Claude Code's own usage without ever
        // touching the keychain (no macOS permission prompt). Checkbox reflects whether it's wired.
        let hook = NSMenuItem(title: String(localized: "Prompt-free Claude tracking"),
                              action: #selector(toggleClaudeHook), keyEquivalent: "")
        hook.target = self
        hook.state = MimirStatusLineHook.isWired() ? .on : .off
        menu.addItem(hook)
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

    /// Toggle the prompt-free Claude statusLine hook. Enabling chains any existing statusLine and
    /// modifies ~/.claude/settings.json, so it's a deliberate user action here; disabling restores it.
    /// After wiring, kick a refresh so Claude's card can pick up the hook file on the next tick.
    @objc private func toggleClaudeHook() {
        let outcome = MimirStatusLineHook.isWired()
            ? MimirStatusLineHook.disable()
            : MimirStatusLineHook.enable()
        switch outcome {
        case .failed(let why):
            let alert = NSAlert()
            alert.messageText = String(localized: "Couldn't update Claude tracking")
            alert.informativeText = why
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        case .enabled, .chained, .alreadyOn:
            Telemetry.signal("claudeHook.enabled")
            store.refresh(userInitiated: true)
        case .disabled:
            Telemetry.signal("claudeHook.disabled")
            store.refresh()
        }
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
        for name in Telemetry.activeProviderNames(from: services) {
            Telemetry.signal("provider.active", parameters: ["service": name])
        }
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
            openPanelUserInitiated()
        }
    }

    /// Show the panel with a user-initiated refresh. Opening the panel is a deliberate user action,
    /// so this refresh is allowed to read Claude Code's keychain item if needed (the only path that
    /// can prompt); the 60s background timer and the launch refresh stay prompt-free. Shared by the
    /// menu-bar click and the stale-widget deep link.
    private func openPanelUserInitiated() {
        Telemetry.signal("popover.opened")
        store.refresh(userInitiated: true)
        refreshStatusTitle()
        showPanel()
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

    static let pollInterval: TimeInterval = 60

    private func poll() {
        lastPoll = Date()
        store.refresh()
        refreshStatusTitle()
    }

    /// On wake, hold the first poll for `graceDelay` and only run it if the data is actually
    /// stale — a short nap needs no off-schedule refresh.
    private func scheduleWakeRefresh() {
        wakeRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard WakeScheduling.shouldRefreshAfterWake(lastPoll: self.lastPoll, now: Date(),
                                                            pollInterval: Self.pollInterval) else { return }
                self.poll()
            }
        }
        wakeRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + WakeScheduling.graceDelay, execute: work)
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
        menuBarDots(from: store.services, dismissed: store.dismissedUnavailable).map { dot in
            // Data unavailable (source down too long) or 7g spent → grey lockout, matching the
            // widget/popover; else the 5h status colour, or the neutral grey with no 5h reading yet.
            if dot.unavailable || dot.weeklyExhausted { return Self.noDataDotColor }
            return dot.sessionPercent.map(statusNSColor) ?? Self.noDataDotColor
        }
    }

    /// Neutral grey dot, reused for two inactive states: a visible service whose 5-hour reading is
    /// missing ("no data yet"), and a model whose weekly (7g) quota is spent (the lockout grey, see
    /// `menuBarDotColors`). Appearance-aware (resolved at `setFill` time inside the menu-bar draw
    /// pass): a darker grey on the light menu bar, a lighter grey on the dark one, so it stays legible
    /// either way — unlike the saturated status colours, a single fixed grey washes out against one
    /// of the two backgrounds.
    private static let noDataDotColor = NSColor(name: "mimirNoData") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(hex: 0x9A9AA0)   // lighter grey for the dark menu bar
            : NSColor(hex: 0x6E6E73)   // darker grey for the light menu bar
    }

    private func statusNSColor(_ percent: Int) -> NSColor {
        switch max(0, min(100, percent)) {
        case 40...100: return NSColor(hex: 0x3FB984)  // green
        case 10..<40:  return NSColor(hex: 0xE0A93C)  // amber
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
        var lowThreshold: Int { 10 }
    }

    private func checkNotifications() {
        // Only the account-level 5h + weekly windows of genuinely LIVE services notify here. The
        // `!isStale` guard is load-bearing: a card served from a snapshot / a refilled estimate is
        // `isStale`, so a low alert is never raised off an inferred number. Refills fire off the
        // window's reset clock (see `fireRefillIfDue`), so a reading flickering back to 100 can't
        // announce one. Antigravity is excluded by name (no service-level windows; per-group rows).
        for service in store.services where service.isAvailable && !service.isStale && service.name != "Antigravity" {
            evaluateWindow(service: service, window: .fiveHour,
                           percent: service.sessionRemainingPercent, resetAt: service.sessionResetAt)
            evaluateWindow(service: service, window: .weekly,
                           percent: service.weeklyRemainingPercent, resetAt: service.weeklyResetAt,
                           windowSeconds: service.weeklyWindowSeconds)
        }
        checkAntigravityWeeklyRefill()
        checkResetCreditExpiry()
    }

    /// A reset credit lapses unused if it isn't spent, and it's worth most on a window that's spent
    /// but not about to reset on its own — so warn while there's still time to use one: 1 day, 5 hours
    /// and 1 hour before the FIRST credit expires. The last-fired stamp pins the expiry it belongs to,
    /// so a newly granted credit starts a fresh set of three and a relaunch doesn't re-fire the same one.
    private func checkResetCreditExpiry() {
        let rows = store.services
            .filter { $0.isAvailable && !$0.isStale }
            .flatMap(\.models)
            .filter { $0.valueText != nil && $0.resetAt != nil }
        guard let expiresAt = rows.compactMap(\.resetAt).min() else { return }

        let remaining = expiresAt.timeIntervalSinceNow
        guard remaining > 0,
              let threshold = Self.resetCreditThresholds.first(where: { remaining <= $0 }) else { return }

        let stamp = "\(Int(expiresAt.timeIntervalSince1970))-\(Int(threshold))"
        guard UserDefaults.standard.string(forKey: Self.resetCreditNotifiedKey) != stamp else { return }
        UserDefaults.standard.set(stamp, forKey: Self.resetCreditNotifiedKey)

        sendNotification(
            identifier: "Codex-resetcredit-\(Int(threshold))",
            title: String(format: String(localized: "⏳ Reset credit expires in %@"),
                          TimeFormatter.duration(from: remaining)),
            body: String(format: String(localized: "You have %@ waiting. Spend one now and it clears a used-up window — unused, it just lapses."),
                         String(rows.count))
        )
    }

    /// Ascending, so `first(where:)` picks the tightest bracket the countdown has entered.
    private static let resetCreditThresholds: [TimeInterval] = [3_600, 5 * 3_600, 86_400]
    private static let resetCreditNotifiedKey = "codexResetCreditNotified"

    /// HH:mm for the 5-hour low notification's reset clock.
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    // MARK: - Persisted per-window notification state

    /// One `UserDefaults` number per field, namespaced by the window key ("Codex-weekly.armed").
    /// Fields: `armed` (the reset we're waiting to announce), `announced` (the one already announced),
    /// `low` (the reset whose low alert already went out), `depleted` (1 once the window was really
    /// run down). Kept on disk because these alerts are once-per-window, not once-per-launch: in
    /// memory, every relaunch re-sent the same "running out" notice.
    private func notifState(_ key: String, _ field: String) -> Double {
        UserDefaults.standard.double(forKey: "notif.\(key).\(field)")
    }

    private func setNotifState(_ key: String, _ field: String, _ value: Double) {
        UserDefaults.standard.set(value, forKey: "notif.\(key).\(field)")
    }

    /// Announce a refill when the armed reset has passed, then disarm so the next one can arm cleanly.
    /// `requireDepleted` is false only for Antigravity, whose usage can't be observed while its IDE is
    /// closed — there the reset clock is all we have.
    private func fireRefillIfDue(key: String, bucket: String, requireDepleted: Bool,
                                 title: String, body: String) {
        let armed = notifState(key, "armed")
        guard refillIsDue(armed: armed, announced: notifState(key, "announced"),
                          now: Date().timeIntervalSince1970) else { return }
        if !requireDepleted || notifState(key, "depleted") == 1 {
            sendNotification(identifier: "\(key)-refilled", window: bucket, title: title, body: body)
        }
        setNotifState(key, "announced", armed)
        setNotifState(key, "depleted", 0)
        setNotifState(key, "armed", 0)
    }

    private func armNextReset(key: String, resetAt: Date?) {
        guard let stamp = nextArmedReset(armed: notifState(key, "armed"),
                                         announced: notifState(key, "announced"),
                                         resetAt: resetAt, now: Date()) else { return }
        setNotifState(key, "armed", stamp)
    }

    /// Antigravity's one reliable notification: the weekly quota refill. Its weekly reset time is
    /// deterministic and known in advance, and the quota can't be spent while the IDE is closed —
    /// so once we've seen the reset time, we can fire "refilled" exactly when it passes, with no
    /// live data. (Low / 5h alerts stay off: those depend on usage we can't observe reliably.)
    private func checkAntigravityWeeklyRefill() {
        let key = "Antigravity-weekly"
        fireRefillIfDue(
            key: key, bucket: "weekly", requireDepleted: false,
            title: String(format: String(localized: "🚀 %@ weekly quota refilled."), "Antigravity"),
            body: String(localized: "Your weekly quota is back to 100%. Pick up where you left off.")
        )

        guard let antigravity = store.services.first(where: { $0.name == "Antigravity" }) else { return }
        // Both weekly buckets share one reset time → take the earliest still ahead of us.
        armNextReset(key: key, resetAt: antigravity.models
            .filter { $0.window == .weekly }
            .compactMap(\.resetAt)
            .filter { $0 > Date() }
            .min())
    }

    private func evaluateWindow(service: ServiceStatus, window: QuotaWindow, percent: Int?, resetAt: Date?,
                                windowSeconds: TimeInterval? = nil) {
        guard let percent else { return }
        let key = "\(service.name)-\(window.suffix)"
        // A window longer than a week is the ChatGPT Go monthly quota, not a weekly one — say so, and
        // report it as its own telemetry bucket rather than folding it into "weekly".
        let isMonthly = window == .weekly && (windowSeconds ?? 0) > 8 * 86_400
        let bucket = isMonthly ? "monthly" : window.suffix
        // The 5h window keeps its flat 20%; a longer one scales its threshold by length (see
        // `lowQuotaThreshold`) so a 30-day quota doesn't warn on day three.
        let lowThreshold = window == .fiveHour
            ? window.lowThreshold
            : lowQuotaThreshold(windowSeconds: windowSeconds, base: window.lowThreshold)

        // A refill notice is only meaningful on a window that was actually run down first: spent for
        // the 5h one, below its low threshold for the longer one.
        if percent < (window == .fiveHour ? 1 : lowThreshold) {
            setNotifState(key, "depleted", 1)
        }

        // Refill: the window's reset came round. Fires once per reset, on the clock rather than on the
        // percent — a reading flickering back to 100 is not a reset.
        switch window {
        case .fiveHour:
            fireRefillIfDue(
                key: key, bucket: bucket, requireDepleted: true,
                title: String(format: String(localized: "🔋 %@ ready for a new sprint."), service.name),
                body: String(localized: "Your 5-hour session is back to 100%. Pick up where you left off.")
            )
        case .weekly:
            fireRefillIfDue(
                key: key, bucket: bucket, requireDepleted: true,
                title: String(format: isMonthly
                              ? String(localized: "🚀 %@ monthly quota refilled.")
                              : String(localized: "🚀 %@ weekly quota refilled."), service.name),
                body: isMonthly
                    ? String(localized: "Your monthly quota is back to 100%. Pick up where you left off.")
                    : String(localized: "Your weekly quota is back to 100%. Pick up where you left off.")
            )
        }
        armNextReset(key: key, resetAt: resetAt)

        // Low: crossed below the threshold. Warn once per window — the stored stamp is the reset the
        // warning belongs to, so the next window warns again and a relaunch inside this one doesn't.
        // A service that reports no reset at all stores 0 and so warns only once, until one appears.
        let lowKey = "notif.\(key).low"
        let resetStamp = resetAt?.timeIntervalSince1970 ?? 0
        guard percent < lowThreshold,
              UserDefaults.standard.object(forKey: lowKey) as? Double != resetStamp else { return }
        UserDefaults.standard.set(resetStamp, forKey: lowKey)

        let duration = resetAt.map { TimeFormatter.duration(from: $0.timeIntervalSinceNow) }
        switch window {
        case .fiveHour:
            // 5h includes the reset clock (it's today) plus the countdown.
            let body: String
            if let resetAt, let duration {
                body = String(format: String(localized: "Resets at %@. ~%@ to go."),
                              Self.clockFormatter.string(from: resetAt), duration)
            } else {
                body = String(localized: "Your 5-hour limit is running out.")
            }
            sendNotification(
                identifier: key,
                window: bucket,
                title: String(format: String(localized: "🪫 %@ 5-hour quota running out — %d%%"), service.name, percent),
                body: body
            )
        case .weekly:
            // Weekly/monthly is days out, so just the countdown (no clock).
            let body = duration.map { String(format: String(localized: "Renews in ~%@."), $0) }
                ?? (isMonthly ? String(localized: "Your monthly limit is running out.")
                              : String(localized: "Your weekly limit is running out."))
            sendNotification(
                identifier: key,
                window: bucket,
                title: String(format: isMonthly
                              ? String(localized: "🚨 %@ monthly quota running out — %d%%")
                              : String(localized: "🚨 %@ weekly quota running out — %d%%"), service.name, percent),
                body: body
            )
        }
    }

    private func sendNotification(identifier: String, window: String? = nil, title: String, body: String) {
        // Derive a categorical type from the identifier: "Claude-5h", "Codex-weekly-refilled", etc.
        let parts = identifier.split(separator: "-")
        let service = parts.first.map(String.init) ?? "unknown"
        let isRefill = identifier.hasSuffix("-refilled")
        let window = window ?? (identifier.contains("weekly") ? "weekly" : "5h")
        let kind = identifier.contains("resetcredit") ? "resetcredit" : (isRefill ? "refilled" : "low")
        Telemetry.signal("notification.sent", parameters: [
            "service": service, "window": window, "kind": kind
        ])

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
