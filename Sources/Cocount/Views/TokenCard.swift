import CocountCore
import SwiftUI

struct TokenCard: View {
    @Environment(\.cocountTheme) private var theme
    let usage: TokenUsage?
    let issue: String?
    let now: Date
    let todayEstimate: TodayTokenEstimate?
    var synchronized = false
    private var estimateScope: String { synchronized ? "동기화된 기기의 Codex 기록" : "이 Mac의 로컬 Codex 기록" }
    @Binding var mode: UsageCardMode
    @State private var isHovered = false

    private var yesterdayTokens: Int64? {
        Calendar.current.date(byAdding: .day, value: -1, to: now).flatMap { usage?.tokens(on: $0) }
    }

    private var days: [Date] {
        (-6...0).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: now) }
    }
    private func chartTokens(on day: Date) -> Int64? {
        Calendar.current.isDate(day, inSameDayAs: now)
            ? todayEstimate?.value(on: now)
            : usage?.tokens(on: day)
    }

    private func chartLabel(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f억", Double(value) / 100_000_000)
    }

    private func dateLabel(_ day: Date) -> String {
        let components = Calendar.current.dateComponents([.month, .day], from: day)
        return "\(components.month ?? 0)/\(components.day ?? 0)"
    }

    var body: some View {
        Card(verticalPadding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                UsageCardHeader(mode: $mode)
                HStack(alignment: .center, spacing: 12) {
                    HStack(alignment: .top, spacing: 8) {
                        todayMetric
                        Rectangle().fill(theme.border).frame(width: 1, height: 32)
                        yesterdayMetric
                    }
                    .frame(width: Theme.metricWidth)
                    activityChart
                }
                DailyTokenChart(estimate: todayEstimate, now: now)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.radius))
        .onHover { isHovered = $0 }
        .help(issue ?? "이전 날짜: 서버 일별 집계 · 오늘: 로컬 기록 기반 추정 · — 미집계")
    }

    private var todayMetric: some View {
        let value = todayEstimate?.value(on: now)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("오늘").font(.system(size: 11)).foregroundStyle(theme.muted)
                Text("추정 토큰").font(.system(size: 9, weight: .medium)).foregroundStyle(theme.accent)
            }
            Text(UsageFormatting.tokens(value))
                .font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(theme.accent)
            Text(TodayTokenEstimate.comparison(today: value, yesterday: yesterdayTokens))
                .font(.system(size: 9)).monospacedDigit().foregroundStyle(theme.muted)
                .lineLimit(1).minimumScaleFactor(0.9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("오늘: \(estimateScope) 기반 추정 \(value?.formatted() ?? "미집계") 토큰. 어제 대비 = 오늘 추정 ÷ 어제 서버 집계 × 100. 두 집계의 범위·시간대가 다를 수 있어요.\(todayEstimate?.isPartial == true ? " 일부 기록이 없거나 다른 기기의 최신 기록이 아직 도착하지 않았을 수 있어요." : "")")
    }

    private var activityChart: some View {
        let values = days.map { (day: $0, tokens: chartTokens(on: $0)) }
        let maximum = max(1, Double(values.compactMap(\.tokens).max() ?? 0))
        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(values, id: \.day) { item in
                let day = item.day
                let value = item.tokens
                let today = Calendar.current.isDate(day, inSameDayAs: now)
                UsageDayBar(day: day, dateLabel: dateLabel(day), value: value.map(Double.init),
                            maximum: maximum, valueLabel: chartLabel(value),
                            isToday: today, isHovered: isHovered)
                .help("\(day.formatted(date: .abbreviated, time: .omitted)): \(value.map { $0.formatted() + " 토큰" } ?? "미집계")\(today ? " · 로컬 기록 기반 추정" : " · 서버 집계")")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(day.formatted(date: .abbreviated, time: .omitted)) \(today ? "추정 " : "")\(UsageFormatting.tokens(value)) 토큰")
            }
        }
    }

    private var yesterdayMetric: some View {
        let value = yesterdayTokens
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("어제").font(.system(size: 11))
                Text("토큰").font(.system(size: 9))
            }
            .foregroundStyle(theme.muted)
            Text(UsageFormatting.tokens(value))
                .font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(theme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(value?.formatted() ?? "미집계")
    }
}
