import Foundation

struct LocalTokenTests {
    private let start = ISO8601DateFormatter().date(from: "2026-09-11T00:00:00Z")!

    private func event(_ timestamp: String, total: Int64, last: Int64) -> String {
        "{\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":\(total),\"input_tokens\":\(total),\"output_tokens\":0},\"last_token_usage\":{\"total_tokens\":\(last)}}}}"
    }

    func cumulativeAndRepeatedEvents() throws {
        var reader = TokenEventAccumulator(start: start, end: start.addingTimeInterval(86_400))
        reader.consume(Data(event("2026-09-11T10:00:00Z", total: 100, last: 100).utf8))
        let next = Data(event("2026-09-11T10:01:00Z", total: 150, last: 50).utf8)
        reader.consume(next)
        reader.consume(next)
        try expect(reader.samples.values.reduce(0, +) == 150)
    }

    func dayBoundaryAndForkBaseline() throws {
        var reader = TokenEventAccumulator(start: start, end: start.addingTimeInterval(86_400))
        reader.consume(Data(event("2026-09-10T23:59:00Z", total: 1_000, last: 1_000).utf8))
        reader.consume(Data(event("2026-09-11T00:00:00Z", total: 1_030, last: 30).utf8))
        reader.consume(Data(event("2026-09-12T00:00:00Z", total: 1_100, last: 70).utf8))
        try expect(reader.samples.values.reduce(0, +) == 30)
        var fork = TokenEventAccumulator(start: start, end: start.addingTimeInterval(86_400))
        fork.consume(Data(event("2026-09-11T10:00:00Z", total: 1_000_000, last: 25).utf8))
        fork.consume(Data(event("2026-09-11T10:01:00Z", total: 1_000_005, last: 5).utf8))
        try expect(fork.samples.values.reduce(0, +) == 30)
        fork.consume(Data(event("2026-09-11T10:02:00Z", total: 20, last: 20).utf8))
        try expect(fork.samples.values.reduce(0, +) == 50 && fork.isPartial)
    }

    func comparisonAndStaleDay() throws {
        try expect(TodayTokenEstimate.comparison(today: 250, yesterday: 1_000) == "어제 대비 25%")
        try expect(TodayTokenEstimate.comparison(today: 1_500, yesterday: 1_000) == "어제 대비 150%")
        try expect(TodayTokenEstimate.comparison(today: 0, yesterday: 1_000) == "어제 대비 0%")
        try expect(TodayTokenEstimate.comparison(today: 500, yesterday: 0) == "어제 대비 —")
        try expect(TodayTokenEstimate.comparison(today: nil, yesterday: 1_000) == "어제 대비 —")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        try expect(TodayTokenEstimate.tenMinuteIndex(at: start, calendar: calendar) == 54)
        try expect(TodayTokenEstimate.tenMinuteIndex(at: start.addingTimeInterval(599), calendar: calendar) == 54)
        try expect(TodayTokenEstimate.tenMinuteIndex(at: start.addingTimeInterval(600), calendar: calendar) == 55)
        try expect(TodayTokenEstimate.tenMinuteIndex(at: start.addingTimeInterval(54_000), calendar: calendar) == 0)
        let sample = TodayTokenEstimate(tokens: 150, date: start, tenMinuteTokens: Array(repeating: 0, count: 144))
        try expect(sample.tenMinuteBins(on: start.addingTimeInterval(86_400)) == nil)
        try expect(sample.value(on: start.addingTimeInterval(86_400)) == nil)
    }

    func fileScanningAndCache() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let directory = root.appendingPathComponent("sessions")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("one.jsonl")
        let copy = directory.appendingPathComponent("fork.jsonl")
        let text = event("2026-09-11T10:00:00Z", total: 100, last: 100) + "\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        try text.write(to: copy, atomically: true, encoding: .utf8)
        let estimator = LocalTokenEstimator(root: root)
        let now = start.addingTimeInterval(43_200)
        let first = try await estimator.estimate(now: now)
        try expect(first.tokens == 100)
        try expect(first.tenMinuteTokens?.count == 144)
        try expect(first.tenMinuteTokens?.reduce(0, +) == 100)
        let eventDate = start.addingTimeInterval(36_000)
        try expect(first.tenMinuteTokens?[TodayTokenEstimate.tenMinuteIndex(at: eventDate)] == 100)
        let cached = try await estimator.estimate(now: now)
        try expect(cached.tokens == first.tokens)
        try expect(cached.tenMinuteTokens == first.tenMinuteTokens)
        let append = event("2026-09-11T10:01:00Z", total: 120, last: 20)
        try (text + append).write(to: file, atomically: true, encoding: .utf8)
        let pending = try await estimator.estimate(now: now)
        try expect(pending.tokens == 100)
        try (text + append + "\n").write(to: file, atomically: true, encoding: .utf8)
        let updated = try await estimator.estimate(now: now)
        try expect(updated.tokens == 120)
        try expect(updated.tenMinuteTokens?.reduce(0, +) == 120)
        let unavailable = try await LocalTokenEstimator(root: root.appendingPathComponent("missing")).estimate(now: now)
        try expect(unavailable.tokens == nil)
        try expect(unavailable.tenMinuteTokens == nil)
    }
    func incrementalAppendRewriteAndBoundedTail() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cocount-incremental-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let directory = root.appendingPathComponent("sessions")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("live.jsonl")
        let now = Date.now
        let timestamp = ISO8601DateFormatter().string(from: now)
        let first = event(timestamp, total: 100, last: 100) + "\n"
        let filler = String(repeating: "{\"message\":\"" + String(repeating: "x", count: 16_384) + "\"}\n", count: 128)
        try (first + filler).write(to: file, atomically: true, encoding: .utf8)
        let estimator = LocalTokenEstimator(root: root)
        let initial = try await estimator.estimate(now: now)
        try expect(initial.tokens == 100)
        let cached = try await estimator.estimate(now: now)
        let cachedIO = await estimator.lastScan
        try expect(cached.tokens == 100 && cachedIO.bytesRead == 0 && cachedIO.cachedFiles == 1)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let second = event(timestamp, total: 120, last: 20)
        try handle.write(contentsOf: Data(second.utf8))
        let pending = try await estimator.estimate(now: now)
        try expect(pending.tokens == 100)
        try handle.write(contentsOf: Data("\n".utf8))
        let appended = try await estimator.estimate(now: now)
        let appendIO = await estimator.lastScan
        try expect(appended.tokens == 120 && appended.tenMinuteTokens?.reduce(0, +) == 120)
        try expect(appendIO.appendedFiles == 1 && appendIO.fullFiles == 0 && appendIO.bytesRead < 20_000)

        // Truncation in place must discard the old cumulative counter.
        try handle.truncate(atOffset: 0)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data((event(timestamp, total: 7, last: 7) + "\n").utf8))
        let truncated = try await estimator.estimate(now: now)
        try expect(truncated.tokens == 7)
        // Replacement can have the same length and modification timestamp.
        let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        try (event(timestamp, total: 8, last: 8) + "\n").write(to: file, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        let replaced = try await estimator.estimate(now: now)
        try expect(replaced.tokens == 8)

        // A growing oversized line is discarded with a bounded cursor; the next event survives.
        let current = try FileHandle(forWritingTo: file)
        defer { try? current.close() }
        try current.seekToEnd()
        try current.write(contentsOf: Data(String(repeating: "x", count: 700_000).utf8))
        let oversized = try await estimator.estimate(now: now)
        try expect(oversized.tokens == 8 && oversized.isPartial)
        try current.write(contentsOf: Data(("tail\n" + event(timestamp, total: 11, last: 3) + "\n").utf8))
        let recovered = try await estimator.estimate(now: now)
        let tailIO = await estimator.lastScan
        try expect(recovered.tokens == 11 && tailIO.bytesRead < 20_000)
        await estimator.clearCache()
        let fresh = try await estimator.estimate(now: now)
        try expect(fresh.tokens == recovered.tokens && fresh.tenMinuteTokens == recovered.tenMinuteTokens)

        // A rewrite that grows the same inode is not an append when its boundary changes.
        try current.truncate(atOffset: 0)
        try current.seek(toOffset: 0)
        let rewritten = event(timestamp, total: 1_000_000, last: 5) + "\n" + filler
            + event(timestamp, total: 1_000_010, last: 10) + "\n"
        try current.write(contentsOf: Data(rewritten.utf8))
        let grownRewrite = try await estimator.estimate(now: now)
        let rewriteIO = await estimator.lastScan
        try expect(grownRewrite.tokens == 15 && rewriteIO.fullFiles == 1)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        let nextDay = try await estimator.estimate(now: tomorrow)
        try expect(nextDay.tokens == 0)

        try fm.removeItem(at: file)
        let removed = try await estimator.estimate(now: now)
        try expect(removed.tokens == 0)
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await estimator.estimate(now: now)
        }
        do { _ = try await canceled.value; try expect(false) }
        catch is CancellationError {}
    }

}
