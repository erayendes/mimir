import AppKit
import Combine
import SwiftUI

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 500)
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(store: store) { [weak self] in
                self?.closePopover(nil)
            }
        )

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item

        store.refresh()
        refreshStatusTitle()
        store.$services
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
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
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }

        if popover.isShown {
            closePopover(sender)
        } else {
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
        statusItem?.button?.title = ""
        
        // SF Symbol ikonunu kullan (m.circle.fill)
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        if let image = NSImage(systemSymbolName: "m.circle.fill", accessibilityDescription: "Mimir")?
            .withSymbolConfiguration(config) {
            image.isTemplate = true
            statusItem?.button?.image = image
        }
        
        statusItem?.button?.imagePosition = .imageOnly
        statusItem?.button?.toolTip = store.services.isEmpty ? "Loading..." : store.services.map(\.name).joined(separator: " | ")
    }
}

private struct PopoverView: View {
    @ObservedObject var store: UsageStore
    let onDismiss: () -> Void

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
                    .padding(.top, PopoverMetrics.edgeInset * 1.1)
                    .padding(.bottom, PopoverMetrics.edgeInset)
                    .padding(.horizontal, PopoverMetrics.edgeInset)
                }

                EdgeFadeOverlay(edge: .top)
                    .allowsHitTesting(false)

                EdgeFadeOverlay(edge: .bottom)
                    .allowsHitTesting(false)
            }
        }
    }
}

private enum PopoverMetrics {
    static let edgeInset: CGFloat = 15
    static let fadeHeight: CGFloat = 58
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

            if usesLimitRows {
                VStack(alignment: .leading, spacing: 10) {
                    limitRows
                }
            } else {
                LabelRow(title: "Session", value: limitValue(percent: service.sessionUsagePercent, resetAt: service.sessionResetAt))
                LabelRow(title: "Weekly", value: limitValue(percent: service.weeklyUsagePercent, resetAt: service.weeklyResetAt))
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
        if service.name == "Claude" || service.name == "Codex" {
            LimitMetricRow(title: "Session", percent: service.sessionUsagePercent, resetAt: service.sessionResetAt, now: now)
            LimitMetricRow(title: "Weekly", percent: service.weeklyUsagePercent, resetAt: service.weeklyResetAt, now: now)
        }

        ForEach(service.models) { model in
            LimitMetricRow(
                title: model.name,
                percent: model.valueText == nil ? model.usagePercent : nil,
                resetAt: model.resetAt,
                valueText: model.valueText,
                now: now
            )
        }
    }

    private var usesLimitRows: Bool {
        true
    }

    private func limitValue(percent: Int?, resetAt: Date?) -> String {
        let clampedPercent = percent.map { max(0, min(100, $0)) }
        let resetText = resetAt.map { TimeFormatter.duration(from: $0.timeIntervalSince(now)) }

        switch (clampedPercent, resetText) {
        case let (percent?, reset?):
            return "%\(percent) (\(reset))"
        case let (percent?, nil):
            return "%\(percent)"
        case let (nil, reset?):
            return reset
        case (nil, nil):
            return "n/a"
        }
    }
}

private struct LimitMetricRow: View {
    let title: String
    let percent: Int?
    let resetAt: Date?
    var valueText: String?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .medium, design: .default))
                    .foregroundStyle(Color.primary.opacity(0.80))
                    .lineLimit(1)

                Spacer(minLength: 8)

                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(primaryValue)
                        .font(.system(size: 14, weight: .medium, design: .default))
                        .monospacedDigit()
                        .foregroundStyle(valueColor)

                    if let resetValue {
                        Text(resetValue)
                            .font(.system(size: 12, weight: .regular, design: .default))
                            .monospacedDigit()
                            .foregroundStyle(Color.secondary.opacity(0.66))
                    }
                }
            }

            if let percent {
                LineGauge(percent: percent, tint: metricTint)
            }
        }
        .padding(.vertical, 1)
    }

    private var primaryValue: String {
        if let valueText {
            return valueText
        }

        if let percent {
            return "%\(max(0, min(100, percent)))"
        }

        return "n/a"
    }

    private var resetValue: String? {
        resetAt.map { TimeFormatter.duration(from: $0.timeIntervalSince(now)) }
    }

    private var valueColor: Color {
        guard percent != nil else {
            return Color.primary.opacity(0.82)
        }

        return metricTint.opacity(0.90)
    }

    private var metricTint: Color {
        guard let percent else {
            return Color.primary.opacity(0.58)
        }

        switch max(0, min(100, percent)) {
        case 0...25:
            return Color(nsColor: .systemRed)
        case 26...60:
            return Color(nsColor: .systemYellow)
        default:
            return Color(nsColor: .systemGreen)
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

private struct LabelRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.system(size: 12))
    }
}
