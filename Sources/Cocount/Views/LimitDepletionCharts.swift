import CocountCore
import SwiftUI

struct WeeklyLimitTrendChart: View {
    @Environment(\.cocountTheme) private var theme
    let trend: LimitDepletionTrend
    let days: [LimitUsageHistory.Bin]
    let selectedDay: Date
    let now: Date
    let isHovered: Bool
    let selectDay: (Date) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            if let first = days.first, let last = days.last {
                LimitDepletionPlot(trend: trend, start: first.start, end: last.end, ceiling: 100)
                    .frame(height: 42).padding(.top, 12)
                    .overlay(alignment: .top) {
                        HStack {
                            Text("100%")
                            Spacer(minLength: 2)
                            Text(trend.points.last.map { LimitUsageHistory.percent($0.remaining) } ?? "기록 없음")
                                .foregroundStyle(theme.accent)
                        }
                        .font(.system(size: 8, weight: .medium)).monospacedDigit()
                        .foregroundStyle(theme.muted)
                    }
                    .allowsHitTesting(false)
            }
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(days) { bin in
                    let today = Calendar.current.isDate(bin.start, inSameDayAs: now)
                    Button { selectDay(bin.start) } label: {
                        VStack(spacing: 4) {
                            Color.clear.frame(height: 54)
                            VStack(spacing: 2) {
                                Text(today ? "오늘" : bin.start.formatted(.dateTime.weekday(.abbreviated)))
                                    .font(.system(size: 9, weight: today || selectedDay == bin.start ? .semibold : .regular))
                                Text(bin.start.formatted(.dateTime.month(.defaultDigits).day()))
                                    .font(.system(size: 8)).monospacedDigit().opacity(isHovered ? 1 : 0)
                            }
                            .foregroundStyle(today ? theme.companion : theme.muted)
                        }
                        .frame(maxWidth: .infinity).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(bin.start.formatted(date: .abbreviated, time: .omitted)) · 클릭하여 시간별 감소 보기")
                    .accessibilityLabel("\(bin.start.formatted(date: .abbreviated, time: .omitted)), 시간별 감소 보기")
                    .accessibilityAddTraits(selectedDay == bin.start ? .isSelected : [])
                }
            }
        }
        .help("100%에서 최근 7일의 기록된 사용량을 누적 차감한 추정이에요. 점선은 관측이 부족한 구간이에요. 리셋으로 보충된 한도는 더하지 않으며 0%까지만 표시해요.")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("최근 7일 한도 감소, 100% 기준. 기록분 차감 후 \(LimitUsageHistory.percent(trend.points.last?.remaining))")
    }
}

/// A small, straight-segment sparkline using the card's existing palette and scale.
/// Unobserved spans use dashes and no area fill, so absence never looks like measured idle time.
struct LimitDepletionPlot: View {
    @Environment(\.cocountTheme) private var theme
    let trend: LimitDepletionTrend
    let start: Date
    let end: Date
    let ceiling: Double
    var floor: Double = 0

    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 3
            let width = max(0, size.width - inset * 2)
            let height = max(0, size.height - inset * 2)
            let duration = max(1, end.timeIntervalSince(start))
            let range = max(0.01, ceiling - floor)
            func position(_ point: LimitDepletionTrend.Point) -> CGPoint {
                CGPoint(x: inset + min(1, max(0, point.date.timeIntervalSince(start) / duration)) * width,
                        y: inset + (1 - min(1, max(0, (point.remaining - floor) / range))) * height)
            }
            var guide = Path()
            guide.move(to: CGPoint(x: inset, y: inset))
            guide.addLine(to: CGPoint(x: size.width - inset, y: inset))
            context.stroke(guide, with: .color(theme.border), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))

            for (previous, current) in zip(trend.points, trend.points.dropFirst()) {
                let a = position(previous)
                let b = position(current)
                if !current.isPartial {
                    var area = Path()
                    area.move(to: a)
                    area.addLine(to: b)
                    area.addLine(to: CGPoint(x: b.x, y: size.height))
                    area.addLine(to: CGPoint(x: a.x, y: size.height))
                    area.closeSubpath()
                    context.fill(area, with: .linearGradient(
                        Gradient(colors: [theme.soft.opacity(0.32), theme.soft.opacity(0.025)]),
                        startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                }
                var segment = Path()
                segment.move(to: a)
                segment.addLine(to: b)
                context.stroke(segment, with: .color(theme.accent.opacity(current.isPartial ? 0.4 : 0.85)),
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round,
                                                  dash: current.isPartial ? [2, 3] : []))
            }
            if let last = trend.points.last {
                let point = position(last)
                context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)),
                             with: .color(theme.card))
                context.fill(Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)),
                             with: .color(theme.companion))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct LimitTrendPreviewKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var cocountLimitTrendPreview: Bool {
        get { self[LimitTrendPreviewKey.self] }
        set { self[LimitTrendPreviewKey.self] = newValue }
    }
}
