import Foundation
import Darwin
import CryptoKit

public struct TodayTokenEstimate: Sendable {
    public let tokens: Int64?
    public let date: Date
    public let isPartial: Bool
    public let tenMinuteTokens: [Int64]? 

    public init(tokens: Int64?, date: Date, isPartial: Bool = false, tenMinuteTokens: [Int64]? = nil) {
        self.tokens = tokens
        self.date = date
        self.isPartial = isPartial
        self.tenMinuteTokens = tenMinuteTokens?.count == 144 ? tenMinuteTokens : nil
    }

    public func value(on day: Date) -> Int64? {
        Calendar.current.isDate(date, inSameDayAs: day) ? tokens : nil
    }

    /// Fixed local-clock axis: repeated DST intervals merge; skipped intervals remain empty.
    public static func tenMinuteIndex(at date: Date, calendar: Calendar = .current) -> Int {
        calendar.component(.hour, from: date) * 6 + calendar.component(.minute, from: date) / 10
    }

    public func tenMinuteBins(on day: Date) -> [Int64]? {
        Calendar.current.isDate(date, inSameDayAs: day) ? tenMinuteTokens : nil
    }

    public static func comparison(today: Int64?, yesterday: Int64?) -> String {
        guard let today, today >= 0, let yesterday, yesterday > 0 else { return "어제 대비 —" }
        return String(format: "어제 대비 %.0f%%", Double(today) / Double(yesterday) * 100)
    }
}

/// Reads only token events, off the main actor. Cache contains counters, never conversation text.
public actor LocalTokenEstimator {
    private let root: URL
    private var cache: [URL: CachedFile] = [:]
    private var cachedDay: Date?
    private var cachedTimeZone: TimeZone?
    /// Content-free I/O counters for diagnostics and reproducible performance checks.
    public struct ScanMetrics: Sendable {
        public fileprivate(set) var bytesRead = 0
        public fileprivate(set) var fullFiles = 0
        public fileprivate(set) var appendedFiles = 0
        public fileprivate(set) var cachedFiles = 0
    }
    public private(set) var lastScan = ScanMetrics()

    public func clearCache() {
        cache.removeAll()
        cachedDay = nil
    }

    public init(root: URL? = nil) {
        self.root = root ?? URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path)
    }

    public func estimate(now: Date = .now) throws -> TodayTokenEstimate {
        try Task.checkCancellation()
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        lastScan = ScanMetrics()
        if cachedDay != start || cachedTimeZone != calendar.timeZone {
            cache.removeAll(); cachedDay = start; cachedTimeZone = calendar.timeZone
        }
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey]
        var seen: Set<URL> = []
        var samples: [Data: Int64] = [:]
        var dates: [Data: Date] = [:]
        var partial = false
        var readableRoot = false
        var failures = 0

        for folder in ["sessions", "archived_sessions"] {
            let directory = root.appendingPathComponent(folder)
            guard fm.fileExists(atPath: directory.path) else { continue }
            var enumerationFailed = false
            guard let files = fm.enumerator(at: directory, includingPropertiesForKeys: Array(keys),
                                            options: [.skipsHiddenFiles], errorHandler: { _, _ in
                enumerationFailed = true
                return true
            }) else { failures += 1; continue }
            readableRoot = true
            for case let file as URL in files {
                try Task.checkCancellation()
                guard file.pathExtension == "jsonl" else { continue }
                do {
                    let attributes = try file.resourceValues(forKeys: keys)
                    guard attributes.isRegularFile == true,
                          let modified = attributes.contentModificationDate, modified >= start,
                          let size = attributes.fileSize else { continue }
                    seen.insert(file)
                    let identity = attributes.fileResourceIdentifier as? NSObject
                    let entry: CachedFile
                    if let saved = cache[file], saved.size == size && saved.modified == modified,
                       saved.identity == identity {
                        entry = saved
                        lastScan.cachedFiles += 1
                    } else {
                        // Remove before mutation so accumulated dictionaries keep unique storage.
                        let saved = cache.removeValue(forKey: file)
                        entry = try parse(file, size: size, modified: modified, identity: identity,
                                          previous: saved, start: start, end: end)
                        cache[file] = entry
                    }
                    partial = partial || entry.result.isPartial
                    // Identical inherited/forked events can occur in multiple session files.
                    for (key, value) in entry.result.samples {
                        samples[key] = max(samples[key] ?? 0, value)
                        dates[key] = entry.result.dates[key]
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { failures += 1; cache.removeValue(forKey: file) }
            }
            if enumerationFailed { failures += 1 }
        }
        cache = cache.filter { seen.contains($0.key) }
        var total: Int64 = 0
        var tenMinuteBins = Array(repeating: Int64(0), count: 144)
        for (key, amount) in samples {
            let sum = total.addingReportingOverflow(amount)
            guard !sum.overflow else { return TodayTokenEstimate(tokens: nil, date: now, isPartial: true) }
            total = sum.partialValue
            if let date = dates[key] {
                tenMinuteBins[TodayTokenEstimate.tenMinuteIndex(at: date, calendar: calendar)] += amount
            }
        }
        return TodayTokenEstimate(tokens: !readableRoot || (samples.isEmpty && failures > 0) ? nil : total,
                                  date: now, isPartial: partial || failures > 0,
                                  tenMinuteTokens: !readableRoot || (samples.isEmpty && failures > 0) ? nil : tenMinuteBins)
    }

    private struct CachedFile {
        let size: Int
        let modified: Date
        let identity: NSObject?
        let fingerprint: Data
        let offset: UInt64
        let droppingLine: Bool
        let result: TokenEventAccumulator
    }

    /// Fingerprint only the boundaries; cached bytes are hashes, never conversation text.
    /// Session logs are append-only. Replacement, truncation and boundary rewrites restart parsing.
    private func fingerprint(_ handle: FileHandle, size: Int) throws -> Data {
        var bytes = Data()
        try handle.seek(toOffset: 0)
        let first = try handle.read(upToCount: min(size, 4_096)) ?? Data()
        bytes.append(first)
        if size > 4_096 {
            try handle.seek(toOffset: UInt64(max(4_096, size - 4_096)))
            bytes.append(try handle.read(upToCount: min(size - 4_096, 4_096)) ?? Data())
        }
        lastScan.bytesRead += bytes.count
        return Data(SHA256.hash(data: bytes))
    }

    private func parse(_ file: URL, size: Int, modified: Date, identity: NSObject?,
                       previous: CachedFile?, start: Date, end: Date) throws -> CachedFile {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var result: TokenEventAccumulator
        var offset: UInt64 = 0
        var droppingLine = false
        if let previous, identity != nil, previous.identity == identity, size > previous.size,
           try fingerprint(handle, size: previous.size) == previous.fingerprint {
            result = previous.result
            offset = previous.offset
            droppingLine = previous.droppingLine
            lastScan.appendedFiles += 1
        } else {
            result = TokenEventAccumulator(start: start, end: end)
            lastScan.fullFiles += 1
        }
        try handle.seek(toOffset: offset)
        var position = offset
        var buffer = Data()
        let maximumLineSize = 524_288
        // Bound a scan to the observed file size even if Codex keeps appending.
        while position < UInt64(size) {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: min(65_536, size - Int(position))),
                  !chunk.isEmpty else { throw UsageError.disconnected }
            lastScan.bytesRead += chunk.count
            position += UInt64(chunk.count)
            buffer.append(chunk)
            // memchr avoids a Swift Data subscript for every byte of large prompt lines.
            let consumed = buffer.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int in
                guard let base = bytes.baseAddress else { return 0 }
                var cursor = 0
                while cursor < bytes.count,
                      let newline = memchr(base.advanced(by: cursor), 0x0A, bytes.count - cursor) {
                    let end = base.distance(to: UnsafeRawPointer(newline))
                    if !droppingLine {
                        if end - cursor <= maximumLineSize {
                            autoreleasepool {
                                result.consume(Data(bytes: base.advanced(by: cursor), count: end - cursor))
                            }
                        } else { result.markPartial() }
                    }
                    droppingLine = false
                    cursor = end + 1
                }
                return cursor
            }
            buffer.removeFirst(consumed)
            offset = position - UInt64(buffer.count)
            if buffer.count > maximumLineSize || droppingLine {
                result.markPartial()
                buffer.removeAll(keepingCapacity: true)
                droppingLine = true
                offset = position
            }
        }
        // Reread only the incomplete tail next time, without retaining its text in the cache.
        let digest = try fingerprint(handle, size: size)
        return CachedFile(size: size, modified: modified, identity: identity, fingerprint: digest,
                          offset: offset, droppingLine: droppingLine, result: result)
    }
}

struct TokenEventAccumulator {
    let start: Date
    let end: Date
    private(set) var samples: [Data: Int64] = [:]
    private(set) var isPartial = false
    private(set) var dates: [Data: Date] = [:]
    private var previousTotal: Int64?
    private let decoder = JSONDecoder()
    private let fractional = ISO8601DateFormatter()
    private let plain = ISO8601DateFormatter()

    init(start: Date, end: Date) {
        self.start = start
        self.end = end
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    mutating func markPartial() { isPartial = true }

    private static let tokenMarker = Data("\"token_count\"".utf8)

    mutating func consume(_ line: Data) {
        guard line.range(of: Self.tokenMarker) != nil else { return }
        guard let event = try? decoder.decode(Event.self, from: line), event.payload.type == "token_count" else {
            isPartial = true
            return
        }
        guard let info = event.payload.info else { return }
        let current = info.total_token_usage?.total_tokens
        let last = info.last_token_usage?.total_tokens
        let delta: Int64
        if let current, current >= 0 {
            if let previousTotal, current >= previousTotal {
                delta = current - previousTotal
            } else {
                // First event may include a fork's inherited counter. Count only its last turn.
                delta = min(current, max(0, last ?? 0))
                if last == nil || previousTotal != nil { isPartial = true }
            }
            previousTotal = current
        } else {
            delta = max(0, last ?? 0)
            isPartial = true
        }
        guard let date = fractional.date(from: event.timestamp) ?? plain.date(from: event.timestamp) else {
            isPartial = true
            return
        }
        guard date >= start, date < end, delta > 0 else { return }
        let key = "\(date.timeIntervalSince1970)|\(current ?? -1)|\(last ?? -1)|\(info.total_token_usage?.input_tokens ?? -1)|\(info.total_token_usage?.output_tokens ?? -1)"
        let digest = Data(SHA256.hash(data: Data(key.utf8)))
        samples[digest] = max(samples[digest] ?? 0, delta)
        dates[digest] = date
    }

    private struct Event: Decodable {
        let timestamp: String
        let payload: Payload
        struct Payload: Decodable { let type: String; let info: Info? }
        struct Info: Decodable {
            let total_token_usage: Amount?
            let last_token_usage: Amount?
        }
        struct Amount: Decodable {
            let total_tokens: Int64?
            let input_tokens: Int64?
            let output_tokens: Int64?
        }
    }
}
