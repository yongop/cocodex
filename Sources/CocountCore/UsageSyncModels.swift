import Foundation
import CryptoKit

/// Content-free identity shared by copied/forked log events on every machine.
public struct TokenUsageEvent: Codable, Equatable, Sendable {
    public let id: String
    public let date: Date
    public let tokens: Int64
}

public struct UsageSyncDevice: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let lastSeen: Date
    public let isCurrentDevice: Bool
}

public struct UsageSyncResult: Sendable {
    public var limits: LimitUsageHistory
    public var periods: PeriodHistory
    public var estimate: TodayTokenEstimate?
    public var devices: [UsageSyncDevice] = []
    public var issue: String?
    public var folder: URL?
}

/// A single writer owns each (account, device, UTC day) shard. Received shards are never exported.
struct UsageSyncDay: Codable, Equatable, Sendable {
    var version = 1
    let account: String
    let device: String
    var name: String
    let day: Int
    var observations: [LimitUsageHistory.Observation] = []
    var tokens: [TokenUsageEvent] = []
    var tokenScan: Date?
    var tokenPartial = false
    var legacy: [LimitUsageDay] = []

    static func number(_ date: Date) -> Int { Int(floor(date.timeIntervalSince1970 / 86_400)) }
    var lastSeen: Date { max(observations.last?.date ?? .distantPast, tokenScan ?? .distantPast) }

    private func contains(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds >= Double(day) * 86_400 && seconds < (Double(day) + 1) * 86_400
    }

    func validate(account expectedAccount: String, device expectedDevice: String, day expectedDay: Int) throws {
        guard version == 1, account == expectedAccount, device == expectedDevice, day == expectedDay,
              name.count <= 100, observations.count <= 3_000, tokens.count <= 100_000, legacy.count <= 4,
              zip(observations, observations.dropFirst()).allSatisfy({ $0.date < $1.date }),
              observations.allSatisfy({ observation in
                  observation.date.timeIntervalSince1970.isFinite && contains(observation.date)
                    && observation.windows.count <= 4
                    && Set(observation.windows.map(\.minutes)).count == observation.windows.count
                    && observation.windows.allSatisfy {
                        $0.minutes > 0 && $0.minutes <= 525_600 && $0.remaining.isFinite
                          && (0...100).contains($0.remaining) && $0.reset.timeIntervalSince1970.isFinite
                          && $0.reset > observation.date
                    }
              }),
              tokens.allSatisfy({ $0.date.timeIntervalSince1970.isFinite && contains($0.date)
                  && $0.tokens > 0 && Data(base64Encoded: $0.id)?.count == 32 }),
              Set(tokens.map(\.id)).count == tokens.count,
              tokenScan.map({ $0.timeIntervalSince1970.isFinite && contains($0) }) ?? true
        else { throw UsageSyncError.invalidFile }
        // Validate archived summaries using the existing bounded, checksummed codec.
        for summary in legacy {
            guard summary.start.timeIntervalSince1970.isFinite, contains(summary.start) else {
                throw UsageSyncError.invalidFile
            }
            _ = try LimitUsageDay.decode(summary.encoded())
        }
    }
}

enum UsageSyncError: Error { case invalidFile, busy, unavailable }

extension TodayTokenEstimate {
    static func merged(_ events: [TokenUsageEvent], now: Date, available: Bool, partial: Bool,
                       calendar: Calendar = .current) -> TodayTokenEstimate {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        var unique: [String: TokenUsageEvent] = [:]
        for event in events where event.date >= start && event.date < end {
            if event.tokens > (unique[event.id]?.tokens ?? 0) { unique[event.id] = event }
        }
        var total: Int64 = 0
        var bins = Array(repeating: Int64(0), count: 144)
        for event in unique.values {
            let next = total.addingReportingOverflow(event.tokens)
            guard !next.overflow else { return .init(tokens: nil, date: now, isPartial: true) }
            total = next.partialValue
            bins[tenMinuteIndex(at: event.date, calendar: calendar)] += event.tokens
        }
        return .init(tokens: available ? total : nil, date: now, isPartial: partial,
                     tenMinuteTokens: available ? bins : nil)
    }
}

func usageSyncDigest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}
