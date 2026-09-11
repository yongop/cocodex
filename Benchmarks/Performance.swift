import Foundation

@main
struct Performance {
    static func measure<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        let start = ProcessInfo.processInfo.systemUptime
        let value = try body()
        print(String(format: "%@: %.3f ms", label, (ProcessInfo.processInfo.systemUptime - start) * 1_000))
        return value
    }

    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cocount-benchmark-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let directory = root.appendingPathComponent("sessions")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("fixture.jsonl")
        let now = Date.now
        let day = Calendar.current.startOfDay(for: now)
        let formatter = ISO8601DateFormatter()
        func event(_ index: Int) -> String {
            let date = formatter.string(from: day.addingTimeInterval(Double(index)))
            return "{\"timestamp\":\"\(date)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":\(index * 10)},\"last_token_usage\":{\"total_tokens\":10}}}}\n"
        }
        let prompt = "{\"type\":\"response_item\",\"text\":\"" + String(repeating: "x", count: 16_384) + "\"}\n"
        try (1...1_000).map { prompt + event($0) }.joined().write(to: file, atomically: true, encoding: .utf8)
        print("Fixture: \((try fm.attributesOfItem(atPath: file.path))[.size]!) bytes; 1,000 token events")
        let estimator = LocalTokenEstimator(root: root)
        let start = ProcessInfo.processInfo.systemUptime
        let first = try await estimator.estimate(now: now)
        print(String(format: "Local initial: %.3f ms", (ProcessInfo.processInfo.systemUptime - start) * 1_000))
        precondition(first.tokens == 10_000)
        let cachedStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<10 { _ = try await estimator.estimate(now: now) }
        print(String(format: "Local unchanged (mean of 10): %.3f ms", (ProcessInfo.processInfo.systemUptime - cachedStart) * 100))
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let addition = Data(event(1_001).utf8)
        try handle.write(contentsOf: addition)
        let appendStart = ProcessInfo.processInfo.systemUptime
        let appended = try await estimator.estimate(now: now)
        print(String(format: "Local append (%d bytes): %.3f ms", addition.count, (ProcessInfo.processInfo.systemUptime - appendStart) * 1_000))
        precondition(appended.tokens == 10_010 && appended.tenMinuteTokens?.reduce(0, +) == 10_010)
        #if !BASELINE
        let io = await estimator.lastScan
        print("Append I/O: \(io.bytesRead) bytes, \(io.appendedFiles) appended, \(io.fullFiles) full files")
        #endif

        let observations = (0..<20_000).map { index in
            "{\"date\":\(index * 30),\"windows\":[{\"minutes\":10080,\"remaining\":\(100 - Double(index) / 250),\"reset\":700000}]}"
        }.joined(separator: ",")
        let data = Data("{\"observations\":[\(observations)]}".utf8)
        let history = try JSONDecoder().decode(LimitUsageHistory.self, from: data)
        let ending = Date(timeIntervalSinceReferenceDate: 599_970)
        let result = measure("20,000 observations, daily/hourly/quarter-hourly (20 iterations)") {
            var total = 0.0
            for _ in 0..<20 {
                total += history.daily(endingOn: ending, minutes: 10080).compactMap(\.usedPercent).reduce(0, +)
                total += history.hourly(on: ending, minutes: 10080).compactMap(\.usedPercent).reduce(0, +)
                total += history.quarterHourly(on: ending, minutes: 10080).compactMap(\.usedPercent).reduce(0, +)
            }
            return total
        }
        print(String(format: "Aggregation checksum: %.6f", result))
        let encoded = try measure("Encode 20,000 observations") { try JSONEncoder().encode(history) }
        print("History at cap: \(encoded.count) bytes")
        for cadence in [1, 5, 15] {
            let count = min(20_000, 8 * 24 * 60 / cadence + 1)
            // Average encoded bytes per observation; reports an estimate, not filesystem writes.
            let bytes = encoded.count * count / history.observations.count
            print("\(cadence)-minute cadence, 8-day steady history estimate: \(count) records, ~\(bytes) bytes; full rewrites ~\(bytes * (24 * 60 / cadence)) bytes/day")
        }

        var idle = LimitUsageHistory()
        var uncompacted: [LimitUsageHistory.Observation] = []
        for minute in stride(from: 0, through: 8 * 24 * 60, by: 5) {
            let limits = try JSONDecoder().decode(RateLimitBucket.self, from: Data("""
            {"primary":{"usedPercent":50,"windowDurationMins":10080,"resetsAt":2000000}}
            """.utf8))
            idle.record(UsageSnapshot(limits: limits, tokens: nil, fetchedAt: Date(timeIntervalSince1970: Double(minute * 60))))
            uncompacted.append(idle.observations.last!)
        }
        let compactData = try JSONEncoder().encode(idle)
        let originalData = try JSONEncoder().encode(["observations": uncompacted])
        print("8 idle days at 5 minutes: \(uncompacted.count) → \(idle.observations.count) records; \(originalData.count) → \(compactData.count) bytes")
    }
}
