import Foundation
import CryptoKit

/// A closed interval on an absolute time axis. A local day usually has 96 quarters;
/// DST and time-zone changes can produce shorter or longer intervals.
public struct LimitUsageDay: Codable, Sendable, Equatable {
    public let id: UUID
    public let start: Date
    public let end: Date
    public let timeZoneID: String
    public let windows: [Window]
    public var fileName: String { "day-\(id.uuidString.lowercased()).bin" }

    public struct Window: Codable, Sendable, Equatable {
        public let minutes: Int
        public let used: [Double]
        public let observed: [Double]
        enum CodingKeys: String, CodingKey { case minutes, samples }

        init(minutes: Int, bins: [LimitUsageHistory.Bin]) {
            self.minutes = minutes
            used = bins.map { $0.usedPercent ?? 0 }
            observed = bins.map(\.observedSeconds)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(minutes, forKey: .minutes)
            var bytes = Data()
            bytes.reserveCapacity(used.count * 16)
            for index in used.indices {
                for value in [used[index], observed[index]] {
                    var bits = value.bitPattern.littleEndian
                    withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
                }
            }
            try container.encode(bytes, forKey: .samples)
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            minutes = try container.decode(Int.self, forKey: .minutes)
            let bytes = try container.decode(Data.self, forKey: .samples)
            guard minutes > 0, !bytes.isEmpty, bytes.count % 16 == 0, bytes.count <= 104 * 16 else {
                throw HistoryStorageError.invalidArchive
            }
            var amounts: [Double] = []
            var coverage: [Double] = []
            for index in stride(from: 0, to: bytes.count, by: 8) {
                let bits = bytes[index..<index + 8].enumerated().reduce(UInt64(0)) {
                    $0 | UInt64($1.element) << ($1.offset * 8)
                }
                let value = Double(bitPattern: bits)
                guard value.isFinite, value >= 0 else { throw HistoryStorageError.invalidArchive }
                if index % 16 == 0 { amounts.append(value) }
                else {
                    guard value <= 900.000_001 else { throw HistoryStorageError.invalidArchive }
                    coverage.append(value)
                }
            }
            used = amounts
            observed = coverage
        }
    }

    init(history: LimitUsageHistory, interval: DateInterval, calendar: Calendar) {
        id = UUID()
        start = interval.start
        end = interval.end
        timeZoneID = calendar.timeZone.identifier
        var intervals: [DateInterval] = []
        var cursor = start
        while cursor < end {
            let next = min(cursor.addingTimeInterval(900), end)
            intervals.append(DateInterval(start: cursor, end: next))
            cursor = next
        }
        let minutes = Set(history.observations.flatMap { $0.windows.map(\.minutes) })
        windows = minutes.sorted().compactMap { minutes in
            let bins = history.bins(intervals, minutes: minutes)
            guard bins.contains(where: { $0.observedSeconds > 0 }) else { return nil }
            return Window(minutes: minutes, bins: bins)
        }
    }

    public func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        var data = try encoder.encode(self)
        data.append(contentsOf: SHA256.hash(data: data))
        return data
    }

    public static func decode(_ data: Data) throws -> LimitUsageDay {
        guard data.count > 32, data.count <= 256 * 1_024 else { throw HistoryStorageError.invalidArchive }
        let payload = data.dropLast(32)
        guard Data(SHA256.hash(data: payload)) == data.suffix(32) else { throw HistoryStorageError.invalidArchive }
        let value = try PropertyListDecoder().decode(Self.self, from: payload)
        let duration = value.end.timeIntervalSince(value.start)
        guard value.start.timeIntervalSince1970.isFinite, value.end.timeIntervalSince1970.isFinite,
              duration > 0, duration <= 26 * 3_600, TimeZone(identifier: value.timeZoneID) != nil,
              value.windows.count <= 64, Set(value.windows.map(\.minutes)).count == value.windows.count,
              value.windows.allSatisfy({ window in
                  window.used.count == Int(ceil(duration / 900)) && window.observed.indices.allSatisfy {
                      window.observed[$0] <= min(900, duration - Double($0) * 900) + 0.000_001
                          && (window.observed[$0] > 0 || window.used[$0] == 0)
                  }
              }) else {
            throw HistoryStorageError.invalidArchive
        }
        return value
    }
}

public enum HistoryStorageError: Error {
    case invalidArchive
}
