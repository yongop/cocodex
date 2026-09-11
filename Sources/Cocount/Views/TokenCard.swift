import CocountCore
import SwiftUI

struct TokenCard: View {
    @Environment(\.cocountTheme) private var theme
    let usage: TokenUsage?
    let issue: String?
    let now: Date
    let todayEstimate: TodayTokenEstimate?
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

    private var maximum: Double { max(1, Double(days.compactMap { chartTokens(on: $0) }.max() ?? 0)) }

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
                        metric("어제", value: yesterdayTokens, prominent: false)
                    }
                    .frame(width: Theme.metricWidth)
                    activityChart
                }
                DailyTokenChart(estimate: todayEstimate)

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
        .help("오늘: 이 Mac의 로컬 Codex 기록 기반 추정 \(value?.formatted() ?? "미집계") 토큰. 어제 대비 = 오늘 추정 ÷ 어제 서버 집계 × 100. 두 집계의 범위·시간대가 다를 수 있어요.\(todayEstimate?.isPartial == true ? " 일부 기록을 읽지 못했거나 누적값 재설정이 감지됐어요." : "")")
    }

    private var activityChart: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(days, id: \.self) { day in
                let value = chartTokens(on: day)
                let today = Calendar.current.isDate(day, inSameDayAs: now)
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(value == nil ? theme.subtle : today ? theme.companion : theme.soft)
                        .frame(height: max(3, Double(value ?? 0) / maximum * 42))
                        .overlay(alignment: .top) {
                            Text(chartLabel(value))
                                .font(.system(size: 8, weight: .medium)).monospacedDigit()
                                .foregroundStyle(today ? theme.companion : theme.muted)
                                .fixedSize()
                                .offset(y: -12)
                                .opacity(isHovered ? 1 : 0)
                                .accessibilityHidden(true)
                        }
                        .frame(height: 42, alignment: .bottom)
                        .padding(.top, 12)
                    VStack(spacing: 2) {
                        Text(today ? "오늘" : day.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.system(size: 9, weight: today ? .semibold : .regular))
                        Text(dateLabel(day))
                            .font(.system(size: 8)).monospacedDigit()
                            .opacity(isHovered ? 1 : 0)
                    }
                    .foregroundStyle(today ? theme.companion : theme.muted)
                }
                .frame(maxWidth: .infinity)
                .help("\(day.formatted(date: .abbreviated, time: .omitted)): \(value.map { $0.formatted() + " 토큰" } ?? "미집계")\(today ? " · 로컬 기록 기반 추정" : " · 서버 집계")")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(day.formatted(date: .abbreviated, time: .omitted)) \(today ? "추정 " : "")\(UsageFormatting.tokens(value)) 토큰")
            }
        }
    }

    private func metric(_ title: String, value: Int64?, prominent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 11))
                Text("토큰").font(.system(size: 9))
            }
            .foregroundStyle(theme.muted)
            Text(UsageFormatting.tokens(value))
                .font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(prominent ? theme.accent : theme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(value?.formatted() ?? "미집계")
    }
}
