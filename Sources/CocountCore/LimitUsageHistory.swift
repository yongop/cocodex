import Foundation

/// Account-scoped observations. No tokens or conversation content are persisted.
public struct LimitUsageHistory: Codable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public let minutes: Int
        public let remaining: Double
        public let reset: Date
    }

    public struct Observation: Codable, Sendable {
        public let date: Date
        public let windows: [Window]
    }

    public struct Bin: Identifiable, Sendable {
        public let start: Date
        public let end: Date
        public var usedPercent: Double?
        public var observedSeconds: TimeInterval = 0
        public var id: Date { start }

        public func isPartial(at now: Date) -> Bool {
            observedSeconds + 1 < max(0, min(now, end).timeIntervalSince(start))
        }
    }

    public private(set) var observations: [Observation] = []
    public private(set) var closedDays: [LimitUsageDay] = []
    public private(set) var archivedThrough: Date?

    // Closed payloads live in separate files, never in the frequently rewritten active JSON.
    private enum CodingKeys: String, CodingKey { case observations, archivedThrough }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        observations = try container.decode([Observation].self, forKey: .observations)
        archivedThrough = try container.decodeIfPresent(Date.self, forKey: .archivedThrough)
        guard observations.count <= 20_000,
              observations.allSatisfy({ observation in
                  observation.date.timeIntervalSince1970.isFinite && observation.windows.allSatisfy {
                      $0.minutes > 0 && $0.remaining.isFinite && (0...100).contains($0.remaining)
                          && $0.reset.timeIntervalSince1970.isFinite
                  }
              }), zip(observations, observations.dropFirst()).allSatisfy({ $0.date < $1.date }),
              archivedThrough.map({ $0.timeIntervalSince1970.isFinite && $0 <= (observations.last?.date ?? .distantPast) }) ?? true else {
            throw HistoryStorageError.invalidArchive
        }
    }

    mutating func restoreClosedDays(_ days: [LimitUsageDay]) throws {
        let sorted = days.sorted { $0.start < $1.start }
        guard sorted.allSatisfy({ $0.end <= (archivedThrough ?? .distantPast) }),
              zip(sorted, sorted.dropFirst()).allSatisfy({ $0.end <= $1.start }) else {
            throw HistoryStorageError.invalidArchive
        }
        closedDays = sorted
    }

    /// Run only after the first observation on the next day, so the midnight pair is complete.
    /// Keep its left endpoint as a baseline, but exclude its already archived portion in queries.
    public mutating func closePastDays(now: Date, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let retention = calendar.date(byAdding: .day, value: -8, to: today)!
        closedDays.removeAll { $0.end <= retention }
        guard let first = observations.first, let last = observations.last, last.date >= today else { return }
        var cursor = max(retention, archivedThrough ?? calendar.startOfDay(for: first.date))
        while cursor < today {
            guard let day = calendar.dateInterval(of: .day, for: cursor), day.end > cursor else { break }
            let end = min(day.end, today)
            let summary = LimitUsageDay(history: self, interval: DateInterval(start: cursor, end: end), calendar: calendar)
            if !summary.windows.isEmpty { closedDays.append(summary) }
            archivedThrough = end
            cursor = end
        }
        // Time-zone changes may move today's boundary backwards. Closed UTC intervals stay immutable.
        let boundary = max(today, archivedThrough ?? today)
        if let index = observations.lastIndex(where: { $0.date < boundary }), index > 0 {
            observations.removeFirst(index)
        }
    }
    /// Longer gaps cannot reliably locate usage in a particular day or hour.
    public static let maximumGap: TimeInterval = 30 * 60
    public init() {}

    public mutating func record(_ snapshot: UsageSnapshot) {
        let date = snapshot.fetchedAt
        guard date.timeIntervalSince1970.isFinite,
              observations.last.map({ date > $0.date }) ?? true else { return }
        let windows = snapshot.limits.windows.compactMap { window -> Window? in
            guard let minutes = window.windowDurationMins, minutes > 0,
                  let used = window.usedPercent, used.isFinite, (0...100).contains(used),
                  let reset = window.resetDate, reset.timeIntervalSince1970.isFinite,
                  reset > date else { return nil }
            return Window(minutes: minutes, remaining: 100 - used, reset: reset)
        }
        recordObservation(Observation(date: date, windows: windows))
    }

    mutating func recordObservation(_ observation: Observation) {
        let date = observation.date
        let windows = observation.windows
        guard observations.last.map({ date > $0.date }) ?? true else { return }
        // Preserve both ends of idle spans, including observation coverage. Never bridge a gap.
        if observations.count >= 2 {
            let before = observations[observations.count - 2]
            let last = observations[observations.count - 1]
            if !windows.isEmpty, before.windows == windows, last.windows == windows,
               date.timeIntervalSince(before.date) <= Self.maximumGap {
                observations.removeLast()
            }
        }
        observations.append(Observation(date: date, windows: windows))
        // Keep nine days until persistence closes the old dates (also bounds a disk-failure backlog).
        let cutoff = date.addingTimeInterval(-9 * 86_400)
        observations.removeAll { $0.date < cutoff }
        // Bound storage even when manual refresh is unusually frequent.
        if observations.count > 20_000 { observations.removeFirst(observations.count - 20_000) }
    }

    public func daily(endingOn date: Date, minutes: Int, calendar: Calendar = .current) -> [Bin] {
        let today = calendar.startOfDay(for: date)
        let intervals = (-6...0).compactMap { offset -> DateInterval? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            return calendar.dateInterval(of: .day, for: day)
        }
        return bins(intervals, minutes: minutes)
    }

    public func hourly(on date: Date, minutes: Int, calendar: Calendar = .current) -> [Bin] {
        guard let day = calendar.dateInterval(of: .day, for: date) else { return [] }
        var intervals: [DateInterval] = []
        var start = day.start
        while start < day.end {
            guard let hour = calendar.dateInterval(of: .hour, for: start), hour.end > start else { break }
            intervals.append(DateInterval(start: start, end: min(hour.end, day.end)))
            start = hour.end
        }
        return bins(intervals, minutes: minutes)
    }

    public func quarterHourly(on date: Date, minutes: Int, calendar: Calendar = .current) -> [Bin] {
        guard let day = calendar.dateInterval(of: .day, for: date) else { return [] }
        return bins(Self.quarterIntervals(in: day), minutes: minutes)
    }

    static func quarterIntervals(in interval: DateInterval) -> [DateInterval] {
        var intervals: [DateInterval] = []
        var start = interval.start
        while start < interval.end {
            let end = min(start.addingTimeInterval(900), interval.end)
            intervals.append(DateInterval(start: start, end: end))
            start = end
        }
        return intervals
    }

    func bins(_ intervals: [DateInterval], minutes: Int) -> [Bin] {
        var result = intervals.map { Bin(start: $0.start, end: $0.end) }
        guard let first = intervals.first, let last = intervals.last else { return result }
        // Archive bins keep both zero usage and missing coverage distinct. Absolute timestamps
        // let current-calendar queries regroup them after a time-zone change without double counting.
        for day in closedDays where day.end > first.start && day.start < last.end {
            guard let window = day.windows.first(where: { $0.minutes == minutes }) else { continue }
            var destination = 0
            for index in window.used.indices where window.observed[index] > 0 {
                let start = day.start.addingTimeInterval(Double(index) * 900)
                let end = min(start.addingTimeInterval(900), day.end)
                while destination < result.count && result[destination].end <= start { destination += 1 }
                var target = destination
                while target < result.count && result[target].start < end {
                    let overlap = min(end, result[target].end).timeIntervalSince(max(start, result[target].start))
                    if overlap > 0 {
                        let fraction = overlap / end.timeIntervalSince(start)
                        result[target].usedPercent = (result[target].usedPercent ?? 0) + window.used[index] * fraction
                        result[target].observedSeconds += window.observed[index] * fraction
                    }
                    target += 1
                }
            }
        }
        var firstBin = 0
        for (previous, current) in zip(observations, observations.dropFirst()) {
            if current.date <= first.start { continue }
            if previous.date >= last.end { break }
            while firstBin < result.count && result[firstBin].end <= previous.date { firstBin += 1 }
            let duration = current.date.timeIntervalSince(previous.date)
            guard duration > 0, duration <= Self.maximumGap,
                  let before = previous.windows.first(where: { $0.minutes == minutes }),
                  let after = current.windows.first(where: { $0.minutes == minutes }),
                  before.reset == after.reset, current.date < before.reset,
                  before.remaining >= after.remaining else { continue }
            let decrease = before.remaining - after.remaining
            let start = max(previous.date, archivedThrough ?? previous.date)
            var index = firstBin
            while index < result.count && result[index].start < current.date {
                defer { index += 1 }
                let overlap = min(current.date, result[index].end)
                    .timeIntervalSince(max(start, result[index].start))
                guard overlap > 0 else { continue }
                // Interpolate only across bounded observations in the same reset period.
                result[index].usedPercent = (result[index].usedPercent ?? 0) + decrease * overlap / duration
                result[index].observedSeconds += overlap
            }
        }
        return result
    }

    public static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f%%", value)
    }

    public static func demo(now: Date = .now, calendar: Calendar = .current) -> LimitUsageHistory {
        var history = LimitUsageHistory()
        let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!
        var date = start
        var weekly = 0.0
        var short = 0.0
        var shortPeriod = -1
        while date <= now {
            let elapsed = date.timeIntervalSince(start)
            let period = Int(elapsed / (5 * 3_600))
            if period != shortPeriod { short = 0; shortPeriod = period }
            let hour = calendar.component(.hour, from: date)
            let weight = (8...22).contains(hour) ? Double((Int(elapsed / 900) * 7) % 11) / 100 : 0
            weekly += weight
            short += weight * 12
            let windows = [
                Window(minutes: 10_080, remaining: max(0, 100 - weekly), reset: start.addingTimeInterval(7 * 86_400)),
                Window(minutes: 300, remaining: max(0, 100 - short), reset: start.addingTimeInterval(Double(period + 1) * 5 * 3_600))
            ]
            history.observations.append(Observation(date: date, windows: windows))
            date = date.addingTimeInterval(900)
        }
        history.closePastDays(now: now, calendar: calendar)
        return history
    }
}
