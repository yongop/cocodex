import CryptoKit
import Foundation

struct LimitDepletionTrendTests {
    private let start = Date(timeIntervalSince1970: 1_783_296_000)
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func sample(_ seconds: Double, used: Double, reset: Double = 20 * 86_400) throws -> UsageSnapshot {
        let limits = try JSONDecoder().decode(RateLimitBucket.self, from: Data("""
        {"primary":{"usedPercent":\(used),"windowDurationMins":10080,"resetsAt":\(start.addingTimeInterval(reset).timeIntervalSince1970)}}
        """.utf8))
        return UsageSnapshot(limits: limits, tokens: nil, fetchedAt: start.addingTimeInterval(seconds))
    }

    func weeklyCumulativeScaleAndMissingCoverage() throws {
        var history = LimitUsageHistory()
        for (seconds, used) in [(0.0, 0.0), (600, 10), (1200, 15), (6 * 86_400, 70), (6 * 86_400 + 1200, 75)] {
            history.record(try sample(seconds, used: used))
        }
        let now = start.addingTimeInterval(6 * 86_400 + 1200)
        let trend = history.weeklyDepletion(endingOn: now, minutes: 10080, calendar: calendar)
        try expect(trend.baseline?.remaining == 100 && trend.baseline?.date == start)
        try expect(trend.points.last?.remaining == 80 && trend.points.last?.date == now)
        try expect(trend.points.contains { $0.isPartial })
        try expect(zip(trend.points, trend.points.dropFirst()).allSatisfy { $0.remaining >= $1.remaining })
        try expect(history.weeklyDepletion(endingOn: now, minutes: 300, calendar: calendar).points.isEmpty)
    }

    func midnightBaselineAndCurrentTime() throws {
        var history = LimitUsageHistory()
        history.record(try sample(-300, used: 30))
        history.record(try sample(300, used: 40))
        history.record(try sample(600, used: 45))
        let now = start.addingTimeInterval(600)
        let trend = history.dailyDepletion(on: start, through: now, minutes: 10080, calendar: calendar)
        try expect(trend.baseline?.date == start && trend.baseline?.remaining == 65)
        try expect(trend.points.last?.date == now && trend.points.last?.remaining == 55)
        try expect(trend.points.allSatisfy { $0.date <= now && !$0.isPartial })
        let future = history.dailyDepletion(on: start.addingTimeInterval(86_400), through: now,
                                            minutes: 10080, calendar: calendar)
        try expect(future.points.isEmpty)
    }

    func absentMidnightResetsAndFloor() throws {
        var history = LimitUsageHistory()
        try expect(history.dailyDepletion(on: start, through: start, minutes: 10080, calendar: calendar).points.isEmpty)
        history.record(try sample(300, used: 80))
        history.record(try sample(600, used: 85))
        history.record(try sample(4200, used: 90)) // No measured decrease across a long gap.
        history.record(try sample(4500, used: 95))
        history.record(try sample(4800, used: 0, reset: 21 * 86_400))
        history.record(try sample(5400, used: 50, reset: 21 * 86_400))
        let trend = history.dailyDepletion(on: start, through: start.addingTimeInterval(5500),
                                           minutes: 10080, calendar: calendar)
        try expect(trend.baseline?.date == start.addingTimeInterval(300) && trend.baseline?.remaining == 20)
        try expect(trend.points.first { $0.date == start.addingTimeInterval(900) }?.remaining == 15)
        try expect(trend.points.last?.remaining == 0 && trend.points.last?.isPartial == true)
        try expect(zip(trend.points, trend.points.dropFirst()).allSatisfy { $0.remaining >= $1.remaining })
    }

    func archivedBaselineAndLegacyCompatibility() throws {
        var history = LimitUsageHistory()
        for (seconds, used) in [(0.0, 20.0), (600, 25), (86_100, 40), (86_700, 50)] {
            history.record(try sample(seconds, used: used))
        }
        let now = start.addingTimeInterval(86_700)
        let before = history.dailyDepletion(on: start, through: now, minutes: 10080, calendar: calendar)
        history.closePastDays(now: now, calendar: calendar)
        let archive = try LimitUsageDay.decode(history.closedDays[0].encoded())
        var restored = try JSONDecoder().decode(LimitUsageHistory.self, from: JSONEncoder().encode(history))
        try restored.restoreClosedDays([archive])
        let after = restored.dailyDepletion(on: start, through: now, minutes: 10080, calendar: calendar)
        try expect(after.baseline == before.baseline && after.baseline?.remaining == 80)
        try expect(after.points.map(\.remaining) == before.points.map(\.remaining))
        try expect(after.points.last?.date == start.addingTimeInterval(86_400))

        // Existing compact day files omit this optional field and must still decode.
        var payload = try PropertyListSerialization.propertyList(from: archive.encoded().dropLast(32), format: nil) as! [String: Any]
        var windows = payload["windows"] as! [[String: Any]]
        for index in windows.indices { windows[index].removeValue(forKey: "baseline") }
        payload["windows"] = windows
        var legacy = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
        legacy.append(contentsOf: SHA256.hash(data: legacy))
        let old = try LimitUsageDay.decode(legacy)
        try expect(old.windows[0].baseline == nil && old.windows[0].used == archive.windows[0].used)
    }

    func daylightSavingEndAndZeroBaseline() throws {
        var la = calendar
        la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        for (month, day, hours) in [(3, 8, 23), (11, 1, 25)] {
            let date = la.date(from: DateComponents(year: 2026, month: month, day: day))!
            let interval = la.dateInterval(of: .day, for: date)!
            var history = LimitUsageHistory()
            for time in [date, date.addingTimeInterval(600)] {
                history.record(try sample(time.timeIntervalSince(start), used: 100, reset: 200 * 86_400))
            }
            let trend = history.dailyDepletion(on: date, through: interval.end, minutes: 10080, calendar: la)
            try expect(trend.baseline?.remaining == 0 && trend.points.allSatisfy { $0.remaining == 0 })
            try expect(trend.points.count == hours * 4 + 1 && trend.points.last?.date == interval.end)
        }
    }
}
