import Foundation

struct UsageSyncTests {
    let account = String(repeating: "a", count: 64)
    let a = String(repeating: "1", count: 64)
    let b = String(repeating: "2", count: 64)
    let now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: .now)!

    func snapshot(_ date: Date, remaining: Double = 80, key: String? = nil, reset: Date? = nil) -> UsageSnapshot {
        UsageSnapshot(limits: RateLimitBucket(limitId: "codex", limitName: nil, planType: "pro",
            primary: UsageWindow(usedPercent: 100 - remaining, windowDurationMins: 10_080,
                                 resetsAt: (reset ?? now.addingTimeInterval(86_400)).timeIntervalSince1970), secondary: nil),
                      tokens: nil, fetchedAt: date, historyKey: "local", syncAccountKey: key ?? account)
    }
    func history(_ values: [(Date, Double)]) -> UsageHistories {
        var result = UsageHistories()
        for (date, remaining) in values { result.limits.record(snapshot(date, remaining: remaining)) }
        return result
    }
    func event(_ id: UInt8, tokens: Int64, date: Date? = nil) -> TokenUsageEvent {
        TokenUsageEvent(id: Data(repeating: id, count: 32).base64EncodedString(), date: date ?? now, tokens: tokens)
    }
    func estimate(_ events: [TokenUsageEvent], at date: Date? = nil) -> TodayTokenEstimate {
        TodayTokenEstimate(tokens: events.reduce(0) { $0 + $1.tokens }, date: date ?? now, events: events)
    }
    func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cocount-sync-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func engine(_ root: URL, _ id: String) -> UsageSyncEngine {
        UsageSyncEngine(localRoot: root.appendingPathComponent(id), cloudRoot: root.appendingPathComponent("cloud"),
                        deviceID: id, deviceName: id == a ? "MacBook" : "Mac mini")
    }
    func shard(_ root: URL, _ id: String, date: Date? = nil) -> URL {
        root.appendingPathComponent("cloud/\(account)/\(id)/\(UsageSyncDay.number(date ?? now)).json")
    }
    func exchange(_ engine: UsageSyncEngine, _ local: UsageHistories, _ events: [TokenUsageEvent],
                  at date: Date? = nil) async throws -> UsageSyncResult {
        try await engine.exchange(snapshot: snapshot(date ?? now), local: local,
                                  estimate: estimate(events, at: date), now: date ?? now)
    }

    func concurrentDevicesDeduplicateAndConverge() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = engine(root, a), second = engine(root, b)
        let t0 = now.addingTimeInterval(-600), t1 = now.addingTimeInterval(-300)
        let left = history([(t0, 90), (t1, 85), (now, 80)])
        let right = history([(t0, 90), (t1.addingTimeInterval(10), 88), (now, 80)])
        let shared = event(1, tokens: 100)
        async let r1 = exchange(first, left, [shared, event(2, tokens: 20)])
        async let r2 = exchange(second, right, [shared, event(3, tokens: 30)])
        _ = try await (r1, r2)
        let x = try await exchange(first, left, [shared, event(2, tokens: 20)])
        let y = try await exchange(second, right, [shared, event(3, tokens: 30)])
        try expect(x.estimate?.tokens == 150 && y.estimate?.tokens == 150)
        try expect(x.devices.count == 2 && y.devices.count == 2)
        let bins = x.limits.daily(endingOn: now, minutes: 10_080)
        try expect(abs((bins.last?.usedPercent ?? -1) - 10) < 0.00001)
        try expect(abs((bins.last?.observedSeconds ?? -1) - 600) < 0.00001)
        try expect(y.limits.daily(endingOn: now, minutes: 10_080).last?.usedPercent == bins.last?.usedPercent)
        // A receiver never republishes the peer's events in its own shard.
        let payload = try JSONDecoder().decode(UsageSyncDay.self, from: Data(contentsOf: shard(root, a)))
        try expect(payload.tokens.count == 2 && !payload.tokens.contains { $0.id == event(3, tokens: 30).id })
        print("PASS sync concurrent devices converge, deduplicate tokens, and count stale quota responses once")
    }

    func unchangedIOAndRestart() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = engine(root, a), second = engine(root, b)
        let local = history([(now.addingTimeInterval(-300), 85), (now, 80)])
        _ = try await exchange(first, local, [event(1, tokens: 100)])
        _ = try await exchange(second, local, [event(2, tokens: 100)])
        _ = try await exchange(first, local, [event(1, tokens: 100)])
        let file = shard(root, a)
        let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        for _ in 0..<5 {
            _ = try await exchange(first, local, [event(1, tokens: 100)])
            let io = await first.lastMetrics
            try expect(io.filesRead == 0 && io.localWrites == 0 && io.cloudWrites == 0)
        }
        let restarted = engine(root, a)
        let restored = try await exchange(restarted, local, [])
        let io = await restarted.lastMetrics
        try expect(restored.estimate?.tokens == 200 && io.cloudWrites == 0 && io.localWrites == 0)
        try expect(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
        print("PASS sync unchanged refreshes perform zero content reads/writes; restart preserves shards and counters")
    }

    func changedShardOnlyAndMidnight() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = engine(root, a), second = engine(root, b)
        let before = Date(timeIntervalSince1970: Double(UsageSyncDay.number(now)) * 86_400 - 60)
        _ = try await exchange(first, history([(before, 90)]), [event(1, tokens: 100, date: before)], at: before)
        let yesterdayFile = shard(root, a, date: before)
        let saved = try Data(contentsOf: yesterdayFile)
        _ = try await exchange(first, history([(before, 90), (now, 80)]), [event(2, tokens: 40)])
        try expect(try Data(contentsOf: yesterdayFile) == saved)
        _ = try await exchange(second, history([(now, 80)]), [event(3, tokens: 10)])
        let later = now.addingTimeInterval(60)
        _ = try await exchange(first, history([(now, 80), (later, 79)]), [event(2, tokens: 40), event(4, tokens: 60)], at: later)
        _ = try await exchange(second, history([(now, 80)]), [event(3, tokens: 10)], at: now)
        let io = await second.lastMetrics
        try expect(io.filesRead == 1 && io.cloudWrites == 0 && io.localWrites == 0)
        try expect(try Data(contentsOf: yesterdayFile) == saved)
        print("PASS sync reads only the changed peer shard and leaves the previous UTC day untouched")
    }

    func offlineRetryAndAccountIsolation() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cloud = root.appendingPathComponent("cloud")
        try Data("temporarily unavailable".utf8).write(to: cloud)
        let first = engine(root, a)
        let local = history([(now, 80)])
        let offline = try await exchange(first, local, [event(1, tokens: 100)])
        try expect(offline.issue != nil && offline.estimate?.tokens == 100)
        try FileManager.default.removeItem(at: cloud)
        let restored = engine(root, a)
        let online = try await exchange(restored, local, [])
        try expect(online.issue == nil && online.estimate?.tokens == 100)
        let other = String(repeating: "b", count: 64)
        let isolated = try await restored.exchange(snapshot: snapshot(now, key: other), local: UsageHistories(),
                                                   estimate: estimate([]), now: now)
        try expect(isolated.estimate?.tokens == 0 && isolated.devices.count == 1)
        let again = try await exchange(restored, local, [])
        try expect(again.estimate?.tokens == 100)
        print("PASS sync offline outbox survives restart and retries; account namespaces stay isolated")
    }

    func corruptPeerKeepsLastGoodAndRecovers() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = engine(root, a), second = engine(root, b)
        let local = history([(now, 80)])
        _ = try await exchange(first, local, [event(1, tokens: 100)])
        _ = try await exchange(second, local, [event(2, tokens: 30)])
        let file = shard(root, a)
        let valid = try Data(contentsOf: file)
        try Data("{partial".utf8).write(to: file, options: .atomic)
        let degraded = try await exchange(second, local, [event(2, tokens: 30)])
        try expect(degraded.issue != nil && degraded.estimate?.tokens == 130)
        _ = try await exchange(second, local, [event(2, tokens: 30)])
        let io = await second.lastMetrics
        try expect(io.filesRead == 0 && io.cloudWrites == 0)
        try valid.write(to: file, options: .atomic)
        let healed = try await exchange(second, local, [event(2, tokens: 30)])
        try expect(healed.issue == nil && healed.estimate?.tokens == 130)
        print("PASS sync partial/corrupt peer files retain last good data, avoid busy retries, and recover")
    }

    func legacyCoverageAndRawOverlay() throws {
        let start = Calendar.current.startOfDay(for: now).addingTimeInterval(-86_400)
        let mid = start.addingTimeInterval(900)
        let end = start.addingTimeInterval(1800)
        let left = history([(start, 90), (mid, 85)])
        let right = history([(mid, 85), (end, 80)])
        let interval = DateInterval(start: start, end: start.addingTimeInterval(86_400))
        let a = LimitUsageDay(history: left.limits, interval: interval, calendar: .current)
        let b = LimitUsageDay(history: right.limits, interval: interval, calendar: .current)
        let raw = history([(start, 90), (mid, 85)]).limits.observations
        let merged = LimitUsageHistory.merging(local: LimitUsageHistory(), observations: raw,
                                               archives: [a, a, b], now: now)
        let bins = merged.bins([DateInterval(start: start, end: end)], minutes: 10_080)
        try expect(abs((bins[0].usedPercent ?? -1) - 10) < 0.00001 && bins[0].observedSeconds == 1800)
        let reverse = LimitUsageHistory.merging(local: LimitUsageHistory(), observations: raw,
                                                archives: [b, a, a], now: now)
        try expect(reverse.bins([DateInterval(start: start, end: end)], minutes: 10_080)[0].usedPercent == bins[0].usedPercent)
        print("PASS sync legacy summaries fill complementary gaps without overlapping raw or duplicate coverage")
    }

    func retentionNeverDeletesPeerFiles() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = engine(root, a), second = engine(root, b)
        _ = try await exchange(first, history([(now, 80)]), [event(1, tokens: 100)])
        _ = try await exchange(second, history([(now, 80)]), [event(2, tokens: 30)])
        let future = now.addingTimeInterval(11 * 86_400)
        _ = try await exchange(first, history([(future, 80)]), [], at: future)
        try expect(!FileManager.default.fileExists(atPath: shard(root, a).path))
        try expect(FileManager.default.fileExists(atPath: shard(root, b).path))
        print("PASS sync retention removes only the current device's expired files")
    }

    func previousDayLogTail() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let midnight = Calendar.current.startOfDay(for: now)
        let before = midnight.addingTimeInterval(-60), after = midnight.addingTimeInterval(60)
        let formatter = ISO8601DateFormatter()
        func line(_ date: Date, total: Int, last: Int) -> String {
            "{\"timestamp\":\"\(formatter.string(from: date))\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":\(total)},\"last_token_usage\":{\"total_tokens\":\(last)}}}}\n"
        }
        try Data((line(before, total: 100, last: 100) + line(after, total: 120, last: 20)).utf8)
            .write(to: sessions.appendingPathComponent("log.jsonl"))
        let estimator = LocalTokenEstimator(root: root)
        let result = try await estimator.estimate(now: now, includePreviousDay: true)
        try expect(result.tokens == 20 && result.events.count == 2)
        _ = try await estimator.estimate(now: now, includePreviousDay: true)
        let io = await estimator.lastScan
        try expect(io.bytesRead == 0)
        print("PASS sync scan exports the previous-day tail while today's total excludes it, with cached zero-byte rescans")
    }

    func delayedOlderShardAndCancellation() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = engine(root, a), second = engine(root, b)
        let local = history([(now, 80)])
        _ = try await exchange(first, local, [event(1, tokens: 100)])
        let file = shard(root, a)
        let old = try Data(contentsOf: file)
        let later = now.addingTimeInterval(60)
        _ = try await exchange(first, history([(now, 80), (later, 79)]),
                               [event(1, tokens: 100), event(2, tokens: 50)], at: later)
        let current = try await exchange(second, local, [], at: later)
        try expect(current.estimate?.tokens == 150)
        try old.write(to: file, options: .atomic)
        let delayed = try await exchange(second, local, [], at: later)
        try expect(delayed.estimate?.tokens == 150)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await exchange(second, local, [], at: later)
        }
        do { try await task.value; try expect(false) } catch is CancellationError {}
        print("PASS sync ignores a delayed older peer snapshot and cancels without writing")
    }

    func correctedResetAndPartialArchiveOverlay() throws {
        let start = now.addingTimeInterval(-900)
        let split = now.addingTimeInterval(-300)
        var raw = LimitUsageHistory()
        raw.record(snapshot(start, remaining: 90, reset: now.addingTimeInterval(86_400)))
        // The service can correct reset timestamps backwards. Subsequent observations
        // of that corrected period must not be discarded forever.
        raw.record(snapshot(split, remaining: 85, reset: now.addingTimeInterval(86_399)))
        raw.record(snapshot(now, remaining: 80, reset: now.addingTimeInterval(86_399)))
        let corrected = LimitUsageHistory.merging(local: raw, observations: [], archives: [], now: now)
        try expect(corrected.observations.last?.windows.first?.remaining == 80)
        try expect(corrected.bins([DateInterval(start: start, end: now)], minutes: 10_080)[0].usedPercent == 5)

        let original = history([(start, 90), (split, 80), (now, 80)])
        let summary = LimitUsageDay(history: original.limits, interval: DateInterval(start: start, end: now), calendar: .current)
        let tail = history([(split, 80), (now, 80)])
        let refined = LimitUsageHistory.merging(local: tail.limits, observations: [], archives: [summary], now: now)
        let bin = refined.bins([DateInterval(start: start, end: now)], minutes: 10_080)[0]
        try expect(abs((bin.usedPercent ?? -1) - 10) < 0.00001 && bin.observedSeconds == 900)
        print("PASS sync accepts corrected reset timestamps and preserves archive totals under partial raw refinement")
    }

    func run() async throws {
        try await concurrentDevicesDeduplicateAndConverge()
        try await unchangedIOAndRestart()
        try await changedShardOnlyAndMidnight()
        try await offlineRetryAndAccountIsolation()
        try await corruptPeerKeepsLastGoodAndRecovers()
        try legacyCoverageAndRawOverlay()
        try await retentionNeverDeletesPeerFiles()
        try await previousDayLogTail()
        try await delayedOlderShardAndCancellation()
        try correctedResetAndPartialArchiveOverlay()
    }
}
