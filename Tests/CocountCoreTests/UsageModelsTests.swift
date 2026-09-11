import Foundation

struct UsageModelsTests {
    private func decode<T: Decodable>(_ json: String, as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func modernBucketsTakePriority() throws {
        let value = try decode("""
        {"rateLimits":{"limitId":"codex","primary":{"usedPercent":5}},
         "rateLimitsByLimitId":{
          "codex_bengalfox":{"limitId":"codex_bengalfox","primary":{"usedPercent":0}},
          "codex":{"limitId":"codex","primary":{"usedPercent":71,"windowDurationMins":10080}}}}
        """, as: RateLimitsResponse.self)
        try expect(value.codex?.featuredWindow?.remainingPercent == 29)
        try expect(value.codex?.featuredWindow?.title == "이번 주")
        try expect(value.codex?.otherWindow == nil)
    }

    func unrelatedBucketDoesNotBecomeCodex() throws {
        let value = try decode("""
        {"rateLimits":{"limitId":"codex","primary":{"usedPercent":5}},
         "rateLimitsByLimitId":{"spark":{"limitId":"spark","primary":{"usedPercent":1}}}}
        """, as: RateLimitsResponse.self)
        try expect(value.codex == nil)
    }

    func legacyAndReversedWindows() throws {
        let value = try decode("""
        {"rateLimits":{"primary":{"usedPercent":50,"windowDurationMins":300},
         "secondary":{"usedPercent":70,"windowDurationMins":10080}}}
        """, as: RateLimitsResponse.self)
        try expect(value.codex?.featuredWindow?.remainingPercent == 30)
        try expect(value.codex?.otherWindow?.title == "5시간")
    }

    func unknownQuotaRemainsUnknown() throws {
        let window = try decode("{\"usedPercent\":null,\"resetsAt\":null}", as: UsageWindow.self)
        try expect(window.remainingPercent == nil)
        try expect(window.resetDate == nil)
        try expect(UsageFormatting.percent(window.remainingPercent) == "—")
    }

    func percentIsClamped(used: Double, expected: Double) throws {
        let window = try decode("{\"usedPercent\":\(used)}", as: UsageWindow.self)
        try expect(window.remainingPercent == expected)
    }

    func resetUsesSecondsAndDoesNotInventFreshQuota() throws {
        let window = try decode("{\"usedPercent\":100,\"resetsAt\":1000}", as: UsageWindow.self)
        try expect(window.resetDate?.timeIntervalSince1970 == 1_000)
        try expect(UsageFormatting.countdown(to: window.resetDate, now: Date(timeIntervalSince1970: 1_001)) == "리셋 확인 필요")
        try expect(window.remainingPercent == 0)
    }

    func shortWindowIsNotMislabeledAsWeekly() throws {
        let bucket = try decode("{\"primary\":{\"windowDurationMins\":15,\"usedPercent\":25}}", as: RateLimitBucket.self)
        try expect(bucket.featuredWindow?.title == "15분")
    }

    func missingTokenDayDiffersFromZero() throws {
        let tokens = try decode("""
        {"dailyUsageBuckets":[{"startDate":"2026-09-10","tokens":0},
         {"startDate":"2026-09-09","tokens":4000000000}]}
        """, as: TokenUsage.self)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10))!
        try expect(tokens.tokens(on: date, calendar: calendar) == 0)
        try expect(tokens.tokens(on: date.addingTimeInterval(86_400), calendar: calendar) == nil)
        try expect(tokens.tokens(on: date.addingTimeInterval(-86_400), calendar: calendar) == 4_000_000_000)
    }

    func nullTokenSummaryAndFormatting() throws {
        let value = try decode("{\"dailyUsageBuckets\":null}", as: TokenUsage.self)
        try expect(value.tokens(on: .now) == nil)
        try expect(UsageFormatting.tokens(nil) == "—")
        try expect(UsageFormatting.tokens(0) == "0")
        try expect(UsageFormatting.tokens(12_860_000) == "1286만")
    }

    func invalidExecutableOverrideIsAnError() throws {
        try expectThrows(UsageError.codexNotFound) {
            _ = try CodexExecutable.locate(environment: ["COCOUNT_CODEX_PATH": "/nonexistent/cocount/codex"])
        }
    }
}
