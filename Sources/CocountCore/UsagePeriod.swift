import Foundation

/// Window boundaries are derived from the server's reset timestamp and duration.
public struct UsagePeriod: Codable, Equatable, Identifiable, Sendable {
    public let start: Date
    public var end: Date
    public var id: Date { start }
    public var midpoint: Date { start.addingTimeInterval(end.timeIntervalSince(start) / 2) }

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public init?(window: UsageWindow) {
        guard let minutes = window.windowDurationMins, minutes > 0,
              let end = window.resetDate, end.timeIntervalSince1970.isFinite else { return nil }
        self.init(start: end.addingTimeInterval(-Double(minutes) * 60), end: end)
    }

    public func remainingFraction(at now: Date) -> Double {
        guard end > start else { return 0 }
        return min(1, max(0, end.timeIntervalSince(now) / end.timeIntervalSince(start)))
    }
}

/// Keep only the current and two previously observed periods. Never fabricate old windows.
public struct PeriodHistory: Codable, Sendable {
    public private(set) var periods: [UsagePeriod] = []
    public init() {}

    public mutating func record(_ period: UsagePeriod) {
        guard period.end > period.start else { return }
        if let latest = periods.first {
            guard period.start > latest.start else { return }
            // An early reset ends the prior period at the next reported start.
            if periods[0].end > period.start { periods[0].end = period.start }
        }
        periods.insert(period, at: 0)
        periods = Array(periods.prefix(3))
    }

    public static func demo(current: UsagePeriod) -> PeriodHistory {
        var history = PeriodHistory()
        let duration = current.end.timeIntervalSince(current.start)
        for offset in [-2, -1, 0] {
            history.record(UsagePeriod(start: current.start.addingTimeInterval(Double(offset) * duration),
                                       end: current.end.addingTimeInterval(Double(offset) * duration)))
        }
        return history
    }
}

public enum PeriodCalendar {
    public static func days(around anchor: Date, calendar: Calendar = .current) -> [Date] {
        let midnight = calendar.startOfDay(for: anchor)
        let weekday = calendar.component(.weekday, from: midnight)
        guard let first = calendar.date(byAdding: .day, value: -(weekday - 1) - 7, to: midnight) else { return [] }
        return (0..<21).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }

    public struct Segment: Sendable {
        public let startFraction: Double
        public let endFraction: Double
        public let isElapsed: Bool
    }

    /// Use actual local day lengths, including daylight-saving transitions.
    public static func segments(on day: Date, periods: [UsagePeriod], now: Date,
                                calendar: Calendar = .current) -> [Segment] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let duration = end.timeIntervalSince(start)
        return periods.flatMap { period -> [Segment] in
            let lower = max(start, period.start)
            let upper = min(end, period.end)
            guard lower < upper else { return [] }
            let split = min(upper, max(lower, now))
            var result: [Segment] = []
            if split > lower {
                result.append(Segment(startFraction: lower.timeIntervalSince(start) / duration,
                                      endFraction: split.timeIntervalSince(start) / duration, isElapsed: true))
            }
            if upper > split {
                result.append(Segment(startFraction: split.timeIntervalSince(start) / duration,
                                      endFraction: upper.timeIntervalSince(start) / duration, isElapsed: false))
            }
            return result
        }
    }
}
