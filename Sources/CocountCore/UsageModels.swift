import Foundation

public struct UsageWindow: Decodable, Equatable, Sendable {
    public let usedPercent: Double?
    public let windowDurationMins: Int?
    public let resetsAt: TimeInterval?

    public var remainingPercent: Double? {
        usedPercent.flatMap { $0.isFinite ? min(100, max(0, 100 - $0)) : nil }
    }

    public var resetDate: Date? { resetsAt.map(Date.init(timeIntervalSince1970:)) }

    public var title: String {
        guard let minutes = windowDurationMins, minutes > 0 else { return "사용 한도" }
        if minutes == 10_080 { return "이번 주" }
        if minutes.isMultiple(of: 1_440) { return "\(minutes / 1_440)일" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60)시간" }
        return "\(minutes)분"
    }
}

public struct RateLimitBucket: Decodable, Sendable {
    public let limitId: String?
    public let limitName: String?
    public let planType: String?
    public let primary: UsageWindow?
    public let secondary: UsageWindow?

    public var windows: [UsageWindow] { [primary, secondary].compactMap { $0 } }
    public var featuredWindow: UsageWindow? {
        windows.first { $0.windowDurationMins == 10_080 }
            ?? windows.max { ($0.windowDurationMins ?? 0) < ($1.windowDurationMins ?? 0) }
    }
    public var otherWindow: UsageWindow? { windows.first { $0 != featuredWindow } }
}

public struct RateLimitsResponse: Decodable, Sendable {
    public let rateLimits: RateLimitBucket?
    public let rateLimitsByLimitId: [String: RateLimitBucket]?
    public let rateLimitResetCredits: ResetCredits?

    // Never label a Spark or other model-specific bucket as the main Codex allowance.
    public var codex: RateLimitBucket? {
        if let buckets = rateLimitsByLimitId, !buckets.isEmpty {
            return buckets["codex"] ?? buckets.values.first { $0.limitId == "codex" }
        }
        guard let rateLimits, rateLimits.limitId == nil || rateLimits.limitId == "codex" else { return nil }
        return rateLimits
    }
}

public struct TokenUsage: Decodable, Sendable {
    public struct Day: Decodable, Identifiable, Sendable {
        public let startDate: String
        public let tokens: Int64?
        public var id: String { startDate }
    }

    public let dailyUsageBuckets: [Day]?

    // Date-only service buckets are kept as service dates, with no invented timezone conversion.
    public func tokens(on date: Date, calendar: Calendar = .current) -> Int64? {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let key = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return dailyUsageBuckets?.first { $0.startDate == key }?.tokens.flatMap { $0 >= 0 ? $0 : nil }
    }
}

public struct UsageSnapshot: Sendable {
    public let limits: RateLimitBucket
    public let tokens: TokenUsage?
    public let fetchedAt: Date
    public let tokenIssue: String?
    public let resetCredits: ResetCredits?
    public let historyKey: String?

    public init(limits: RateLimitBucket, tokens: TokenUsage?, fetchedAt: Date, tokenIssue: String? = nil,
                resetCredits: ResetCredits? = nil, historyKey: String? = nil) {
        self.limits = limits
        self.tokens = tokens
        self.fetchedAt = fetchedAt
        self.tokenIssue = tokenIssue
        self.resetCredits = resetCredits
        self.historyKey = historyKey
    }

    public static func demo(now: Date = .now) -> UsageSnapshot {
        let limits = RateLimitBucket(
            limitId: "codex", limitName: nil, planType: "pro",
            primary: UsageWindow(usedPercent: 18, windowDurationMins: 300,
                                 resetsAt: now.addingTimeInterval(7_920).timeIntervalSince1970),
            secondary: UsageWindow(usedPercent: 70, windowDurationMins: 10_080,
                                   resetsAt: now.addingTimeInterval(342_000).timeIntervalSince1970)
        )
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let values: [Int64] = [12_400_000, 18_900_000, 10_500_000, 24_800_000, 15_600_000, 39_130_000, 12_860_000]
        let days = values.enumerated().map { index, value in
            let date = Calendar.current.date(byAdding: .day, value: index - 6, to: now)!
            return TokenUsage.Day(startDate: formatter.string(from: date), tokens: value)
        }
        return UsageSnapshot(limits: limits, tokens: TokenUsage(dailyUsageBuckets: days),
                             fetchedAt: now, resetCredits: .demo(now: now))
    }
}

public enum UsageFormatting {
    public static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    public static func tokens(_ value: Int64?) -> String {
        guard let value, value >= 0 else { return "—" }
        if value >= 100_000_000 { return String(format: "%.1f억", Double(value) / 100_000_000) }
        if value >= 10_000 { return String(format: "%.0f만", Double(value) / 10_000) }
        return value.formatted()
    }

    public static func countdown(to date: Date?, now: Date = .now) -> String {
        guard let date else { return "리셋 시간 정보 없음" }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "리셋 확인 필요" }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes >= 1_440 { return "\(minutes / 1_440)일 \((minutes % 1_440) / 60)시간 후 리셋" }
        if minutes >= 60 { return "\(minutes / 60)시간 \(minutes % 60)분 후 리셋" }
        return "\(minutes)분 후 리셋"
    }
}
