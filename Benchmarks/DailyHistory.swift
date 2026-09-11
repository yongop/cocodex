import Foundation

@main
struct DailyHistoryBenchmark {
    static func main() async throws {
        let suite = "local.cocount.rollup-benchmark.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cocount-rollup-benchmark-\(UUID())")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = Date(timeIntervalSince1970: 1_783_296_000)
        let today = start.addingTimeInterval(8 * 86400)
        let encoder = JSONEncoder()
        for cadence in [1, 5, 15] {
            let key = "cadence-\(cadence)"
            let step = Double(cadence * 60)
            var history = LimitUsageHistory()
            // Nine calendar dates: eight full past days and a nearly full current day.
            for index in 0..<Int(9 * 86400 / step) {
                let elapsed = Double(index) * step
                let date = start.addingTimeInterval(elapsed)
                let week = floor(elapsed / (7 * 86400))
                let window = LimitUsageHistory.Window(minutes: 10080,
                    remaining: 100 - (elapsed - week * 7 * 86400) / (7 * 86400) * 80,
                    reset: start.addingTimeInterval((week + 1) * 7 * 86400))
                history.recordObservation(.init(date: date, windows: [window]))
            }
            let legacy = try encoder.encode(history)
            defaults.set(legacy, forKey: "limitUsageHistory.v1.\(key)")
            let provider = UsageHistoryPersistence(suiteName: suite, root: root)
            let nextDate = today.addingTimeInterval(86400 - step / 2)
            let limits = try JSONDecoder().decode(RateLimitBucket.self, from: Data("""
            {"primary":{"usedPercent":22.85,"windowDurationMins":10080,"resetsAt":\(start.addingTimeInterval(14 * 86400).timeIntervalSince1970)}}
            """.utf8))
            let began = ProcessInfo.processInfo.systemUptime
            let first = try await provider.record(UsageSnapshot(limits: limits, tokens: nil,
                fetchedAt: nextDate, historyKey: key), calendar: calendar)
            precondition(first.storageIssue == nil)
            let initial = await provider.lastWrite
            let elapsed = (ProcessInfo.processInfo.systemUptime - began) * 1000
            let folder = await provider.directory(for: key)
            let total = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
                .reduce(0) { try $0 + $1.resourceValues(forKeys: [.fileSizeKey]).fileSize! }
            let last = try await provider.record(UsageSnapshot(limits: limits, tokens: nil,
                fetchedAt: nextDate.addingTimeInterval(1), historyKey: key), calendar: calendar)
            precondition(last.storageIssue == nil)
            let routine = await provider.lastWrite
            precondition(routine.archiveBytes == 0 && routine.archiveFiles == 0)
            let encoderStart = ProcessInfo.processInfo.systemUptime
            for _ in 0..<20 { _ = try encoder.encode(history) }
            let oldMs = (ProcessInfo.processInfo.systemUptime - encoderStart) * 1000 / 20
            let activeStart = ProcessInfo.processInfo.systemUptime
            for _ in 0..<20 { _ = try encoder.encode(last.limits) }
            let activeMs = (ProcessInfo.processInfo.systemUptime - activeStart) * 1000 / 20
            print("\(cadence)m: raw \(history.observations.count) records / \(legacy.count) bytes → active \(first.limits.observations.count) records / \(initial.activeBytes) bytes; archives \(first.limits.closedDays.count) files / \(initial.archiveBytes) bytes; total \(total) bytes")
            print(String(format: "  One-time migration %.2f ms; raw encoding %.3f → %.3f ms; next refresh archive writes %d bytes", elapsed, oldMs, activeMs, routine.archiveBytes))
        }
    }
}
