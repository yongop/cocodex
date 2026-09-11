import Foundation

struct PeriodAndCreditTests {
    func dailyCreditBlocks() throws {
        let credit = ResetCredit(id: "test", resetType: "codexRateLimits", status: "available",
                                 grantedAt: 0, expiresAt: 3 * 86_400)
        try expect(credit.dayBlocks(at: Date(timeIntervalSince1970: 0)) == [1, 1, 1])
        try expect(credit.dayBlocks(at: Date(timeIntervalSince1970: 1.5 * 86_400)) == [1, 0.5, 0])
        try expect(credit.dayBlocks(at: Date(timeIntervalSince1970: 4 * 86_400)) == [0, 0, 0])
        let unknown = ResetCredit(id: "unknown", resetType: "codexRateLimits", status: "available",
                                  grantedAt: nil, expiresAt: nil)
        try expect(unknown.dayBlocks(at: .now).isEmpty)
    }

    private func decode<T: Decodable>(_ text: String, as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }

    func remainingTimeRing() throws {
        let window = try decode("{\"windowDurationMins\":60,\"resetsAt\":7200}", as: UsageWindow.self)
        let period = UsagePeriod(window: window)!
        try expect(period.start.timeIntervalSince1970 == 3_600)
        try expect(period.remainingFraction(at: Date(timeIntervalSince1970: 5_400)) == 0.5)
        try expect(period.remainingFraction(at: Date(timeIntervalSince1970: 8_000)) == 0)
        try expect(period.remainingFraction(at: Date(timeIntervalSince1970: 0)) == 1)
        let unknown = try decode("{\"windowDurationMins\":null,\"resetsAt\":7200}", as: UsageWindow.self)
        try expect(UsagePeriod(window: unknown) == nil)
    }

    func historyKeepsTwoPastPeriods() throws {
        var history = PeriodHistory()
        for index in 0..<5 {
            let period = UsagePeriod(start: Date(timeIntervalSince1970: Double(index * 100)),
                                     end: Date(timeIntervalSince1970: Double((index + 1) * 100)))
            history.record(period)
            history.record(period)
        }
        try expect(history.periods.count == 3)
        try expect(history.periods.map { $0.start.timeIntervalSince1970 } == [400, 300, 200])
        let restored = try JSONDecoder().decode(PeriodHistory.self, from: JSONEncoder().encode(history))
        try expect(restored.periods == history.periods)
    }

    func earlyResetAndMissingHistory() throws {
        var history = PeriodHistory()
        history.record(UsagePeriod(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 100)))
        try expect(history.periods.count == 1)
        history.record(UsagePeriod(start: Date(timeIntervalSince1970: 60), end: Date(timeIntervalSince1970: 160)))
        try expect(history.periods[1].end.timeIntervalSince1970 == 60)
        history.record(UsagePeriod(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 100)))
        try expect(history.periods.count == 2)
    }

    func calendarCrossesMonthAndDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let days = PeriodCalendar.days(around: anchor, calendar: calendar)
        try expect(days.count == 21)
        try expect(calendar.component(.weekday, from: days[0]) == 1)
        try expect(calendar.component(.weekday, from: days[20]) == 7)
        try expect(Set(days).count == 21)
        try expect(days[8].timeIntervalSince(days[7]) == 23 * 3_600)
        let yearEnd = calendar.date(from: DateComponents(year: 2026, month: 12, day: 31))!
        let crossing = PeriodCalendar.days(around: yearEnd, calendar: calendar)
        try expect(calendar.component(.year, from: crossing.last!) == 2027)
    }

    func partialDayAndEndBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 0)
        let period = UsagePeriod(start: day.addingTimeInterval(6 * 3_600), end: day.addingTimeInterval(18 * 3_600))
        let segments = PeriodCalendar.segments(on: day, periods: [period], now: day.addingTimeInterval(12 * 3_600), calendar: calendar)
        try expect(segments.count == 2)
        try expect(segments[0].startFraction == 0.25 && segments[0].endFraction == 0.5 && segments[0].isElapsed)
        try expect(segments[1].startFraction == 0.5 && segments[1].endFraction == 0.75 && !segments[1].isElapsed)
        let fullDay = UsagePeriod(start: day, end: day.addingTimeInterval(86_400))
        try expect(PeriodCalendar.segments(on: fullDay.end, periods: [fullDay], now: fullDay.end, calendar: calendar).isEmpty)
    }

    func creditCountIsNotDetailCount() throws {
        let summary = try decode("""
        {"availableCount":3,"credits":[{"id":"one","resetType":"codexRateLimits","status":"available","expiresAt":null}]}
        """, as: ResetCredits.self)
        try expect(summary.count == 3)
        try expect(summary.available.count == 1)
        try expect(summary.available[0].remainingLabel(at: .now) == "만료 없음")
        let countOnly = try decode("{\"availableCount\":2,\"credits\":null}", as: ResetCredits.self)
        try expect(countOnly.available.isEmpty && countOnly.count == 2)
        let unknown = try decode("{}", as: ResetCredits.self)
        try expect(unknown.count == nil)
    }

    func creditExpirySortingAndProgress() throws {
        let summary = try decode("""
        {"availableCount":2,"credits":[
        {"id":"later","resetType":"codexRateLimits","status":"available","grantedAt":0,"expiresAt":7200},
        {"id":"used","resetType":"codexRateLimits","status":"redeemed","grantedAt":0,"expiresAt":1000},
        {"id":"soon","resetType":"codexRateLimits","status":"available","grantedAt":0,"expiresAt":3600}]}
        """, as: ResetCredits.self)
        try expect(summary.available.map(\.id) == ["soon", "later"])
        try expect(summary.available[0].remainingFraction(at: Date(timeIntervalSince1970: 1_800)) == 0.5)
        try expect(summary.available[0].remainingLabel(at: Date(timeIntervalSince1970: 3_600)) == "만료 · 갱신 필요")
        try expect(summary.available[0].remainingFraction(at: Date(timeIntervalSince1970: 4_000)) == 0)
    }
}
