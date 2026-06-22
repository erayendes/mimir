import WidgetKit
import SwiftUI

// A 5-hour metric paired with its provider's logo, flattened across providers for the row/block
// layouts (Small/Medium/Large). XL keeps the per-provider grouping instead (see XLColumn).
private struct FlatMetric: Identifiable {
    let id = UUID()
    let iconName: String
    let metric: WindowMetric
}

private extension WidgetPayload {
    var available: [ProviderPayload] { providers.filter(\.isAvailable) }

    /// All 5-hour metrics across available providers, in display order (Claude, Codex, then
    /// Antigravity's Gemini + Claude/GPT). Drives Small/Medium/Large.
    var fiveHourFlat: [FlatMetric] {
        available.flatMap { p in p.fiveHour.map { FlatMetric(iconName: p.iconName, metric: $0) } }
    }
}

struct DetailedWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MimirEntry

    var body: some View {
        if let payload = entry.payload, !payload.available.isEmpty {
            switch family {
            case .systemSmall:      SmallView(metric: smallMetric(payload), now: entry.date)
            case .systemMedium:     MediumView(payload: payload, now: entry.date)
            case .systemLarge:      LargeView(payload: payload, now: entry.date)
            case .systemExtraLarge: ExtraLargeView(payload: payload, now: entry.date)
            default:                MediumView(payload: payload, now: entry.date)
            }
        } else {
            EmptyStateView()
        }
    }

    /// Small shows a single window: the one chosen in the widget config, else the most critical
    /// (lowest remaining) one as a sensible default.
    private func smallMetric(_ p: WidgetPayload) -> FlatMetric {
        if let label = entry.selectedLabel, let chosen = p.fiveHourFlat.first(where: { $0.metric.label == label }) {
            return chosen
        }
        return p.fiveHourFlat.min { $0.metric.percent < $1.metric.percent } ?? p.fiveHourFlat[0]
    }
}

// MARK: - Shared bits

/// The "mimir" wordmark + a small window/credit pill, used as the header of S/M.
private struct WordmarkHeader: View {
    var badge: String
    var body: some View {
        HStack {
            Text("mimir").font(.system(size: 11, weight: .medium)).tracking(-0.1).foregroundStyle(Tok.brand)
            Spacer()
            Pill(badge)
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

/// gauge + remaining (left) ·· clock + reset (right). Spec footer for S/L/XL.
private struct ResetFooter: View {
    let resetAt: Date?
    let now: Date
    var size: CGFloat = 10
    var color: Color = Tok.tertiary
    var body: some View {
        HStack(spacing: 0) {
            IconText(symbol: "gauge.with.needle", text: Reset.remaining(resetAt, now: now), size: size)
            Spacer(minLength: 6)
            IconText(symbol: "clock", text: Reset.clock(resetAt), size: size)
        }
        .foregroundStyle(color)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WordmarkHeader(badge: String(localized: "widget.window.fiveHour"))
            Spacer(minLength: 14)   // breathing room between header and the metric
            HStack(spacing: 6) {
                BrandMark(iconName: metric.iconName, size: 13)
                Text(metric.metric.label).font(.system(size: 12)).foregroundStyle(Tok.secondary).lineLimit(1)
            }
            Text("\(metric.metric.percent)%")
                .font(.system(size: 44, weight: .heavy)).tracking(-0.9)
                .foregroundStyle(statusColor(metric.metric.percent))
                .monospacedDigit()
                .padding(.top, 1)
            ProgressBar(percent: metric.metric.percent, height: 5).padding(.top, 7)
            ResetFooter(resetAt: metric.metric.resetAt, now: now, size: 9.5).padding(.top, 9)
        }
        .padding(15)
    }
}

// MARK: - Medium (338×158) — horizontal rows

private struct MediumView: View {
    let payload: WidgetPayload
    let now: Date
    var body: some View {
        VStack(spacing: 0) {
            WordmarkHeader(badge: String(localized: "widget.window.fiveHour"))
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
    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                BrandMark(iconName: item.iconName, size: 14)
                Text(item.metric.label).font(.system(size: 12)).foregroundStyle(Tok.secondary).lineLimit(1)
            }
            .frame(width: 84, alignment: .leading)
            ProgressBar(percent: item.metric.percent, height: 5)
            Text("\(item.metric.percent)%")
                .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                .foregroundStyle(statusColor(item.metric.percent))
                .frame(minWidth: 32, alignment: .trailing)
            Text(resetLine)
                .font(.system(size: 9)).monospacedDigit().foregroundStyle(Tok.tertiary)
                .frame(minWidth: 62, alignment: .trailing).lineLimit(1)
        }
    }
    private var resetLine: String {
        [Reset.remaining(item.metric.resetAt, now: now), Reset.clock(item.metric.resetAt)]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Large (338×354) — vertical blocks

private struct LargeView: View {
    let payload: WidgetPayload
    let now: Date
    var body: some View {
        VStack(spacing: 0) {
            WordmarkHeader(badge: String(localized: "widget.window.fiveHour"))
            Spacer(minLength: 0)
            VStack(spacing: 16) {
                ForEach(payload.fiveHourFlat.prefix(4)) { LargeBlock(item: $0, now: now) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 16)
    }
}

private struct LargeBlock: View {
    let item: FlatMetric
    let now: Date
    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                BrandMark(iconName: item.iconName, size: 18)
                Text(item.metric.label).font(.system(size: 15, weight: .semibold)).foregroundStyle(Tok.primary)
                Spacer()
                Text("\(item.metric.percent)%")
                    .font(.system(size: 22, weight: .bold)).monospacedDigit()
                    .foregroundStyle(statusColor(item.metric.percent))
            }
            ProgressBar(percent: item.metric.percent, height: 7)
            ResetFooter(resetAt: item.metric.resetAt, now: now, size: 11.5, color: .primary.opacity(0.45))
        }
    }
}

// MARK: - Extra Large (715×354) — three provider columns

private struct ExtraLargeView: View {
    let payload: WidgetPayload
    let now: Date
    var body: some View {
        // Outer padding == the gap between cards (14) so the frame around the columns is even.
        HStack(spacing: 14) {
            ForEach(payload.available, id: \.name) { XLColumn(provider: $0, now: now) }
        }
        .padding(14)
    }
}

private struct XLColumn: View {
    let provider: ProviderPayload
    let now: Date

    /// Each 5h window paired with its same-named 7d window, so a model's two windows sit together
    /// (Gemini 5s → Gemini 7g → Claude/GPT 5s → Claude/GPT 7g) rather than all 5h then all 7d.
    private var groups: [(five: WindowMetric, weekly: WindowMetric?)] {
        provider.fiveHour.map { f in (f, provider.sevenDay.first { $0.label == f.label }) }
    }
    /// 7d windows with no matching 5h window (e.g. Claude's "Sonnet") — listed after the groups.
    private var leftoverWeekly: [WindowMetric] {
        let fiveLabels = Set(provider.fiveHour.map(\.label))
        return provider.sevenDay.filter { !fiveLabels.contains($0.label) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: logo + name + credits.
            HStack(spacing: 8) {
                BrandMark(iconName: provider.iconName, size: 16)
                Text(provider.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Tok.primary)
                Spacer()
                if let credits = provider.credits {
                    Text(String(localized: "widget.label.credits")).font(.system(size: 9)).foregroundStyle(Tok.faint)
                    Text(credits).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(Tok.secondary)
                }
            }
            // Per-model groups: 5h block with its 7d row directly beneath; a divider between models.
            ForEach(Array(groups.enumerated()), id: \.offset) { idx, g in
                if idx > 0 { Rectangle().fill(Tok.divider).frame(height: 1) }
                VStack(alignment: .leading, spacing: 8) {
                    XLMainBlock(metric: g.five, now: now)
                    if let weekly = g.weekly { XLWeeklyRow(metric: weekly, now: now) }
                }
            }
            ForEach(leftoverWeekly, id: \.label) { XLWeeklyRow(metric: $0, now: now) }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Tok.inner).fill(Tok.innerCard))
    }
}

private struct XLMainBlock: View {
    let metric: WindowMetric
    let now: Date
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(metric.label).font(.system(size: 13, weight: .medium)).foregroundStyle(Tok.primary).lineLimit(1)
                Pill(String(localized: "widget.window.fiveHour"))
                Spacer()
                Text("\(metric.percent)%")
                    .font(.system(size: 19, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(statusColor(metric.percent))
            }
            ProgressBar(percent: metric.percent, height: 5)
            ResetFooter(resetAt: metric.resetAt, now: now, size: 10, color: Tok.tertiary)
        }
    }
}

private struct XLWeeklyRow: View {
    let metric: WindowMetric
    let now: Date
    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(statusColor(metric.percent)).frame(width: 6, height: 6)
                Text(metric.label).font(.system(size: 12)).foregroundStyle(Tok.secondary).lineLimit(1)
                Pill(String(localized: "widget.window.sevenDay"))
                Spacer()
                Text("\(metric.percent)%").font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(statusColor(metric.percent))
                if let r = Reset.remaining(metric.resetAt, now: now) {
                    Text(r).font(.system(size: 10)).monospacedDigit().foregroundStyle(Tok.tertiary)
                }
            }
            ProgressBar(percent: metric.percent, height: 5)
        }
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
