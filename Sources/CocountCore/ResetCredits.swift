import Foundation

public struct ResetCredits: Decodable, Sendable {
    public let availableCount: Int?
    public let credits: [ResetCredit]?

    // The server count is authoritative; detail rows may be truncated or absent.
    public var count: Int? { availableCount.flatMap { $0 >= 0 ? $0 : nil } }
    public var available: [ResetCredit] {
        (credits ?? []).filter { $0.status == "available" && $0.resetType == "codexRateLimits" }
            .sorted {
                if $0.expiresAt == $1.expiresAt { return $0.id < $1.id }
                return ($0.expiresAt ?? .infinity) < ($1.expiresAt ?? .infinity)
            }
    }

    public static func demo(now: Date) -> ResetCredits {
        ResetCredits(availableCount: 3, credits: [3, 10, 24].enumerated().map { index, days in
            ResetCredit(id: "demo-\(index)", resetType: "codexRateLimits", status: "available",
                        grantedAt: now.addingTimeInterval(Double(days - 30) * 86_400).timeIntervalSince1970,
                        expiresAt: now.addingTimeInterval(Double(days) * 86_400).timeIntervalSince1970)
        })
    }
}

public struct ResetCredit: Decodable, Identifiable, Sendable {
    public let id: String
    public let resetType: String
    public let status: String
    public let grantedAt: TimeInterval?
    public let expiresAt: TimeInterval?
    public var expiryDate: Date? { expiresAt.map(Date.init(timeIntervalSince1970:)) }

    /// One block is 24 hours. Fill remaining time from the left, including a partial day.
    public func dayBlocks(at now: Date) -> [Double] {
        guard let grantedAt, let expiresAt else { return [] }
        let duration = expiresAt - grantedAt
        guard duration.isFinite, duration > 0, duration <= 86_400 * 3_660 else { return [] }
        let remaining = min(duration, max(0, expiresAt - now.timeIntervalSince1970))
        return (0..<Int(ceil(duration / 86_400))).map { index in
            let offset = Double(index) * 86_400
            let blockDuration = min(86_400, duration - offset)
            return min(1, max(0, (remaining - offset) / blockDuration))
        }
    }

    public func remainingFraction(at now: Date) -> Double? {
        guard let grantedAt, let expiresAt, expiresAt > grantedAt else { return nil }
        return min(1, max(0, (expiresAt - now.timeIntervalSince1970) / (expiresAt - grantedAt)))
    }

    public func remainingLabel(at now: Date) -> String {
        guard let expiryDate else { return "만료 없음" }
        let seconds = expiryDate.timeIntervalSince(now)
        guard seconds > 0 else { return "만료 · 갱신 필요" }
        let hours = Int(ceil(seconds / 3_600))
        if hours >= 24 { return "\(hours / 24)일 \(hours % 24)시간" }
        if seconds >= 3_600 { return "\(hours)시간" }
        return "\(max(1, Int(ceil(seconds / 60))))분"
    }
}
