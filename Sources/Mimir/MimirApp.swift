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
    private var lowQuotaNotified: Set<String> = []
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

        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                try? await center.requestAuthorization(options: [.alert, .sound])
            }
        }

        popover.behavior = .transient
        let hosting = NSHostingController(
            rootView: PopoverView(store: store) { [weak self] in
                self?.closePopover(nil)
            }
        )
        hosting.sizingOptions = .preferredContentSize
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

    private func checkNotifications() {
        for service in store.services {
            let checks: [(key: String, label: String, percent: Int?)] =
                [("\(service.name)-session", "5h Session", service.sessionRemainingPercent),
                 ("\(service.name)-weekly", "Weekly", service.weeklyRemainingPercent)]
                + service.models.map { ("\(service.name)-\($0.name)", $0.name, Optional($0.remainingPercent)) }

            for check in checks {
                guard let percent = check.percent else { continue }

                if percent < 20, !lowQuotaNotified.contains(check.key) {
                    sendNotification(
                        identifier: check.key,
                        title: "⚠️ \(service.name) \(check.label)",
                        body: "\(percent)% left"
                    )
                    lowQuotaNotified.insert(check.key)
                } else if percent >= 80, lowQuotaNotified.contains(check.key) {
                    sendNotification(
                        identifier: "\(check.key)-refilled",
                        title: "✅ \(service.name) \(check.label)",
                        body: "Refilled — \(percent)% available"
                    )
                    lowQuotaNotified.remove(check.key)
                }
            }
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
    @State private var contentHeight: CGFloat = PopoverMetrics.maxHeight

    private var needsScrolling: Bool {
        contentHeight > PopoverMetrics.maxHeight
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ZStack {
                PopoverBackdrop()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: PopoverMetrics.edgeInset) {
                        ForEach(store.services) { service in
                            ServiceCard(service: service, now: context.date)
                        }
                    }
                    .padding(.top, PopoverMetrics.edgeInset + 10)
                    .padding(.bottom, PopoverMetrics.edgeInset + 10)
                    .padding(.horizontal, PopoverMetrics.edgeInset)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: PopoverContentHeightKey.self, value: proxy.size.height)
                        }
                    }
                }

                if needsScrolling {
                    EdgeFadeOverlay(edge: .top)
                        .allowsHitTesting(false)

                    EdgeFadeOverlay(edge: .bottom)
                        .allowsHitTesting(false)
                }
            }
        }
        .onPreferenceChange(PopoverContentHeightKey.self) { contentHeight = $0 }
        .frame(width: PopoverMetrics.width)
        .frame(height: min(contentHeight, PopoverMetrics.maxHeight))
    }
}

private struct PopoverContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = PopoverMetrics.maxHeight

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private enum PopoverMetrics {
    static let edgeInset: CGFloat = 15
    static let fadeHeight: CGFloat = 58
    static let width: CGFloat = 360
    static let maxHeight: CGFloat = 500
}

private struct EdgeFadeOverlay: View {
    enum Edge {
        case top
        case bottom
    }

    let edge: Edge

    var body: some View {
        VStack {
            if edge == .bottom {
                Spacer()
            }

            Rectangle()
                .fill(.ultraThinMaterial)
                .frame(height: PopoverMetrics.fadeHeight)
                .mask(
                    LinearGradient(
                        colors: gradientStops,
                        startPoint: edge == .top ? .top : .bottom,
                        endPoint: edge == .top ? .bottom : .top
                    )
                )

            if edge == .top {
                Spacer()
            }
        }
        .ignoresSafeArea(edges: edge == .top ? .top : .bottom)
    }

    private var gradientStops: [Color] {
        [
            Color.black,
            Color.black.opacity(0.55),
            Color.clear
        ]
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                BrandIconView(iconName: service.iconName, size: 18)
                    .frame(width: 18)

                Text(service.name)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .tracking(0.05)
                    .foregroundStyle(Color.primary.opacity(0.86))

                if !service.isAvailable {
                    Text(service.statusNote ?? "unavailable")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(Color.secondary.opacity(0.72))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
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
