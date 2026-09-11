import Foundation

struct LimitUsageHistoryTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func sample(_ seconds: Double, used: Double?, reset: Double = 604_800,
                        shortUsed: Double? = nil) throws -> UsageSnapshot {
        let json = """
        {"primary":{"usedPercent":\(used.map(String.init(describing:)) ?? "null"),"windowDurationMins":10080,"resetsAt":\(reset)},
         "secondary":{"usedPercent":\(shortUsed.map(String.init(describing:)) ?? "null"),"windowDurationMins":300,"resetsAt":604800}}
        """
        return UsageSnapshot(limits: try JSONDecoder().decode(RateLimitBucket.self, from: Data(json.utf8)),
                             tokens: nil, fetchedAt: Date(timeIntervalSince1970: seconds))
    }

    func baselineZeroAndWindowIsolation() throws {
        var history = LimitUsageHistory()
        let now = Date(timeIntervalSince1970: 1200)
        history.record(try sample(0, used: 50, shortUsed: 10))
        try expect(history.daily(endingOn: now, minutes: 10080, calendar: calendar).last?.usedPercent == nil)
        history.record(try sample(600, used: 50, shortUsed: 15))
        try expect(history.hourly(on: now, minutes: 10080, calendar: calendar)[0].usedPercent == 0)
        history.record(try sample(1200, used: 52, shortUsed: 25))
        let weekly = history.hourly(on: now, minutes: 10080, calendar: calendar)
        try expect(weekly[0].usedPercent == 2)
        try expect(weekly[0].observedSeconds == 1200)
        try expect(weekly[1].usedPercent == nil)
        try expect(history.daily(endingOn: now, minutes: 300, calendar: calendar).last?.usedPercent == 15)
        try expect(history.daily(endingOn: now, minutes: 10080, calendar: calendar).dropLast().allSatisfy { $0.usedPercent == nil })
        history.record(try sample(1800, used: 52, shortUsed: 25))
        try expect(history.hourly(on: now, minutes: 10080, calendar: calendar)[0].usedPercent == 2)
        try expect(LimitUsageHistory.percent(nil) == "—")
        try expect(LimitUsageHistory.percent(0) == "0.0%")
    }

    func interpolationAcrossMidnight() throws {
        var history = LimitUsageHistory()
        history.record(try sample(86_100, used: 20)) // 23:55
        history.record(try sample(86_700, used: 30)) // 00:05
        let now = Date(timeIntervalSince1970: 86_700)
        let daily = history.daily(endingOn: now, minutes: 10080, calendar: calendar)
        try expect(daily[5].usedPercent == 5 && daily[6].usedPercent == 5)
        try expect(daily[5].observedSeconds == 300 && daily[6].observedSeconds == 300)
        let hourly = history.hourly(on: now, minutes: 10080, calendar: calendar)
        try expect(hourly[0].usedPercent == 5)
        try expect(!hourly[0].isPartial(at: now))
        try expect(daily[5].isPartial(at: now))
        try expect(hourly.compactMap(\.usedPercent).reduce(0, +) == daily[6].usedPercent)
        let quarters = history.quarterHourly(on: now, minutes: 10080, calendar: calendar)
        try expect(quarters.count == 96)
        try expect(quarters.compactMap(\.usedPercent).reduce(0, +) == daily[6].usedPercent)
    }

    func resetsGapsAndInvalidObservations() throws {
        var history = LimitUsageHistory()
        history.record(try sample(0, used: 80))
        history.record(try sample(600, used: 85))
        history.record(try sample(1200, used: 10, reset: 605_000))
        history.record(try sample(1800, used: 12, reset: 605_000))
        history.record(try sample(2400, used: 8, reset: 605_000)) // correction is a baseline
        history.record(try sample(3000, used: 9, reset: 605_000))
        history.record(try sample(5400, used: 20, reset: 605_000)) // long gap omitted
        history.record(try sample(6000, used: nil, reset: 605_000))
        history.record(try sample(6600, used: 22, reset: 605_000)) // missing reading breaks chain
        history.record(try sample(7200, used: 23, reset: 605_000))
        history.record(try sample(7000, used: 90, reset: 605_000)) // out of order ignored
        history.record(try sample(7200, used: 90, reset: 605_000)) // duplicate ignored
        history.record(try sample(7800, used: 150, reset: 605_000))
        history.record(try sample(8400, used: 25, reset: 605_000))
        history.record(try sample(9000, used: 30, reset: 9000)) // expired window
        let result = history.daily(endingOn: Date(timeIntervalSince1970: 9000), minutes: 10080, calendar: calendar).last!
        try expect(result.usedPercent == 9)
        try expect(result.observedSeconds == 2400)
        try expect(result.isPartial(at: Date(timeIntervalSince1970: 9000)))
    }

    func multiplePeriodsPersistenceAndRetention() throws {
        var history = LimitUsageHistory()
        history.record(try sample(0, used: 0))
        history.record(try sample(600, used: 90))
        history.record(try sample(1200, used: 0, reset: 605_000))
        history.record(try sample(1800, used: 60, reset: 605_000))
        let data = try JSONEncoder().encode(history)
        let restored = try JSONDecoder().decode(LimitUsageHistory.self, from: data)
        let now = Date(timeIntervalSince1970: 1800)
        try expect(restored.daily(endingOn: now, minutes: 10080, calendar: calendar).last?.usedPercent == 150)
        history.record(try sample(10 * 86_400, used: 0, reset: 20 * 86_400))
        try expect(history.observations.count == 1)
    }

    func daylightSavingHours() throws {
        var calendar = calendar
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let history = LimitUsageHistory()
        let spring = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let autumn = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        try expect(history.hourly(on: spring, minutes: 300, calendar: calendar).count == 23)
        try expect(history.quarterHourly(on: spring, minutes: 300, calendar: calendar).count == 92)
        let autumnHours = history.hourly(on: autumn, minutes: 300, calendar: calendar)
        try expect(autumnHours.count == 25 && Set(autumnHours.map(\.id)).count == 25)
        try expect(history.quarterHourly(on: autumn, minutes: 300, calendar: calendar).count == 100)
    }
    func idleCompactionPreservesCoverageAndGaps() throws {
        var history = LimitUsageHistory()
        for seconds in stride(from: 0, through: 3_600, by: 60) {
            history.record(try sample(Double(seconds), used: 50))
        }
        try expect(history.observations.count == 3)
        let hour = history.hourly(on: Date(timeIntervalSince1970: 3_600), minutes: 10080, calendar: calendar)[0]
        try expect(hour.usedPercent == 0 && hour.observedSeconds == 3_600)
        history.record(try sample(3_900, used: 55))
        history.record(try sample(7_200, used: 60)) // preserve the missing interval
        history.record(try sample(7_500, used: 60))
        let day = history.daily(endingOn: Date(timeIntervalSince1970: 7_500), minutes: 10080, calendar: calendar).last!
        try expect(day.usedPercent == 5 && day.observedSeconds == 4_200)
    }

    func linearAggregationMatchesReference() throws {
        var history = LimitUsageHistory()
        for index in 0..<2_000 {
            let used: Double? = index % 37 == 0 ? nil : Double(index % 100)
            history.record(try sample(Double(index * 120), used: used))
        }
        for day in [86_400.0, 172_800, 259_200] {
            let date = Date(timeIntervalSince1970: day)
            let bins = history.daily(endingOn: date, minutes: 10080, calendar: calendar)
                + history.hourly(on: date, minutes: 10080, calendar: calendar)
                + history.quarterHourly(on: date, minutes: 10080, calendar: calendar)
            for bin in bins {
                var value: Double?
                var coverage = 0.0
                for (a, b) in zip(history.observations, history.observations.dropFirst()) {
                    let duration = b.date.timeIntervalSince(a.date)
                    guard duration > 0, duration <= LimitUsageHistory.maximumGap,
                          let before = a.windows.first, let after = b.windows.first,
                          before.reset == after.reset, b.date < before.reset,
                          before.remaining >= after.remaining else { continue }
                    let overlap = min(b.date, bin.end).timeIntervalSince(max(a.date, bin.start))
                    guard overlap > 0 else { continue }
                    value = (value ?? 0) + (before.remaining - after.remaining) * overlap / duration
                    coverage += overlap
                }
                try expect((value == nil) == (bin.usedPercent == nil))
                try expect(abs((value ?? 0) - (bin.usedPercent ?? 0)) < 1e-9)
                try expect(coverage == bin.observedSeconds)
            }
        }
    }

}
