import Foundation

/// A decreasing balance after subtracting recorded usage, not a prediction of live quota.
/// Missing coverage stays explicit; resets never add an upward jump to this view.
public struct LimitDepletionTrend: Sendable {
    public struct Baseline: Codable, Equatable, Sendable {
        public let date: Date
        public let remaining: Double
    }

    public struct Point: Identifiable, Sendable {
        public let date: Date
        public let remaining: Double
        /// Coverage of the segment leading to this point is incomplete.
        public let isPartial: Bool
        public var id: Date { date }
    }

    public let baseline: Baseline?
    public let points: [Point]

    init(baseline: Baseline?, bins: [LimitUsageHistory.Bin]) {
        self.baseline = baseline
        guard let baseline else { points = []; return }
        var balance = baseline.remaining
        var result = [Point(date: baseline.date, remaining: balance, isPartial: false)]
        for bin in bins where bin.end > baseline.date {
            balance = max(0, balance - (bin.usedPercent ?? 0))
            result.append(Point(date: bin.end, remaining: balance, isPartial: bin.isPartial(at: bin.end)))
        }
        points = result
    }
}

extension LimitUsageHistory {
    public func weeklyDepletion(endingOn now: Date, minutes: Int,
                                calendar: Calendar = .current) -> LimitDepletionTrend {
        let intervals = daily(endingOn: now, minutes: minutes, calendar: calendar).compactMap { bin -> DateInterval? in
            guard bin.start < now else { return nil }
            return DateInterval(start: bin.start, end: min(bin.end, now))
        }
        let values = bins(intervals, minutes: minutes)
        let baseline = values.contains { $0.usedPercent != nil }
            ? intervals.first.map { LimitDepletionTrend.Baseline(date: $0.start, remaining: 100) } : nil
        return LimitDepletionTrend(baseline: baseline, bins: values)
    }

    public func dailyDepletion(on date: Date, through now: Date, minutes: Int,
                               calendar: Calendar = .current) -> LimitDepletionTrend {
        guard let day = calendar.dateInterval(of: .day, for: date), day.start <= now else {
            return LimitDepletionTrend(baseline: nil, bins: [])
        }
        let end = min(day.end, now)
        let baseline = remainingBaseline(in: DateInterval(start: day.start, end: end), minutes: minutes)
        guard let baseline else { return LimitDepletionTrend(baseline: nil, bins: []) }
        let intervals = Self.quarterIntervals(in: day).compactMap { quarter -> DateInterval? in
            let start = max(quarter.start, baseline.date)
            let stop = min(quarter.end, end)
            return stop > start ? DateInterval(start: start, end: stop) : nil
        }
        return LimitDepletionTrend(baseline: baseline, bins: bins(intervals, minutes: minutes))
    }

    /// Prefer a real midnight value (or bounded interpolation across midnight).
    /// When midnight was not observed, return the first known value with its true timestamp.
    func remainingBaseline(in interval: DateInterval, minutes: Int) -> LimitDepletionTrend.Baseline? {
        var candidates = closedDays.compactMap { day -> LimitDepletionTrend.Baseline? in
            guard let baseline = day.windows.first(where: { $0.minutes == minutes })?.baseline,
                  baseline.date >= interval.start, baseline.date <= interval.end else { return nil }
            return baseline
        }
        for (previous, current) in zip(observations, observations.dropFirst()) {
            guard previous.date < interval.start, current.date > interval.start,
                  current.date.timeIntervalSince(previous.date) <= Self.maximumGap,
                  let before = previous.windows.first(where: { $0.minutes == minutes }),
                  let after = current.windows.first(where: { $0.minutes == minutes }),
                  before.reset == after.reset, current.date < before.reset,
                  before.remaining >= after.remaining else { continue }
            let fraction = interval.start.timeIntervalSince(previous.date) / current.date.timeIntervalSince(previous.date)
            return .init(date: interval.start, remaining: before.remaining - (before.remaining - after.remaining) * fraction)
        }
        if let first = observations.first(where: { observation in
            observation.date >= interval.start && observation.date <= interval.end
                && observation.windows.contains { $0.minutes == minutes }
        }), let window = first.windows.first(where: { $0.minutes == minutes }) {
            candidates.append(.init(date: first.date, remaining: window.remaining))
        }
        return candidates.min { $0.date < $1.date }
    }
}
