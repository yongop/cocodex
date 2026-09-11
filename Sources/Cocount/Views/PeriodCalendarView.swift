import CocountCore
import SwiftUI

struct PeriodCalendarView: View {
    @Environment(\.cocountTheme) private var theme
    let periods: [UsagePeriod]
    let credits: [ResetCredit]
    let now: Date
    @Binding var focus: Date?

    private var days: [Date] { PeriodCalendar.days(around: focus ?? now) }
    private var heading: String {
        guard let first = days.first, let last = days.last else { return "3주 달력" }
        let format = Date.FormatStyle.dateTime.month()
        return Calendar.current.isDate(first, equalTo: last, toGranularity: .month)
            ? first.formatted(format) : "\(first.formatted(format)) · \(last.formatted(format))"
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 5) {
                Text(heading).font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                Button { shift(-7) } label: { Image(systemName: "chevron.left") }
                    .help("이전 주").accessibilityLabel("이전 주")
                Button("3주") { focus = nil }.help("오늘로 돌아가기")
                Button { shift(7) } label: { Image(systemName: "chevron.right") }
                    .help("다음 주").accessibilityLabel("다음 주")
            }
            .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(theme.muted)
            HStack(spacing: 3) {
                ForEach(Array(["일", "월", "화", "수", "목", "금", "토"].enumerated()), id: \.offset) { index, day in
                    Text(day).font(.system(size: 9))
                        .foregroundStyle(index == 0 ? theme.time : index == 6 ? theme.companion : theme.muted)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 3) {
                ForEach(days, id: \.self) { day in cell(day) }
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).stroke(theme.danger, lineWidth: 1).frame(width: 7, height: 7)
                Text("초기화권 만료").font(.system(size: 8))
            }
            .foregroundStyle(theme.muted)
        }
        .frame(width: 174)
    }

    private func cell(_ day: Date) -> some View {
        let calendar = Calendar.current
        let segments = periods.prefix(3).enumerated().flatMap { index, period in
            PeriodCalendar.segments(on: day, periods: [period], now: now).map {
                ColoredSegment(periodIndex: index, interval: $0)
            }
        }
        let starts = periods.contains { calendar.isDate($0.start, inSameDayAs: day) }
        let ends = periods.contains { calendar.isDate($0.end, inSameDayAs: day) }
        let expiring = credits.filter { $0.expiryDate.map { calendar.isDate($0, inSameDayAs: day) } ?? false }
        let today = calendar.isDate(day, inSameDayAs: now)
        return ZStack {
            RoundedRectangle(cornerRadius: 5).fill(theme.subtle)
            GeometryReader { geometry in
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Rectangle().fill(color(for: segment))
                        .frame(width: geometry.size.width * (segment.interval.endFraction - segment.interval.startFraction))
                        .offset(x: geometry.size.width * segment.interval.startFraction)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            Text("\(calendar.component(.day, from: day))")
                .font(.system(size: 11, weight: today ? .bold : .medium))
                .foregroundStyle(theme.text)
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(!expiring.isEmpty ? theme.danger : today ? theme.accent : .clear,
                              lineWidth: !expiring.isEmpty ? 1.5 : 1)
            if today {
                Circle().fill(theme.accent).frame(width: 3, height: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(2)
            }
        }
        .frame(height: 23)
        .help(dayDescription(day, starts: starts, ends: ends, expiring: expiring))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dayDescription(day, starts: starts, ends: ends, expiring: expiring))
    }

    private func dayDescription(_ day: Date, starts: Bool, ends: Bool, expiring: [ResetCredit]) -> String {
        var parts = [day.formatted(date: .complete, time: .omitted)]
        let dayStart = Calendar.current.startOfDay(for: day)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        for (index, period) in periods.prefix(3).enumerated()
            where period.start < dayEnd && period.end >= dayStart {
            let name = index == 0 ? "현재 기간" : "지난 \(index)기간"
            parts.append("\(name): \(period.start.formatted(date: .abbreviated, time: .shortened)) ~ \(period.end.formatted(date: .abbreviated, time: .shortened))")
        }
        if Calendar.current.isDate(day, inSameDayAs: now) { parts.append("오늘") }
        if starts { parts.append("사용 기간 시작") }
        if ends { parts.append("사용 기간 종료 · 리셋") }
        if !expiring.isEmpty { parts.append("초기화권 \(expiring.count)장 만료") }
        return parts.joined(separator: ", ")
    }

    private struct ColoredSegment {
        let periodIndex: Int
        let interval: PeriodCalendar.Segment
    }

    private func color(for segment: ColoredSegment) -> Color {
        switch segment.periodIndex {
        case 0: segment.interval.isElapsed ? theme.elapsed : theme.soft
        case 1: theme.previousPeriod
        default: theme.olderPeriod
        }
    }

    private func shift(_ days: Int) {
        focus = Calendar.current.date(byAdding: .day, value: days, to: focus ?? now)
    }
}
