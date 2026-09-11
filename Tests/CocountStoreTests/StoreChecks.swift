import Foundation
import CocountCore

private actor RecordingProvider: UsageProvider {
    private(set) var calls: [Bool] = []
    private var account: String? = "test-account"
    private var failure: UsageError?
    private var tokenIssue: String?

    func configure(account: String? = "test-account", failure: UsageError? = nil, tokenIssue: String? = nil) {
        self.account = account
        self.failure = failure
        self.tokenIssue = tokenIssue
    }

    func fetch(includeTokens: Bool) async throws -> UsageSnapshot {
        calls.append(includeTokens)
        let account = account, failure = failure, tokenIssue = tokenIssue
        try await Task.sleep(for: .milliseconds(20))
        if let failure { throw failure }
        let demo = UsageSnapshot.demo()
        return UsageSnapshot(limits: demo.limits, tokens: includeTokens && tokenIssue == nil ? demo.tokens : nil,
                             fetchedAt: .now, tokenIssue: includeTokens ? tokenIssue : nil,
                             resetCredits: demo.resetCredits, historyKey: account)
    }
}

@MainActor
private final class TestClock {
    var now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: .now)!
}

@MainActor
private final class Fixture {
    let suite = "local.cocount.storetest.\(UUID())"
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cocount-store-\(UUID())")
    let provider = RecordingProvider()
    let clock = TestClock()
    let defaults: UserDefaults
    let estimator: LocalTokenEstimator
    let store: UsageStore

    init() throws {
        defaults = UserDefaults(suiteName: suite)!
        estimator = LocalTokenEstimator(root: root)
        let clock = clock
        store = UsageStore(provider: provider, defaults: defaults,
            historyPersistence: UsageHistoryPersistence(suiteName: suite, root: root.appendingPathComponent("history")),
            estimator: estimator,
            now: { clock.now })
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"),
                                                 withIntermediateDirectories: true)
        try event(total: 100, last: 100).write(to: log, atomically: true, encoding: .utf8)
    }

    var log: URL { root.appendingPathComponent("sessions/usage.jsonl") }

    func event(total: Int, last: Int) -> String {
        let timestamp = ISO8601DateFormatter().string(from: clock.now)
        return "{\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":\(total)},\"last_token_usage\":{\"total_tokens\":\(last)}}}}\n"
    }

    func appendEvent() throws {
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(event(total: 150, last: 50).utf8))
    }

    func calls(_ expected: [Bool]) async {
        let actual = await provider.calls
        precondition(actual == expected, "Expected requests \(expected), got \(actual)")
    }

    func loadTokens() async throws {
        store.usageCardMode = .tokens
        try await StoreChecks.settled(store)
        try await StoreChecks.waitUntil { self.store.todayEstimate != nil }
        precondition(store.snapshot?.tokens != nil && store.todayEstimate?.tokens == 100)
    }

    func close() async {
        await store.shutdown()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@main
@MainActor
struct StoreChecks {
    static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            precondition(ContinuousClock.now < deadline, "Async work failed to settle")
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    static func settled(_ store: UsageStore) async throws {
        try await waitUntil { !store.isLoading }
    }

    static func initialAndInFlightSwitch() async throws {
        let f = try Fixture()
        let store = f.store
        store.refresh()
        try await settled(store)
        await f.calls([false])
        precondition(store.snapshot != nil && store.snapshot?.tokens == nil && store.todayEstimate == nil)

        store.refresh()
        for _ in 0..<20 {
            store.usageCardMode = .limits
            store.usageCardMode = .tokens
        }
        try await settled(store)
        try await waitUntil { store.todayEstimate != nil }
        await f.calls([false, false, true])
        precondition(store.snapshot?.tokens != nil)
        await f.close()
        print("PASS limit-only startup and one token follow-up during an in-flight refresh")
    }

    static func cachedSwitches() async throws {
        let f = try Fixture()
        try await f.loadTokens()
        let date = f.store.todayEstimate?.date
        try f.appendEvent()
        for _ in 0..<20 {
            f.store.usageCardMode = .limits
            precondition(f.store.todayEstimate?.tokens == 100)
            f.store.usageCardMode = .tokens
            precondition(!f.store.isLoading && f.store.snapshot?.tokens != nil)
        }
        await f.calls([true])
        precondition(f.store.todayEstimate?.date == date && f.store.todayEstimate?.tokens == 100)
        await f.close()
        print("PASS 20 cached round trips trigger no server request, estimate reset, or local rescan")
    }

    static func quotaRefreshKeepsTokens() async throws {
        let f = try Fixture()
        try await f.loadTokens()
        let previous = f.store.snapshot!
        f.store.usageCardMode = .limits
        f.store.refresh()
        f.store.usageCardMode = .tokens
        try await settled(f.store)
        await f.calls([true, false])
        precondition(f.store.snapshot?.tokens?.dailyUsageBuckets?.count == previous.tokens?.dailyUsageBuckets?.count)
        precondition(f.store.snapshot!.fetchedAt > previous.fetchedAt)
        precondition(f.store.snapshot?.resetCredits != nil && f.store.todayEstimate?.tokens == 100)
        await f.close()
        print("PASS fresh token results survive a quota refresh without a redundant follow-up")
    }

    static func expiryAndIncrementalCache() async throws {
        let f = try Fixture()
        try await f.loadTokens()
        let previous = f.store.todayEstimate?.date
        try f.appendEvent()
        f.store.usageCardMode = .limits
        f.clock.now += 299
        f.store.refresh()
        try await settled(f.store)
        f.store.usageCardMode = .tokens
        precondition(!f.store.isLoading)
        await f.calls([true, false])
        f.clock.now += 1
        f.store.usageCardMode = .limits
        f.store.usageCardMode = .tokens
        precondition(f.store.isLoading && f.store.snapshot?.tokens != nil && f.store.todayEstimate?.tokens == 100)
        try await settled(f.store)
        try await waitUntil { f.store.todayEstimate?.date != previous }
        await f.calls([true, false, true])
        let metrics = await f.estimator.lastScan
        precondition(f.store.todayEstimate?.tokens == 150 && metrics.appendedFiles == 1 && metrics.fullFiles == 0)
        await f.close()
        print("PASS token expiry is independent of quota freshness and reuses incremental log cache")
    }

    static func hiddenAndManualRefresh() async throws {
        let f = try Fixture()
        try await f.loadTokens()
        let previous = f.store.todayEstimate?.date
        f.store.showTokens = false
        for _ in 0..<10 { f.store.refresh() }
        try await settled(f.store)
        precondition(f.store.todayEstimate?.date == previous && f.store.snapshot?.tokens != nil)
        f.store.showTokens = true
        precondition(!f.store.isLoading)
        await f.calls([true, false])
        f.clock.now += 1
        for _ in 0..<10 { f.store.refresh() }
        try await settled(f.store)
        try await waitUntil { f.store.todayEstimate?.date != previous }
        await f.calls([true, false, true])
        let metrics = await f.estimator.lastScan
        precondition(metrics.bytesRead == 0 && metrics.cachedFiles == 1)
        await f.close()
        print("PASS hiding preserves cached data; manual refresh still fetches and coalesces requests")
    }

    static func inFlightTokensFinishWhileHidden() async throws {
        let f = try Fixture()
        f.store.usageCardMode = .tokens
        f.store.usageCardMode = .limits
        try await settled(f.store)
        try await waitUntil { f.store.todayEstimate != nil }
        f.store.usageCardMode = .tokens
        precondition(!f.store.isLoading && f.store.todayEstimate?.tokens == 100 && f.store.snapshot?.tokens != nil)
        await f.calls([true])
        await f.close()
        print("PASS an in-flight token request and estimate remain reusable after switching away")
    }

    static func accountIsolation() async throws {
        for account: String? in ["another-account", nil] {
            let f = try Fixture()
            try await f.loadTokens()
            f.store.usageCardMode = .limits
            await f.provider.configure(account: account)
            f.store.refresh()
            try await settled(f.store)
            precondition(f.store.snapshot?.tokens == nil && f.store.snapshot?.tokenIssue == nil)
            f.store.usageCardMode = .tokens
            precondition(f.store.isLoading)
            try await settled(f.store)
            await f.calls([true, false, true])
            await f.close()
        }
        print("PASS changed and missing account identities invalidate the server token cache")
    }

    static func failuresDoNotCauseSwitchRetries() async throws {
        let f = try Fixture()
        try await f.loadTokens()
        await f.provider.configure(failure: .timeout)
        f.store.refresh()
        try await settled(f.store)
        precondition(f.store.errorMessage != nil && f.store.snapshot?.tokens != nil)
        for _ in 0..<10 {
            f.store.usageCardMode = .limits
            f.store.usageCardMode = .tokens
            precondition(!f.store.isLoading)
        }
        await f.calls([true, true])
        f.clock.now += 300
        f.store.usageCardMode = .limits
        f.store.usageCardMode = .tokens
        try await settled(f.store)
        await f.calls([true, true, true])
        await f.provider.configure()
        f.store.refresh()
        try await settled(f.store)
        precondition(f.store.errorMessage == nil)
        await f.calls([true, true, true, true])
        await f.close()
        print("PASS failed token attempts respect freshness while expired and manual retries still work")
    }

    static func partialTokenFailure() async throws {
        let f = try Fixture()
        try await f.loadTokens()
        await f.provider.configure(tokenIssue: "Token summary unavailable")
        f.store.refresh()
        try await settled(f.store)
        precondition(f.store.snapshot?.tokens != nil && f.store.snapshot?.tokenIssue != nil)
        f.store.usageCardMode = .limits
        f.store.refresh()
        try await settled(f.store)
        f.store.usageCardMode = .tokens
        precondition(!f.store.isLoading && f.store.snapshot?.tokens != nil && f.store.snapshot?.tokenIssue != nil)
        await f.calls([true, true, false])
        await f.close()
        print("PASS partial token failures preserve previous values and their issue across quota refreshes")
    }

    static func unavailableTokensAreNotRetriedOnEverySwitch() async throws {
        let f = try Fixture()
        await f.provider.configure(tokenIssue: "Token summary unavailable")
        f.store.usageCardMode = .tokens
        try await settled(f.store)
        try await waitUntil { f.store.todayEstimate != nil }
        for _ in 0..<10 {
            f.store.usageCardMode = .limits
            f.store.usageCardMode = .tokens
            precondition(!f.store.isLoading && f.store.snapshot?.tokens == nil)
        }
        precondition(f.store.snapshot?.tokenIssue != nil && f.store.todayEstimate?.tokens == 100)
        await f.calls([true])
        await f.close()
        print("PASS unavailable server tokens do not trigger repeated requests on card switches")
    }

    static func calendarAndIntervalChanges() async throws {
        let f = try Fixture()
        f.clock.now = Calendar.current.date(byAdding: .day, value: 1,
                                            to: Calendar.current.startOfDay(for: f.clock.now))!.addingTimeInterval(-1)
        try await f.loadTokens()
        let beforeMidnight = f.store.todayEstimate?.date
        f.clock.now = Calendar.current.date(byAdding: .day, value: 1,
                                            to: Calendar.current.startOfDay(for: f.clock.now))!
        f.store.usageCardMode = .limits
        f.store.usageCardMode = .tokens
        precondition(f.store.isLoading)
        try await settled(f.store)
        try await waitUntil { f.store.todayEstimate?.date != beforeMidnight }
        await f.calls([true, true])
        f.clock.now += 61
        f.store.refreshMinutes = 1
        f.store.usageCardMode = .limits
        f.store.usageCardMode = .tokens
        try await settled(f.store)
        await f.calls([true, true, true])
        f.clock.now -= 120
        f.store.usageCardMode = .limits
        f.store.usageCardMode = .tokens
        try await settled(f.store)
        await f.calls([true, true, true, true])
        await f.close()
        print("PASS midnight, a shorter refresh interval, and clock rollback invalidate freshness")
    }

    static func demoAndSameValueChanges() async throws {
        let f = try Fixture()
        try await f.loadTokens()
        f.clock.now += 300
        f.store.usageCardMode = .tokens
        f.store.showTokens = true
        precondition(!f.store.isLoading)
        await f.calls([true])
        f.store.refresh()
        f.store.isDemo = true
        f.store.changeMode()
        let demoDate = f.store.todayEstimate?.date
        try await Task.sleep(for: .milliseconds(40))
        precondition(f.store.snapshot?.historyKey == nil && f.store.todayEstimate?.date == demoDate)
        f.store.usageCardMode = .limits
        f.store.usageCardMode = .tokens
        precondition(!f.store.isLoading && f.store.todayEstimate != nil)
        f.store.isDemo = false
        f.store.changeMode()
        precondition(f.store.isLoading && f.store.snapshot == nil && f.store.todayEstimate == nil)
        try await settled(f.store)
        try await waitUntil { f.store.todayEstimate != nil }
        precondition(f.store.snapshot?.historyKey == "test-account" && f.store.todayEstimate?.tokens == 100)
        let metrics = await f.estimator.lastScan
        precondition(metrics.fullFiles == 1)
        await f.close()
        print("PASS unchanged settings do not reload; demo changes invalidate caches and ignore canceled work")
    }

    static func main() async throws {
        try await initialAndInFlightSwitch()
        try await cachedSwitches()
        try await quotaRefreshKeepsTokens()
        try await expiryAndIncrementalCache()
        try await hiddenAndManualRefresh()
        try await inFlightTokensFinishWhileHidden()
        try await accountIsolation()
        try await failuresDoNotCauseSwitchRetries()
        try await partialTokenFailure()
        try await unavailableTokensAreNotRetriedOnEverySwitch()
        try await calendarAndIntervalChanges()
        try await demoAndSameValueChanges()
        print("12 store checks passed.")
    }
}
