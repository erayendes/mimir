import WidgetKit
import SwiftUI

/// The 5-hour session window length — the reset fallback shown when a provider reports no `resetAt`
/// (Claude does this while its 5h window is inactive/full), so the row reads "5h" instead of blank.
private let fiveHourWindow: TimeInterval = 5 * 3600
/// The weekly window length — reset fallback for a metric that represents the weekly (7g) quota
/// (a service with no active 5h window, e.g. Codex since OpenAI's July 2026 removal).
private let weeklyWindow: TimeInterval = 7 * 24 * 3600

/// The pill text for a metric's window: "5h/5s" for the session, else the window's REAL length
/// ("7d", "30d" — OpenAI's Go plan uses a ~30-day window). Falls back to the plain weekly label
/// when the provider reports no length, rather than printing a guessed day count.
private func windowPill(_ m: WindowMetric) -> String {
    guard m.isWeekly else { return String(localized: "widget.window.fiveHour") }
    if let days = quotaWindowDays(m.windowSeconds) {
        return "\(days)\(String(localized: "duration.unit.day"))"
    }
    return String(localized: "widget.window.weekly")
}

/// The reset countdown fallback length matching a metric's window (its real length when known).
private func windowFallback(_ m: WindowMetric) -> TimeInterval {
    guard m.isWeekly else { return fiveHourWindow }
    return m.windowSeconds ?? weeklyWindow
}

// A 5-hour metric paired with its provider's logo, flattened across providers so Small can pick
// one to show.
private struct FlatMetric: Identifiable {
    let id = UUID()
    let iconName: String
    let providerName: String   // for the "{app} kapalı görünüyor" message
    let unavailable: Bool      // live source unreachable too long → render the empty state
    let isStale: Bool          // last-known reading → dim + tap-to-refresh (host renews the token)
    let metric: WindowMetric
}

private extension WidgetPayload {
    /// All 5-hour metrics across available providers, in display order (Claude, Codex, then
    /// Antigravity's Gemini + Claude/GPT). Small picks one out of this.
    var fiveHourFlat: [FlatMetric] {
        providers.filter(\.isAvailable)
            .flatMap { p in p.fiveHour.map { FlatMetric(iconName: p.iconName, providerName: p.name, unavailable: p.unavailable, isStale: p.isStale, metric: $0) } }
    }
}

/// Deep link the unavailable empty state taps into: `mimir://open?app=<provider>`. The host app
/// (MimirApp) handles the scheme and launches that provider's app via AppTarget — the widget
/// extension is sandboxed and can't launch another app itself.
private func widgetOpenURL(_ provider: String) -> URL? {
    let q = provider.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? provider
    return URL(string: "mimir://open?app=\(q)")
}

struct DetailedWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MimirEntry

    var body: some View {
        // Guard on fiveHourFlat (not just `available`): a provider can be available but carry no
        // 5h metric yet (e.g. right at launch before the first quota read). Empty → EmptyState,
        // never an out-of-range crash.
        if let payload = entry.payload, !payload.fiveHourFlat.isEmpty {
            if family == .systemMedium {
                MediumView(metric: smallMetric(payload), now: entry.date)
            } else {
                SmallView(metric: smallMetric(payload), now: entry.date)
            }
        } else {
            EmptyStateView()
        }
    }

    /// Small and Medium show a single model: the one chosen in the widget config, else the most
    /// critical (lowest remaining) one. Caller guarantees `fiveHourFlat` is non-empty.
    private func smallMetric(_ p: WidgetPayload) -> FlatMetric {
        if let label = entry.selectedLabel, let chosen = p.fiveHourFlat.first(where: { $0.metric.label == label }) {
            return chosen
        }
        return p.fiveHourFlat.min { $0.metric.percent < $1.metric.percent } ?? p.fiveHourFlat[0]
    }
}

// MARK: - Shared bits

private struct Pill: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Tok.brand)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Tok.badgeBg))
    }
}

private struct IconText: View {
    let symbol: String
    let text: String?
    var size: CGFloat
    var body: some View {
        if let text {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: size * 0.92)).imageScale(.small)
                Text(text).font(.system(size: size)).monospacedDigit()
            }
            .lineLimit(1)
            .fixedSize()   // never truncate the reset text ("2s 51d") — keep it whole
        }
    }
}

// MARK: - Small (158×158)

/// The Medium language on a square: the face washed from the left by the 5-hour remaining
/// percent, the number under the header with the reset clock and countdown beside it, and the
/// weekly capsule along the bottom with its reset row. A long-window-only service (Codex Go's
/// 30d) shows that window as the face with a pill in the header and no capsule.
private struct SmallView: View {
    let metric: FlatMetric
    let now: Date
    private var m: WindowMetric { metric.metric }
    private var weekly: (percent: Int, resetAt: Date?)? {
        guard !m.isWeekly, let w = m.weeklyPercent else { return nil }
        return (w, m.weeklyResetAt)
    }
    // A spent weekly quota locks the model: grey the face so a full session can't read as usable.
    private var faceColor: Color { weekly?.percent == 0 ? Tok.passive : statusColor(m.percent) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                FaceWash(color: faceColor, percent: m.percent, width: geo.size.width)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        BrandMark(iconName: metric.iconName, size: 14)
                        Text(m.label).font(.system(size: 13)).foregroundStyle(Tok.secondary).lineLimit(1)
                        if m.isWeekly { Pill(windowPill(m)) }
                    }
                    if metric.unavailable {
                        // Live source unreachable too long → an actionable "couldn't fetch" state (no number).
                        Spacer(minLength: 0)
                        Text(String(localized: "widget.unavailable.title"))
                            .font(.system(size: 15, weight: .medium)).foregroundStyle(Tok.secondary).lineLimit(1)
                        Text(String(format: String(localized: "widget.unavailable.app"), metric.providerName))
                            .font(.system(size: 12)).foregroundStyle(Tok.tertiary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true).padding(.top, 3)
                        Spacer(minLength: 0)
                        Rectangle().fill(Tok.track).frame(height: 0.5)
                        Text(String(localized: "widget.unavailable.action"))
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Tok.primary).padding(.top, 8)
                    } else {
                        Group {
                            Spacer(minLength: 0)
                            HStack(alignment: .top, spacing: 8) {
                                BigPercent(m.percent, size: 40, color: faceColor)
                                Spacer(minLength: 0)
                                ResetColumn(resetAt: m.resetAt, now: now, fallback: windowFallback(m), compact: true)
                            }
                            Spacer(minLength: 0)
                            if let weekly {
                                WeeklyBar(percent: weekly.percent, resetAt: weekly.resetAt, now: now, height: 18, compact: true)
                            }
                        }
                        .opacity(metric.isStale ? 0.55 : 1)
                    }
                }
                // Pinned to the face's width so an overlong row can't widen the column and push the
                // capsule and the reset info past the edge.
                .frame(width: geo.size.width - 32, alignment: .leading)
                .padding(16)
            }
        }
        // Unavailable → open the provider's app; stale → refresh in the host (Claude/Codex have no
        // app to open). Both go through the same `mimir://open` scheme; the host routes by provider.
        .widgetURL(metric.unavailable || metric.isStale ? widgetOpenURL(metric.providerName) : nil)
    }
}

// MARK: - Shared face pieces

/// The face wash: a light tint spanning that share of the width, edge to edge (the widget's own
/// mask rounds the corners). Solid at 0.22 went muddy against the face's grey.
private struct FaceWash: View {
    let color: Color
    let percent: Int
    let width: CGFloat
    var body: some View {
        Rectangle().fill(color.opacity(0.12))
            .frame(width: width * CGFloat(clampPct(percent)) / 100)
    }
}

/// Large digits with a smaller "%" sign, lifted so their cap top meets the top of an 11pt line
/// beside them and their baseline the second line's — the number spans clock-to-countdown.
/// Display caps at 99: a third digit overruns the Small row, and nobody acts differently on 100
/// versus 99. The data, the bar, and the notifications keep the real value.
private struct BigPercent: View {
    let percent: Int
    let size: CGFloat
    let color: Color
    init(_ percent: Int, size: CGFloat, color: Color) { self.percent = percent; self.size = size; self.color = color }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text("\(min(99, percent))").font(.system(size: size, weight: .light)).tracking(-0.5).monospacedDigit()
            Text("%").font(.system(size: size * 0.55, weight: .light))
        }
        .foregroundStyle(color)
        .fixedSize()
        .layoutPriority(1)
        .frame(height: 30, alignment: .top)
        .offset(y: -7)
    }
}

/// Reset clock over countdown, trailing-aligned.
private struct ResetColumn: View {
    let resetAt: Date?
    let now: Date
    let fallback: TimeInterval
    var compact = false
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            IconText(symbol: "clock", text: Reset.clock(resetAt, now: now, compact: compact), size: 11)
                .foregroundStyle(Tok.tertiary)
            IconText(symbol: "gauge.with.needle",
                     text: Reset.remaining(resetAt, now: now, fallbackWindow: fallback), size: 11)
                .foregroundStyle(Tok.tertiary)
        }
    }
}

/// The weekly capsule: track + fill, the percent on the fill (white in full colour; punched out in
/// the vibrant/accented modes, which flatten every colour to white), and the reset row underneath.
/// Too little fill to hold the label → just past the fill, in label colour.
private struct WeeklyBar: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    let percent: Int
    let resetAt: Date?
    let now: Date
    var height: CGFloat = 22
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let barW = max(height, geo.size.width * CGFloat(clampPct(percent)) / 100)
                let label = Text("\(min(99, percent))%").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                ZStack(alignment: .leading) {
                    Capsule().fill(Tok.track)
                    ZStack(alignment: .leading) {
                        Capsule().fill(statusColor(percent))
                        if barW >= 48 {
                            // Full colour: painted white, which reads on every status colour. The
                            // vibrant/accented modes flatten colours to white, so there the label is
                            // punched out instead (a hole shows the backdrop); the hole is too pale
                            // to read over a light face, hence not used in full colour.
                            if renderingMode == .fullColor {
                                label.foregroundStyle(.white.opacity(0.92)).padding(.leading, 10)
                            } else {
                                label.padding(.leading, 10).blendMode(.destinationOut)
                            }
                        }
                    }
                    .compositingGroup()
                    .frame(width: barW)
                    if barW < 48 { label.foregroundStyle(Tok.primary).padding(.leading, barW + 6) }
                }
            }
            .frame(height: height)
            HStack(spacing: compact ? 8 : 10) {
                IconText(symbol: "gauge.with.needle",
                         text: Reset.remaining(resetAt, now: now, fallbackWindow: weeklyWindow), size: 11)
                IconText(symbol: "clock", text: Reset.clock(resetAt, now: now, compact: compact), size: 11)
            }
            .foregroundStyle(Tok.tertiary)
            .padding(.horizontal, compact ? 2 : 6)
        }
    }
}

// MARK: - Medium (338×158)

/// One model, both windows, the widget itself as the gauge: the 5-hour remaining percent is a tint
/// that fills that share of the whole face from the left; its number and reset info sit fixed at
/// the top right. The weekly quota is a capsule bar below with its percent riding the fill and its
/// reset row underneath. No inner card — the face IS the session gauge. A service whose only
/// window is the long one (Codex) shows that window as the face, with no bar.
private struct MediumView: View {
    let metric: FlatMetric
    let now: Date
    private var m: WindowMetric { metric.metric }
    private var weekly: (percent: Int, resetAt: Date?)? {
        guard !m.isWeekly, let w = m.weeklyPercent else { return nil }
        return (w, m.weeklyResetAt)
    }
    // A spent weekly quota locks the model: grey the face so a full session can't read as usable.
    private var faceColor: Color { weekly?.percent == 0 ? Tok.passive : statusColor(m.percent) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                FaceWash(color: faceColor, percent: m.percent, width: geo.size.width)

                // Header and the top-right block share one row so the clock line's top sits on the
                // header's top; the number centres on the two info lines beside it.
                HStack(alignment: .top, spacing: 8) {
                    HStack(spacing: 6) {
                        BrandMark(iconName: metric.iconName, size: 14)
                        Text(m.label).font(.system(size: 13)).foregroundStyle(Tok.secondary).lineLimit(1)
                        // The face is the session by default; when a long window has taken its place
                        // (Codex Go's 30d), say so — otherwise the 5s needs no label.
                        if m.isWeekly { Pill(windowPill(m)) }
                    }
                    Spacer(minLength: 8)
                    if !metric.unavailable {
                        HStack(alignment: .top, spacing: 10) {
                            ResetColumn(resetAt: m.resetAt, now: now, fallback: windowFallback(m))
                            BigPercent(m.percent, size: 40, color: faceColor)
                        }
                        .opacity(metric.isStale ? 0.55 : 1)
                    }
                }
                .padding(16)

                if metric.unavailable {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "widget.unavailable.title"))
                            .font(.system(size: 15, weight: .medium)).foregroundStyle(Tok.secondary).lineLimit(1)
                        Text(String(format: String(localized: "widget.unavailable.app"), metric.providerName))
                            .font(.system(size: 12)).foregroundStyle(Tok.tertiary).lineLimit(1)
                        Text(String(localized: "widget.unavailable.action"))
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Tok.primary).padding(.top, 8)
                    }
                    .padding(16).padding(.top, 34)
                } else if let weekly {
                    WeeklyBar(percent: weekly.percent, resetAt: weekly.resetAt, now: now, height: 22)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(.bottom, 12)
                        .opacity(metric.isStale ? 0.55 : 1)
                }
            }
        }
        .widgetURL(metric.unavailable || metric.isStale ? widgetOpenURL(metric.providerName) : nil)
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("mimir").font(.system(size: 12, weight: .medium)).foregroundStyle(Tok.brand)
            Text(String(localized: "widget.empty")).font(.system(size: 11)).foregroundStyle(Tok.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
