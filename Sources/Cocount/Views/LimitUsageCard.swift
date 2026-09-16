import CocountCore
import SwiftUI

struct LimitUsageCard: View {
    @Environment(\.cocountTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cocountAnimationsEnabled) private var animationsEnabled
    @Environment(\.cocountDashboardVisible) private var dashboardVisible
    @Environment(\.cocountLimitTrendPreview) private var trendPreview
    let limits: RateLimitBucket
    let history: LimitUsageHistory
    let now: Date
    @Binding var mode: UsageCardMode
    @State private var selectedMinutes: Int?
    @State private var selectedDay: Date?
    @State private var isHovered = false
    @State private var showTrend = false

    private var showsTrend: Bool { showTrend || trendPreview }
    private var rotatesCharts: Bool { animationsEnabled && dashboardVisible }

    private var windows: [UsageWindow] {
        var seen = Set<Int>()
        return limits.windows.filter {
            guard let minutes = $0.windowDurationMins, minutes > 0 else { return false }
            return seen.insert(minutes).inserted
        }.sorted { ($0.windowDurationMins ?? 0) > ($1.windowDurationMins ?? 0) }
    }
    private var window: UsageWindow? {
        windows.first { $0.windowDurationMins == selectedMinutes } ?? windows.first
    }
    private var minutes: Int { window?.windowDurationMins ?? 0 }
    private var basis: String { minutes == 10_080 ? "주간" : window?.title ?? "한도" }

    var body: some View {
        let days = history.daily(endingOn: now, minutes: minutes)
        let day = selectedDay.flatMap { selected in days.first { $0.start == selected }?.start }
            ?? Calendar.current.startOfDay(for: now)
        let today = days.last?.usedPercent
        let yesterday = days.dropLast().last?.usedPercent
        let maximum = max(1, days.compactMap(\.usedPercent).max() ?? 0)
        return Card(verticalPadding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                UsageCardHeader(mode: $mode, basis: basis, changeBasis: {
                    guard let index = windows.firstIndex(where: { $0.windowDurationMins == minutes }),
                          windows.count > 1 else { return }
                    selectedMinutes = windows[(index + 1) % windows.count].windowDurationMins
                })
                HStack(alignment: .center, spacing: 12) {
                    HStack(alignment: .top, spacing: 8) {
                        todayMetric(today: today, yesterday: yesterday)
                        Rectangle().fill(theme.border).frame(width: 1, height: 32)
                        yesterdayMetric(yesterday)
                    }
                    .frame(width: Theme.metricWidth)
                    ZStack {
                        activityChart(days: days, day: day, maximum: maximum)
                            .opacity(showsTrend ? 0 : 1)
                            .allowsHitTesting(!showsTrend).accessibilityHidden(showsTrend)
                        WeeklyLimitTrendChart(trend: history.weeklyDepletion(endingOn: now, minutes: minutes),
                                              days: days, selectedDay: day, now: now, isHovered: isHovered,
                                              selectDay: { selectedDay = $0 })
                            .opacity(showsTrend ? 1 : 0)
                            .allowsHitTesting(showsTrend).accessibilityHidden(!showsTrend)
                    }
                }
                DailyLimitChart(history: history, minutes: minutes, day: day, now: now, showsTrend: showsTrend)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.radius))
        .onHover { isHovered = $0 }
        .task(id: rotatesCharts) {
            guard rotatesCharts else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(7)) }
                catch { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 1.2)) {
                    showTrend.toggle()
                }
            }
        }
    }

    private func todayMetric(today: Double?, yesterday: Double?) -> some View {
        let comparison: String
        if let today, let yesterday, yesterday > 0 {
            comparison = "어제 대비 \(UsageFormatting.percent(today / yesterday * 100))"
        } else { comparison = "어제 대비 —" }
        return VStack(alignment: .leading, spacing: 3) {
            Text("오늘").font(.system(size: 11)).foregroundStyle(theme.muted)
            Text(LimitUsageHistory.percent(today))
                .font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(theme.accent)
            Text(comparison)
                .font(.system(size: 9)).monospacedDigit().foregroundStyle(theme.muted)
                .lineLimit(1).minimumScaleFactor(0.9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("\(basis) 한도 전체 = 100%. 잔여율 80% → 75%는 5% 사용이에요. 조회 사이 감소분을 시간 비례로 나눈 추정이며 기록된 구간만 합산해요. 리셋·잔여율 증가·30분 초과 공백은 제외해 실제 사용보다 적을 수 있어요. 여러 기간을 합하면 100%를 넘을 수 있어요. —는 기록 없음, 0%는 관측된 사용 없음이에요. 어제 대비 = 오늘 기록분 ÷ 어제 기록분 × 100.")
    }

    private func yesterdayMetric(_ yesterday: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("어제").font(.system(size: 11)).foregroundStyle(theme.muted)
            Text(LimitUsageHistory.percent(yesterday))
                .font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(theme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("어제 \(basis) 한도 사용 추정 · \(LimitUsageHistory.percent(yesterday)) · 기록된 구간만 합산")
    }

    private func activityChart(days: [LimitUsageHistory.Bin], day: Date, maximum: Double) -> some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(days) { bin in
                let today = Calendar.current.isDate(bin.start, inSameDayAs: now)
                let selected = bin.start == day
                Button { selectedDay = bin.start } label: {
                    UsageDayBar(day: bin.start, dateLabel: bin.start.formatted(.dateTime.month(.defaultDigits).day()),
                                value: bin.usedPercent, maximum: maximum,
                                valueLabel: LimitUsageHistory.percent(bin.usedPercent),
                                isToday: today, isSelected: selected, isHovered: isHovered)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(bin.start.formatted(date: .abbreviated, time: .omitted)): \(limitBinDetail(bin, now: now)) · 클릭하여 시간별 보기")
                .accessibilityLabel("\(bin.start.formatted(date: .abbreviated, time: .omitted)): \(limitBinDetail(bin, now: now)), 시간별 보기")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

private struct DailyLimitChart: View {
    @Environment(\.cocountTheme) private var theme
    let history: LimitUsageHistory
    let minutes: Int
    let day: Date
    let now: Date
    let showsTrend: Bool

    var body: some View {
        let values = history.quarterHourly(on: day, minutes: minutes)
        let hours = history.hourly(on: day, minutes: minutes)
        let maximum = max(0.01, values.compactMap(\.usedPercent).max() ?? 0)
        let isToday = Calendar.current.isDate(day, inSameDayAs: now)
        let nextQuarter = values.firstIndex { $0.end > now }.map { $0 + 1 } ?? values.count
        let fraction = Double(nextQuarter) / Double(max(1, values.count))
        let trend = history.dailyDepletion(on: day, through: now, minutes: minutes)
        let interval = Calendar.current.dateInterval(of: .day, for: day)
        return VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geometry in
                ZStack(alignment: .bottomLeading) {
                    Rectangle().fill(theme.border).frame(height: 1)
                        .overlay(alignment: .topLeading) {
                            ForEach(0..<5) { index in
                                Rectangle().fill(theme.muted.opacity(0.5))
                                    .frame(width: 1, height: 4)
                                    .offset(x: (geometry.size.width - 1) * Double(index) / 4, y: 1)
                            }
                        }
                    HStack(alignment: .bottom, spacing: 1) {
                        ForEach(values) { bin in
                            let amount = bin.usedPercent ?? 0
                            let hour = hours.first { $0.start <= bin.start && $0.end > bin.start }
                            Rectangle()
                                .fill(theme.accent.opacity(0.45))
                                .frame(maxWidth: .infinity)
                                .frame(height: amount > 0 ? max(2, amount / maximum * 25.2) : 0)
                                .frame(height: 28, alignment: .bottom)
                                .contentShape(Rectangle())
                                .help(hour.map {
                                    "\($0.start.formatted(date: .omitted, time: .shortened))–\($0.end.formatted(date: .omitted, time: .shortened)): \(limitBinDetail($0, now: now))"
                                } ?? "기록 없음")
                        }
                    }
                    .opacity(showsTrend ? 0 : 1).allowsHitTesting(!showsTrend)
                    if let interval {
                        LimitDepletionPlot(trend: trend, start: interval.start, end: interval.end,
                                           ceiling: trend.baseline?.remaining ?? 100, floor: dailyFloor(trend))
                            .frame(height: 28)
                            .opacity(showsTrend ? 1 : 0).allowsHitTesting(false)
                    }
                    if showsTrend && trend.baseline == nil {
                        Text("00시 한도 기록 없음")
                            .font(.system(size: 8)).foregroundStyle(theme.muted)
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    if isToday && !showsTrend {
                        NextIntervalDot()
                            .offset(x: geometry.size.width * fraction - 3, y: 2.5)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: 30.1).padding(.bottom, 4)
            ZStack {
                timeAxis(trend: trend, isToday: isToday, lineMode: false).opacity(showsTrend ? 0 : 1)
                timeAxis(trend: trend, isToday: isToday, lineMode: true).opacity(showsTrend ? 1 : 0)
            }
            .font(.system(size: 8)).monospacedDigit().foregroundStyle(theme.muted)
        }
        .help(showsTrend ? "자정 잔여 한도에서 기록된 사용량을 차감해요. 하루의 작은 감소도 보이도록 세로 범위를 확대해요. 자정 기록이 없으면 표시된 첫 기록 시각부터 시작해요. 점선은 관측 부족, 리셋·잔여율 증가·30분 초과 공백은 차감에서 제외해요. 실제 잔여 한도는 상단 게이지를 확인하세요." : "15분별 한도 사용 추정")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(showsTrend
            ? "\(day.formatted(date: .abbreviated, time: .omitted)) 한도 감소. \(axisStart(trend: trend, isToday: isToday, lineMode: true)). 기록분 차감 후 \(LimitUsageHistory.percent(trend.points.last?.remaining)). 점선은 관측 부족."
            : "\(day.formatted(date: .abbreviated, time: .omitted)) 시간별 한도 사용 추정. " + hours.map {
            "\($0.start.formatted(.dateTime.hour().timeZone())) \(limitBinDetail($0, now: now))"
        }.joined(separator: ", "))
    }

    private func timeAxis(trend: LimitDepletionTrend, isToday: Bool, lineMode: Bool) -> some View {
        HStack {
            Text(axisStart(trend: trend, isToday: isToday, lineMode: lineMode))
            Spacer()
            if lineMode, let last = trend.points.last {
                Text("기록 기준 \(LimitUsageHistory.percent(last.remaining))").foregroundStyle(theme.accent)
                Spacer()
            }
            Text("24")
        }
    }

    private func dailyFloor(_ trend: LimitDepletionTrend) -> Double {
        guard let baseline = trend.baseline, let last = trend.points.last else { return 0 }
        return max(0, last.remaining - max(1, (baseline.remaining - last.remaining) * 0.2))
    }

    private func axisStart(trend: LimitDepletionTrend, isToday: Bool, lineMode: Bool) -> String {
        let prefix = isToday ? "" : "\(day.formatted(.dateTime.month(.defaultDigits).day())) · "
        guard lineMode, let baseline = trend.baseline else { return prefix + "00" }
        let isMidnight = baseline.date == Calendar.current.startOfDay(for: day)
        let time = isMidnight ? "00시" : "첫 기록 \(baseline.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()))"
        return prefix + "\(time) \(LimitUsageHistory.percent(baseline.remaining))"
    }
}

private func limitBinDetail(_ bin: LimitUsageHistory.Bin, now: Date) -> String {
    guard bin.start < now else { return "아직 지나지 않은 시간" }
    guard bin.usedPercent != nil else { return "기록 없음 · 두 번 이상 조회한 뒤 기록이 표시돼요" }
    return "\(LimitUsageHistory.percent(bin.usedPercent)) 사용 추정 · \(Int((bin.observedSeconds / 60).rounded()))분 관측\(bin.isPartial(at: now) ? " · 일부 구간" : "")"
}
