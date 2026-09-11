import Foundation

struct UsageHistoryPersistenceTests {
    func accountsRestorationAndExpiry() async throws {
        let suite = "local.cocount.test.\(UUID())"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cocount-history-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date.now
        func snapshot(_ offset: Double, key: String?) throws -> UsageSnapshot {
            let limits = try JSONDecoder().decode(RateLimitBucket.self, from: Data("""
            {"primary":{"usedPercent":\(50 + offset / 600),"windowDurationMins":10080,"resetsAt":\(now.timeIntervalSince1970 + 604800)}}
            """.utf8))
            return UsageSnapshot(limits: limits, tokens: nil, fetchedAt: now.addingTimeInterval(offset), historyKey: key)
        }
        var expired = LimitUsageHistory()
        expired.record(try snapshot(-9 * 86_400, key: "expired"))
        defaults.set(try JSONEncoder().encode(expired), forKey: "limitUsageHistory.v1.expired")
        let store = UsageHistoryPersistence(suiteName: suite, root: root)
        let first = try await store.record(snapshot(0, key: "a"))
        try expect(first.limits.observations.count == 1 && first.periods.periods.count == 1)
        try expect(defaults.data(forKey: "limitUsageHistory.v1.expired") == nil)
        _ = try await store.record(snapshot(600, key: "a"))
        let other = try await store.record(snapshot(600, key: "b"))
        try expect(other.limits.observations.count == 1)
        let restored = try await UsageHistoryPersistence(suiteName: suite, root: root).record(snapshot(1_200, key: "a"))
        try expect(restored.limits.observations.count == 3)
        try expect(restored.limits.daily(endingOn: now.addingTimeInterval(1_200), minutes: 10080).compactMap(\.usedPercent).reduce(0, +) == 2)
        let anonymous = try await store.record(snapshot(1_200, key: nil))
        let anonymousAgain = try await store.record(snapshot(1_800, key: nil))
        try expect(anonymous.limits.observations.count == 1 && anonymousAgain.limits.observations.count == 1)
        try expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("limitUsageHistory.v1.") }.count == 0)
    }
}
