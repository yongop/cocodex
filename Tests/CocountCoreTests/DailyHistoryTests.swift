import Foundation

private final class CommitFault: @unchecked Sendable {
    private let lock = NSLock()
    private var _enabled = true
    var enabled: Bool {
        get { lock.withLock { _enabled } }
        set { lock.withLock { _enabled = newValue } }
    }
}

struct DailyHistoryTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private let base = Date(timeIntervalSince1970: 1_783_296_000) // 2026-07-06 00:00 UTC

    private func sample(_ date: Date, used: Double?, key: String? = "a", reset: Date? = nil) throws -> UsageSnapshot {
        let usedJSON = used.map(String.init(describing:)) ?? "null"
        let limits = try JSONDecoder().decode(RateLimitBucket.self, from: Data("""
        {"primary":{"usedPercent":\(usedJSON),"windowDurationMins":10080,"resetsAt":\((reset ?? date.addingTimeInterval(20 * 86400)).timeIntervalSince1970)}}
        """.utf8))
        return UsageSnapshot(limits: limits, tokens: nil, fetchedAt: date, historyKey: key)
    }
    private func recorded(_ seconds: Double, used: Double?, key: String? = "a") throws -> UsageSnapshot {
        try sample(base.addingTimeInterval(seconds), used: used, key: key,
                   reset: base.addingTimeInterval(20 * 86400))
    }
    private func compare(_ a: [LimitUsageHistory.Bin], _ b: [LimitUsageHistory.Bin]) throws {
        try expect(a.count == b.count)
        for (a, b) in zip(a, b) {
            try expect(a.start == b.start && a.end == b.end)
            try expect((a.usedPercent == nil) == (b.usedPercent == nil))
            try expect(abs((a.usedPercent ?? 0) - (b.usedPercent ?? 0)) < 1e-8)
            try expect(abs(a.observedSeconds - b.observedSeconds) < 1e-6)
        }
    }

    func midnightZeroMissingResetAndCodec() throws {
        var history = LimitUsageHistory()
        for (seconds, used) in [(0.0, 0.0), (300, 0), (600, 1), (2100, 2),
                                (4200, 9), (86_100, 20), (86_700, 30)] {
            history.record(try recorded(seconds, used: used))
        }
        let reference = history
        let now = base.addingTimeInterval(86_700)
        history.closePastDays(now: now, calendar: calendar)
        try expect(history.closedDays.count == 1 && history.observations.count == 2)
        try expect(history.archivedThrough == base.addingTimeInterval(86400))
        let summary = history.closedDays[0]
        let bytes = try summary.encoded()
        try expect(bytes.count < 2_100 && summary.windows[0].used.count == 96)
        try expect(try LimitUsageDay.decode(bytes) == summary)
        var corrupted = bytes
        corrupted[corrupted.count / 2] ^= 0x01
        do { _ = try LimitUsageDay.decode(corrupted); try expect(false) }
        catch is HistoryStorageError {}
        do { _ = try LimitUsageDay.decode(bytes.dropLast()); try expect(false) }
        catch is HistoryStorageError {}
        try compare(reference.daily(endingOn: now, minutes: 10080, calendar: calendar),
                    history.daily(endingOn: now, minutes: 10080, calendar: calendar))
        for date in [base, now] {
            try compare(reference.hourly(on: date, minutes: 10080, calendar: calendar),
                        history.hourly(on: date, minutes: 10080, calendar: calendar))
            try compare(reference.quarterHourly(on: date, minutes: 10080, calendar: calendar),
                        history.quarterHourly(on: date, minutes: 10080, calendar: calendar))
        }
        // A later drop must not recount the already archived five minutes before midnight.
        history.record(try recorded(87_000, used: 35))
        let today = history.daily(endingOn: now, minutes: 10080, calendar: calendar).last!
        try expect(today.usedPercent == 10 && today.observedSeconds == 600)
    }

    func dstTimeZoneAndRetention() throws {
        var la = calendar
        la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        for (month, day, expected) in [(3, 8, 92), (11, 1, 100)] {
            let start = la.date(from: DateComponents(year: 2026, month: month, day: day))!
            let end = la.date(byAdding: .day, value: 1, to: start)!
            var history = LimitUsageHistory()
            var cursor = start
            let reset = end.addingTimeInterval(86400)
            while cursor <= end.addingTimeInterval(300) {
                history.record(try sample(cursor, used: cursor.timeIntervalSince(start) / 10000, reset: reset))
                cursor = cursor.addingTimeInterval(300)
            }
            let reference = history
            history.closePastDays(now: end.addingTimeInterval(300), calendar: la)
            try expect(history.closedDays[0].windows[0].used.count == expected)
            try compare(reference.hourly(on: start, minutes: 10080, calendar: la),
                        history.hourly(on: start, minutes: 10080, calendar: la))
            var tokyo = calendar
            tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
            let now = end.addingTimeInterval(300)
            history.closePastDays(now: now, calendar: tokyo)
            try compare(reference.daily(endingOn: now, minutes: 10080, calendar: tokyo),
                        history.daily(endingOn: now, minutes: 10080, calendar: tokyo))
            history.closePastDays(now: now, calendar: la) // move the civil-day boundary back
            try compare(reference.quarterHourly(on: start, minutes: 10080, calendar: la),
                        history.quarterHourly(on: start, minutes: 10080, calendar: la))
        }
        var history = LimitUsageHistory()
        for day in 0...12 {
            history.record(try recorded(Double(day * 86400), used: 20))
            history.record(try recorded(Double(day * 86400 + 300), used: 21))
            history.closePastDays(now: base.addingTimeInterval(Double(day * 86400 + 300)), calendar: calendar)
        }
        try expect(history.closedDays.count == 8)
        try expect(history.closedDays.first?.start == base.addingTimeInterval(4 * 86400))
        try expect(history.observations.count <= 3)
    }

    func migrationAndImmutableArchives() async throws {
        let suite = "local.cocount.dailytest.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        var legacy = LimitUsageHistory()
        legacy.record(try recorded(0, used: 10))
        legacy.record(try recorded(300, used: 15))
        legacy.record(try recorded(86_100, used: 20))
        defaults.set(try JSONEncoder().encode(legacy), forKey: "limitUsageHistory.v1.a")
        let store = UsageHistoryPersistence(suiteName: suite, root: root)
        let migrated = try await store.record(recorded(86_700, used: 30), calendar: calendar)
        try expect(migrated.storageIssue == nil && migrated.limits.closedDays.count == 1)
        try expect(defaults.data(forKey: "limitUsageHistory.v1.a") == nil)
        let folder = await store.directory(for: "a")
        let archive = folder.appendingPathComponent(migrated.limits.closedDays[0].fileName)
        let data = try Data(contentsOf: archive)
        let modified = try archive.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let updated = try await store.record(recorded(87_000, used: 35), calendar: calendar)
        let metrics = await store.lastWrite
        try expect(metrics.archiveFiles == 0 && metrics.archiveBytes == 0 && metrics.activeBytes > 0)
        try expect(try Data(contentsOf: archive) == data)
        try expect(try archive.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
        let reloaded = try await UsageHistoryPersistence(suiteName: suite, root: root)
            .record(recorded(87_300, used: 35), calendar: calendar)
        try expect(reloaded.storageIssue == nil && reloaded.limits.closedDays == updated.limits.closedDays)
        try expect(reloaded.limits.observations.count <= 4)
        try compare(updated.limits.hourly(on: base, minutes: 10080, calendar: calendar),
                    reloaded.limits.hourly(on: base, minutes: 10080, calendar: calendar))
    }

    func interruptedCommitRecoveryAndCorruption() async throws {
        let suite = "local.cocount.dailyfailure.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        var legacy = LimitUsageHistory()
        legacy.record(try recorded(86_100, used: 20))
        let legacyData = try JSONEncoder().encode(legacy)
        defaults.set(legacyData, forKey: "limitUsageHistory.v1.a")
        let fault = CommitFault()
        let store = UsageHistoryPersistence(suiteName: suite, root: root, write: { data, url in
            if url.lastPathComponent == "today.json", fault.enabled { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
        let failed = try await store.record(recorded(86_700, used: 30), calendar: calendar)
        try expect(failed.storageIssue != nil && failed.limits.closedDays.isEmpty)
        try expect(defaults.data(forKey: "limitUsageHistory.v1.a") == legacyData)
        let folder = await store.directory(for: "a")
        try expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("today.json").path))
        let failedFiles = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        try expect(failedFiles.filter { $0.pathExtension == "bin" }.isEmpty)
        // Simulate a hard process interruption (no defer cleanup): its file has no committed reference.
        let orphan = LimitUsageDay(history: failed.limits,
            interval: DateInterval(start: base, end: base.addingTimeInterval(86400)), calendar: calendar)
        try orphan.encoded().write(to: folder.appendingPathComponent(orphan.fileName))
        // A new process must ignore the orphan archive and migrate from the surviving raw data.
        let recovered = try await UsageHistoryPersistence(suiteName: suite, root: root)
            .record(recorded(87_000, used: 35), calendar: calendar)
        try expect(recovered.storageIssue == nil && recovered.limits.closedDays.count == 1)
        let day = recovered.limits.daily(endingOn: base.addingTimeInterval(87_000), minutes: 10080, calendar: calendar)
        try expect(abs((day[5].usedPercent ?? 0) - 5) < 1e-8 && abs((day[6].usedPercent ?? 0) - 10) < 1e-8)
        // Detect a damaged archive without overwriting the committed manifest or pretending it is zero.
        let stateURL = folder.appendingPathComponent("today.json")
        let state = try Data(contentsOf: stateURL)
        let archive = folder.appendingPathComponent(recovered.limits.closedDays[0].fileName)
        let intact = try Data(contentsOf: archive)
        try Data("damaged".utf8).write(to: archive)
        let reader = UsageHistoryPersistence(suiteName: suite, root: root)
        let damaged = try await reader.record(recorded(87_300, used: 36), calendar: calendar)
        try expect(damaged.storageIssue != nil)
        try expect(try Data(contentsOf: stateURL) == state)
        try intact.write(to: archive)
        let repaired = try await reader.record(recorded(87_600, used: 37), calendar: calendar)
        try expect(repaired.storageIssue == nil && repaired.limits.closedDays.count == 1)
        try expect(repaired.limits.observations.contains(where: { $0.date == base.addingTimeInterval(87_300) }))
    }
    func mixedWindowsMatchOriginalQueries() throws {
        var history = LimitUsageHistory()
        var elapsed = 0.0
        var index = 0
        while elapsed < 9 * 86400 + 600 {
            let date = base.addingTimeInterval(elapsed)
            var windows: [LimitUsageHistory.Window] = []
            for minutes in [300, 10080] {
                if index % (minutes == 300 ? 31 : 47) == 0 { continue }
                let duration = Double(minutes * 60)
                let period = floor(elapsed / duration)
                windows.append(.init(minutes: minutes,
                    remaining: 100 - (elapsed - period * duration) / duration * 80,
                    reset: base.addingTimeInterval((period + 1) * duration)))
            }
            history.recordObservation(.init(date: date, windows: windows))
            elapsed += index % 71 == 0 ? 2400 : 600
            index += 1
        }
        let reference = history
        let now = history.observations.last!.date
        history.closePastDays(now: now, calendar: calendar)
        for minutes in [300, 10080] {
            try compare(reference.daily(endingOn: now, minutes: minutes, calendar: calendar),
                        history.daily(endingOn: now, minutes: minutes, calendar: calendar))
            for offset in -8...0 {
                let date = calendar.date(byAdding: .day, value: offset, to: now)!
                try compare(reference.hourly(on: date, minutes: minutes, calendar: calendar),
                            history.hourly(on: date, minutes: minutes, calendar: calendar))
                try compare(reference.quarterHourly(on: date, minutes: minutes, calendar: calendar),
                            history.quarterHourly(on: date, minutes: minutes, calendar: calendar))
            }
        }
    }

    func failedRolloverRetriesWithoutLosingRawData() async throws {
        let suite = "local.cocount.rolloverretry.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let seed = UsageHistoryPersistence(suiteName: suite, root: root)
        _ = try await seed.record(recorded(86_100, used: 20), calendar: calendar)
        let folder = await seed.directory(for: "a")
        let stateURL = folder.appendingPathComponent("today.json")
        let original = try Data(contentsOf: stateURL)
        let fault = CommitFault()
        let store = UsageHistoryPersistence(suiteName: suite, root: root, write: { data, url in
            if url.lastPathComponent == "today.json", fault.enabled { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
        let failed = try await store.record(recorded(86_700, used: 30), calendar: calendar)
        try expect(failed.storageIssue != nil && failed.limits.observations.count == 2)
        try expect(try Data(contentsOf: stateURL) == original)
        fault.enabled = false
        let restored = try await store.record(recorded(87_000, used: 31), calendar: calendar)
        try expect(restored.storageIssue == nil)
        let bins = restored.limits.daily(endingOn: base.addingTimeInterval(87_000), minutes: 10080, calendar: calendar)
        try expect(bins[5].usedPercent == 5 && bins[6].usedPercent == 6)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        try expect(files.filter { $0.pathExtension == "bin" }.count == 1)
        let reopened = try await UsageHistoryPersistence(suiteName: suite, root: root)
            .record(recorded(87_300, used: 32), calendar: calendar)
        try expect(reopened.storageIssue == nil && reopened.limits.closedDays.count == 1)
        // Old inactive accounts are removed; period history is a separate, small preference.
        let abandoned = await store.directory(for: "abandoned")
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: base], ofItemAtPath: abandoned.path)
        _ = try await store.record(recorded(10 * 86400, used: 10, key: "b"), calendar: calendar)
        try expect(!FileManager.default.fileExists(atPath: folder.path))
        try expect(!FileManager.default.fileExists(atPath: abandoned.path))
    }

}
