import Foundation
import CocountCore
import Combine

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
                             resetCredits: demo.resetCredits, historyKey: account,
                             syncAccountKey: account.map { String(repeating: $0 == "test-account" ? "a" : "b", count: 64) })
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
    let syncEngine: UsageSyncEngine
    let store: UsageStore

    init(visible: Bool = true, sync: Bool = false) throws {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(sync, forKey: "iCloudSyncEnabled")
        estimator = LocalTokenEstimator(root: root)
        syncEngine = UsageSyncEngine(localRoot: root.appendingPathComponent("outbox"),
            cloudRoot: root.appendingPathComponent("cloud"), deviceID: String(repeating: "1", count: 64), deviceName: "Test Mac")
        let clock = clock
        store = UsageStore(provider: provider, defaults: defaults,
            historyPersistence: UsageHistoryPersistence(suiteName: suite, root: root.appendingPathComponent("history")),
            estimator: estimator, syncEngine: syncEngine,
            now: { clock.now })
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"),
                                                 withIntermediateDirectories: true)
        try event(total: 100, last: 100).write(to: log, atomically: true, encoding: .utf8)
        store.setDashboardVisible(visible)
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

    static func dashboardVisibility() async throws {
        let f = try Fixture(visible: false)
        f.store.usageCardMode = .tokens
        precondition(!f.store.isLoading)
        f.store.refresh()
        try await settled(f.store)
        await f.calls([false])
        precondition(f.store.todayEstimate == nil)
        let hiddenScan = await f.estimator.lastScan
        precondition(hiddenScan.bytesRead == 0)

        f.store.setDashboardVisible(true)
        f.store.refreshIfNeeded()
        try await settled(f.store)
        try await waitUntil { f.store.todayEstimate != nil }
        await f.calls([false, true])
        precondition(f.store.todayEstimate?.tokens == 100)

        f.store.setDashboardVisible(false)
        f.clock.now += 300
        try f.appendEvent()
        f.store.refresh()
        try await settled(f.store)
        await f.calls([false, true, false])
        precondition(f.store.todayEstimate?.tokens == 100 && f.store.snapshot?.tokens != nil)
        f.store.setDashboardVisible(true)
        try await settled(f.store)
        try await waitUntil { f.store.todayEstimate?.tokens == 150 }
        await f.calls([false, true, false, true])
        let resumedScan = await f.estimator.lastScan
        precondition(resumedScan.appendedFiles == 1 && resumedScan.fullFiles == 0)
        for _ in 0..<10 {
            f.store.setDashboardVisible(false)
            f.store.setDashboardVisible(true)
        }
        precondition(!f.store.isLoading)
        await f.calls([false, true, false, true])
        await f.close()
        print("PASS closed dashboards collect only quotas; reopening resumes stale tokens once with the retained log cache")
    }

    static func visibilityDuringRequests() async throws {
        let f = try Fixture(visible: false)
        f.store.usageCardMode = .tokens
        f.store.refresh()
        f.store.setDashboardVisible(true)
        try await settled(f.store)
        try await waitUntil { f.store.todayEstimate != nil }
        await f.calls([false, true])
        f.clock.now += 300
        try f.appendEvent()
        f.store.refresh()
        f.store.setDashboardVisible(false)
        try await settled(f.store)
        try await waitUntil { f.store.todayEstimate?.tokens == 150 }
        f.store.setDashboardVisible(true)
        precondition(!f.store.isLoading)
        await f.calls([false, true, true])
        await f.close()
        print("PASS opening during a quota request adds one token follow-up; closing retains in-flight results")
    }

    static func menuContentDeduplication() async throws {
        let f = try Fixture()
        var values: [MenuBarContent] = []
        let subscription = f.store.menuContent.sink { values.append($0) }
        precondition(values.count == 1)
        f.store.refresh()
        try await settled(f.store)
        precondition(values.count == 2)
        f.store.showSettings.toggle()
        f.store.themePreset = .sage
        f.store.refresh()
        try await settled(f.store)
        precondition(values.count == 2, "Same quota and unrelated state must not redraw the menu item")
        await f.provider.configure(failure: .timeout)
        f.store.refresh()
        try await settled(f.store)
        precondition(values.count == 3 && values.last!.title.hasPrefix("! "))
        f.store.refresh()
        try await settled(f.store)
        precondition(values.count == 3)
        await f.provider.configure()
        f.store.refresh()
        try await settled(f.store)
        precondition(values.count == 4 && !values.last!.title.hasPrefix("! "))
        f.store.isDemo = true
        precondition(values.count == 5 && values.last!.isDemo && values.last!.title.hasPrefix("예시 "))
        subscription.cancel()
        await f.close()
        print("PASS menu updates only for changed display values, including errors, recovery, and demo mode")
    }

    static func syncCollectsHiddenAndReusesCache() async throws {
        let f = try Fixture(visible: false, sync: true)
        f.store.showTokens = false
        f.store.refresh()
        try await settled(f.store)
        try await waitUntil { !f.store.isSyncing && f.store.syncDevices.count == 1 }
        precondition(f.store.todayEstimate?.tokens == 100 && f.store.syncIssue == nil)
        await f.calls([false])
        try f.appendEvent()
        f.clock.now += 60
        f.store.refresh()
        try await settled(f.store)
        try await waitUntil { !f.store.isSyncing && f.store.todayEstimate?.tokens == 150 }
        let scan = await f.estimator.lastScan
        precondition(scan.fullFiles == 0 && scan.appendedFiles == 1)
        f.store.refresh()
        try await settled(f.store)
        try await waitUntil { !f.store.isSyncing }
        let io = await f.syncEngine.lastMetrics
        precondition(io.cloudWrites == 0 && io.filesRead == 0 && io.localWrites == 0)
        f.store.syncEnabled = false
        precondition(f.store.syncDevices.isEmpty && f.store.todayEstimate?.tokens == 150)
        try f.appendEvent()
        f.clock.now += 60
        f.store.refresh()
        try await settled(f.store)
        precondition(!f.store.isSyncing && f.store.todayEstimate?.tokens == 150)
        await f.close()
        print("PASS sync collects while hidden, keeps incremental scans, skips unchanged I/O, and stops when disabled")
    }

    static func syncAccountAndDemoIsolation() async throws {
        let f = try Fixture(visible: false, sync: true)
        f.store.refresh()
        try await settled(f.store)
        try await waitUntil { !f.store.isSyncing && f.store.syncDevices.count == 1 }
        await f.provider.configure(account: nil)
        f.store.refresh()
        try await settled(f.store)
        try await waitUntil { !f.store.isSyncing }
        precondition(f.store.syncDevices.isEmpty && f.store.syncIssue != nil)
        f.store.isDemo = true
        f.store.changeMode()
        precondition(!f.store.isSyncing && f.store.syncDevices.isEmpty && f.store.syncIssue == nil)
        f.store.syncEnabled = false
        f.store.syncEnabled = true
        precondition(!f.store.isSyncing)
        await f.close()
        print("PASS unidentified accounts and demo mode never publish synchronized records")
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
        try await dashboardVisibility()
        try await visibilityDuringRequests()
        try await menuContentDeduplication()
        try await syncCollectsHiddenAndReusesCache()
        try await syncAccountAndDemoIsolation()
        print("17 store checks passed.")
    }
}
