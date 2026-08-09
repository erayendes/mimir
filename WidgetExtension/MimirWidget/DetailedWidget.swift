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

// A 5-hour metric paired with its provider's logo, flattened across providers for the Small
// (single metric) and Medium (one row per metric) layouts.
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
    /// Antigravity's Gemini + Claude/GPT). Drives Small and Medium.
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
        // 5h metric yet (e.g. right at launch before the first quota read). Both Small and Medium
        // need at least one metric — empty → EmptyState, never an out-of-range crash.
        if let payload = entry.payload, !payload.fiveHourFlat.isEmpty {
            switch family {
            case .systemSmall: SmallView(metric: smallMetric(payload), now: entry.date)
            default:           MediumView(payload: payload, now: entry.date)
            }
        } else {
            EmptyStateView()
        }
    }

    /// Small shows a single window: the one chosen in the widget config, else the most critical
    /// (lowest remaining) one. Caller guarantees `fiveHourFlat` is non-empty.
    private func smallMetric(_ p: WidgetPayload) -> FlatMetric {
        if let label = entry.selectedLabel, let chosen = p.fiveHourFlat.first(where: { $0.metric.label == label }) {
            return chosen
        }
        return p.fiveHourFlat.min { $0.metric.percent < $1.metric.percent } ?? p.fiveHourFlat[0]
    }
}

// MARK: - Shared bits

/// The "mimir" wordmark, used as the header of Medium. It carries no window badge: rows can mix
/// windows (Claude 5h + Codex weekly since the July 2026 5h removal), so a single badge would be
/// wrong — each row's reset line already says which window it is.
private struct WordmarkHeader: View {
    var body: some View {
        HStack {
            Text("mimir").font(.system(size: 11, weight: .medium)).tracking(-0.1).foregroundStyle(Tok.brand)
            Spacer()
        }
    }
}

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

/// gauge + remaining (left) ·· clock + reset (right). Spec footer for Small. When the provider gives
/// no reset (Claude's idle 5h window), the remaining falls back to the 5h window length and the clock
/// is simply omitted — there's no real time to show.
private struct ResetFooter: View {
    let resetAt: Date?
    let now: Date
    var size: CGFloat = 10
    var fallbackWindow: TimeInterval = fiveHourWindow
    var body: some View {
        HStack(spacing: 0) {
            IconText(symbol: "gauge.with.needle",
                     text: Reset.remaining(resetAt, now: now, fallbackWindow: fallbackWindow), size: size)
            Spacer(minLength: 6)
            IconText(symbol: "clock", text: Reset.clock(resetAt), size: size)
        }
        .foregroundStyle(Tok.tertiary)
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

private struct SmallView: View {
    let metric: FlatMetric
    let now: Date
    // A spent weekly quota locks the model: grey the number + bar so a full session can't read as
    // "usable" when the week is gone.
    private var weeklyExhausted: Bool { metric.metric.weeklyPercent == 0 }
    private var pct: Int { metric.metric.percent }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Model + 5s badge at the top (the clean original face; the "mimir" wordmark is dropped).
            HStack(spacing: 6) {
                BrandMark(iconName: metric.iconName, size: 14)
                Text(metric.metric.label).font(.system(size: 13)).foregroundStyle(Tok.secondary).lineLimit(1)
                Pill(windowPill(metric.metric))
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
                // Stale (last-known) → dim the figure; tapping the face refreshes (see widgetURL).
                Group {
                    Spacer(minLength: 0)
                    // Big percent at weather-widget scale: large digits with a smaller "%" sign for a
                    // cleaner figure. Greys to passive when the weekly quota is spent.
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(pct)").font(.system(size: 48, weight: .light)).tracking(-0.5).monospacedDigit()
                        Text("%").font(.system(size: 26, weight: .light))
                    }
                    .foregroundStyle(weeklyExhausted ? Tok.passive : statusColor(pct))
                    // Symmetric gaps: the number's font carries ~descender(48pt)≈10pt of slack below the
                    // digits, so a +2 here visually matches the footer's `.padding(.top, 10)` below the bar.
                    ProgressBar(percent: pct, height: 6, color: weeklyExhausted ? Tok.passive : nil).padding(.top, 2)
                    ResetFooter(resetAt: metric.metric.resetAt, now: now, size: 11,
                                fallbackWindow: windowFallback(metric.metric)).padding(.top, 10)
                }
                .opacity(metric.isStale ? 0.55 : 1)
            }
        }
        .padding(16)
        // Unavailable → open the provider's app; stale → refresh in the host (Claude/Codex have no
        // app to open). Both go through the same `mimir://open` scheme; the host routes by provider.
        .widgetURL(metric.unavailable || metric.isStale ? widgetOpenURL(metric.providerName) : nil)
    }
}

// MARK: - Medium (338×158) — horizontal rows

private struct MediumView: View {
    let payload: WidgetPayload
    let now: Date
    var body: some View {
        VStack(spacing: 0) {
            WordmarkHeader()
            Spacer(minLength: 12)   // keep the header off the first row
            VStack(spacing: 12) {
                ForEach(payload.fiveHourFlat.prefix(4)) { MediumRow(item: $0, now: now) }
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 14)
    }
}

private struct MediumRow: View {
    let item: FlatMetric
    let now: Date
    // Grey the row when its weekly quota is spent — same lockout rule as Small/the popover.
    private var exhausted: Bool { item.metric.weeklyPercent == 0 }
    var body: some View {
        // Unavailable rows deep-link to the provider's app; stale rows deep-link to refresh (host
        // routes by provider). Fresh rows aren't tappable — the whole widget already opens the host.
        if (item.unavailable || item.isStale), let url = widgetOpenURL(item.providerName) {
            Link(destination: url) { dimmedRow }
        } else {
            dimmedRow
        }
    }

    // Dim a stale (last-known) row so it reads as not-live; the unavailable row draws its own "—".
    private var dimmedRow: some View {
        row.opacity(item.isStale && !item.unavailable ? 0.55 : 1)
    }

    private var row: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                BrandMark(iconName: item.iconName, size: 14)
                Text(item.metric.label).font(.system(size: 12)).foregroundStyle(Tok.secondary).lineLimit(1)
            }
            // 92, not 84: the longest label ("Claude/GPT") plus its logo runs ~85pt at 12pt, so the
            // narrower column truncated it to "Claude/G…".
            .frame(width: 92, alignment: .leading)
            if item.unavailable {
                // Live source unreachable too long → empty track + "—" (Stocks "no data" language).
                Capsule().fill(Tok.track).frame(height: 5)
                Text("—").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Tok.tertiary).frame(minWidth: 32, alignment: .trailing)
                Text("—").font(.system(size: 9)).foregroundStyle(Tok.tertiary)
                    .frame(minWidth: 62, alignment: .trailing)
            } else {
                ProgressBar(percent: item.metric.percent, height: 5, color: exhausted ? Tok.passive : nil)
                Text("\(item.metric.percent)%")
                    .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(exhausted ? Tok.passive : statusColor(item.metric.percent))
                    .frame(minWidth: 32, alignment: .trailing)
                Text(resetLine)
                    .font(.system(size: 9)).monospacedDigit().foregroundStyle(Tok.tertiary)
                    .frame(minWidth: 62, alignment: .trailing).lineLimit(1)
                    .fixedSize()   // never truncate the reset text ("6g 20s · 08:50") — same rule as Small
            }
        }
    }
    private var resetLine: String {
        [Reset.remaining(item.metric.resetAt, now: now, fallbackWindow: windowFallback(item.metric)), Reset.clock(item.metric.resetAt)]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Empty

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
