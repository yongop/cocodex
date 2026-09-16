import AppKit
import CocountCore
import Combine
import SwiftUI

enum UsageCardMode: String, CaseIterable {
    case limits, tokens
    var title: String { self == .limits ? "한도 사용" : "토큰 사용" }
}

struct MenuBarContent: Equatable {
    let title: String
    let isDemo: Bool

    init(snapshot: UsageSnapshot?, errorMessage: String?, isDemo: Bool) {
        let remaining = UsageFormatting.percent(snapshot?.limits.featuredWindow?.remainingPercent)
        title = isDemo ? "예시 \(remaining)" : "\(errorMessage == nil ? "" : "! ")\(remaining)"
        self.isDemo = isDemo
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var todayEstimate: TodayTokenEstimate?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var historyIssue: String?
    @Published private(set) var syncIssue: String?
    @Published private(set) var syncDevices: [UsageSyncDevice] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var syncFolder: URL?
    @Published var syncEnabled: Bool {
        didSet {
            guard syncEnabled != oldValue else { return }
            defaults.set(syncEnabled, forKey: "iCloudSyncEnabled")
            syncGeneration += 1
            syncTask?.cancel()
            pendingSync = nil
            isSyncing = false
            syncIssue = nil
            syncDevices = []
            limitHistory = localHistories.limits
            history = localHistories.periods
            todayEstimate = localEstimate
            if syncEnabled { refresh() }
        }
    }
    @Published private(set) var history = PeriodHistory()
    @Published private(set) var limitHistory = LimitUsageHistory()
    @Published var usageCardMode: UsageCardMode {
        didSet {
            guard usageCardMode != oldValue else { return }
            defaults.set(usageCardMode.rawValue, forKey: "usageCardMode")
            updateTokenCollection()
        }
    }
    @Published var isDemo: Bool
    @Published var showSettings = false
    @Published var showTokens: Bool {
        didSet {
            guard showTokens != oldValue else { return }
            defaults.set(showTokens, forKey: "showTokens")
            updateTokenCollection()
        }
    }
    @Published var refreshMinutes: Int {
        didSet {
            defaults.set(refreshMinutes, forKey: "refreshMinutes")
            startTimer()
        }
    }
    @Published var appearance: String {
        didSet { defaults.set(appearance, forKey: "appearance") }
    }
    @Published var themePreset: ThemePreset {
        didSet { defaults.set(themePreset.rawValue, forKey: "themePreset") }
    }
    private let provider: any UsageProvider
    private let defaults: UserDefaults
    private let historyPersistence: UsageHistoryPersistence
    private let now: () -> Date
    private var timerTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var estimateTask: Task<Void, Never>?
    private var estimateCacheResetTask: Task<Void, Never>?
    private let estimator: LocalTokenEstimator
    private let syncEngine: UsageSyncEngine
    private var syncTask: Task<Void, Never>?
    private var syncGeneration = 0
    private var localHistories = UsageHistories()
    private var localEstimate: TodayTokenEstimate?
    private var pendingSync: (UsageSnapshot, UsageHistories)?
    private var generation = 0
    private(set) var isDashboardVisible = false
    // Quota-only refreshes must not extend the freshness of the token data.
    private var lastTokenRequestAt: Date?
    private var tokenRequestTimeZone: TimeZone?

    init(provider: any UsageProvider = AppServerUsageProvider(), demo: Bool = false,
         defaults: UserDefaults = .standard,
         historyPersistence: UsageHistoryPersistence = UsageHistoryPersistence(),
         estimator: LocalTokenEstimator = LocalTokenEstimator(),
         syncEngine: UsageSyncEngine = UsageSyncEngine(),
         now: @escaping () -> Date = { .now }) {
        self.provider = provider
        self.defaults = defaults
        self.historyPersistence = historyPersistence
        self.estimator = estimator
        self.syncEngine = syncEngine
        syncEnabled = defaults.object(forKey: "iCloudSyncEnabled") as? Bool ?? true
        self.now = now
        isDemo = demo
        usageCardMode = defaults.string(forKey: "usageCardMode").flatMap(UsageCardMode.init(rawValue:)) ?? .limits
        showTokens = defaults.object(forKey: "showTokens") as? Bool ?? true
        let saved = defaults.integer(forKey: "refreshMinutes")
        refreshMinutes = [1, 5, 15].contains(saved) ? saved : 5
        appearance = defaults.string(forKey: "appearance") ?? "system"
        themePreset = defaults.string(forKey: "themePreset").flatMap(ThemePreset.init(rawValue:)) ?? .sage
        if demo { refreshDemo() }
    }

    var colorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    var menuContent: AnyPublisher<MenuBarContent, Never> {
        Publishers.CombineLatest3($snapshot, $errorMessage, $isDemo)
            .map { MenuBarContent(snapshot: $0, errorMessage: $1, isDemo: $2) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func setDashboardVisible(_ visible: Bool) {
        guard visible != isDashboardVisible else { return }
        isDashboardVisible = visible
        if visible { updateTokenCollection() }
    }

    func start() {
        refresh()
        startTimer()
    }

    func refreshIfNeeded() {
        guard let snapshot, now().timeIntervalSince(snapshot.fetchedAt) < 60 else {
            refresh()
            return
        }
        updateTokenCollection()
    }

    func refresh() {
        guard !isLoading else { return }
        if isDemo {
            refreshDemo()
            return
        }
        isLoading = true
        let requestGeneration = generation
        let includeTokens = isDashboardVisible && showTokens && usageCardMode == .tokens
        if includeTokens {
            // Also throttle failed attempts so switching cards cannot cause a retry loop.
            lastTokenRequestAt = now()
            tokenRequestTimeZone = .current
            if !syncEnabled { refreshEstimate() }
        }
        refreshTask = Task { [weak self, provider, historyPersistence] in
            do {
                let value = try await provider.fetch(includeTokens: includeTokens)
                guard self?.generation == requestGeneration, !Task.isCancelled else { return }
                let histories = try await historyPersistence.record(value)
                guard let self, self.generation == requestGeneration, !Task.isCancelled else { return }
                let sameAccount = value.historyKey != nil && value.historyKey == self.snapshot?.historyKey
                if !sameAccount {
                    self.syncGeneration += 1
                    self.syncTask?.cancel()
                    self.pendingSync = nil
                    self.syncDevices = []
                    self.syncIssue = nil
                    self.localEstimate = nil
                    if self.syncEnabled { self.todayEstimate = nil }
                }
                if !includeTokens && !sameAccount {
                    self.lastTokenRequestAt = nil
                    self.tokenRequestTimeZone = nil
                }
                // Keep token results when a background quota refresh omits them, but never
                // carry server data across different or unidentifiable accounts.
                self.snapshot = UsageSnapshot(
                    limits: value.limits, tokens: value.tokens ?? (sameAccount ? self.snapshot?.tokens : nil),
                    fetchedAt: value.fetchedAt,
                    tokenIssue: includeTokens ? value.tokenIssue : (sameAccount ? self.snapshot?.tokenIssue : nil),
                    resetCredits: value.resetCredits, historyKey: value.historyKey, syncAccountKey: value.syncAccountKey
                )
                self.localHistories = histories
                if !sameAccount || !self.syncEnabled || self.syncDevices.isEmpty {
                    self.history = histories.periods
                    self.limitHistory = histories.limits
                }
                self.historyIssue = histories.storageIssue
                self.errorMessage = nil
                self.isLoading = false
                if self.syncEnabled { self.enqueueSync(value, histories: histories) }
                if !includeTokens { self.updateTokenCollection() }
            } catch {
                guard let self, self.generation == requestGeneration, !Task.isCancelled else { return }
                // Keep the last successful snapshot visibly stale on transient failures.
                self.errorMessage = (error as? UsageError)?.errorDescription ?? "사용량 연결에 실패했어요. 다시 시도해 주세요."
                self.isLoading = false
            }
        }
    }

    func changeMode() {
        generation += 1
        syncGeneration += 1
        syncTask?.cancel()
        pendingSync = nil
        isSyncing = false
        syncDevices = []
        syncIssue = nil
        localHistories = UsageHistories()
        localEstimate = nil
        refreshTask?.cancel()
        estimateTask?.cancel()
        estimateTask = nil
        estimateCacheResetTask = Task { [estimator, estimateCacheResetTask] in
            await estimateCacheResetTask?.value
            await estimator.clearCache()
        }
        lastTokenRequestAt = nil
        tokenRequestTimeZone = nil
        isLoading = false
        snapshot = nil
        todayEstimate = nil
        history = PeriodHistory()
        limitHistory = LimitUsageHistory()
        historyIssue = nil
        errorMessage = nil
        refresh()
    }

    func stop() {
        syncGeneration += 1
        syncTask?.cancel()
        pendingSync = nil
        timerTask?.cancel()
        refreshTask?.cancel()
        estimateTask?.cancel()
    }

    private func refreshDemo() {
        let snapshot = UsageSnapshot.demo()
        self.snapshot = snapshot
        let total = snapshot.tokens?.tokens(on: snapshot.fetchedAt) ?? 0
        let current = TodayTokenEstimate.tenMinuteIndex(at: snapshot.fetchedAt)
        var weights = Array(repeating: Int64(0), count: 144)
        for index in 0...current where index % 13 < 9 {
            weights[index] = Int64((index * 17 % 31) + 1)
        }
        let weightTotal = max(1, weights.reduce(0, +))
        var tenMinuteBins = weights.map { total * $0 / weightTotal }
        tenMinuteBins[current] += total - tenMinuteBins.reduce(0, +)
        todayEstimate = TodayTokenEstimate(tokens: total, date: snapshot.fetchedAt,
                                            tenMinuteTokens: tenMinuteBins)
        history = snapshot.limits.featuredWindow.flatMap(UsagePeriod.init(window:))
            .map { PeriodHistory.demo(current: $0) } ?? PeriodHistory()
        limitHistory = .demo(now: snapshot.fetchedAt)
        errorMessage = nil
    }

    private func refreshEstimate() {
        // Let an existing scan finish even if its card is temporarily out of view.
        guard estimateTask == nil else { return }
        let requestGeneration = generation
        let requestedAt = now()
        estimateTask = Task(priority: .utility) { [weak self, estimator, estimateCacheResetTask] in
            await estimateCacheResetTask?.value
            let result = try? await estimator.estimate(now: requestedAt)
            guard let self, self.generation == requestGeneration, !Task.isCancelled else { return }
            self.localEstimate = result
            self.todayEstimate = result
            self.estimateTask = nil
        }
    }

    private func enqueueSync(_ snapshot: UsageSnapshot, histories: UsageHistories) {
        pendingSync = (snapshot, histories)
        guard syncTask == nil else { return }
        let requestGeneration = syncGeneration
        isSyncing = true
        syncTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                self.syncTask = nil
                self.isSyncing = false
                // Coalesce rapid refreshes, including a setting/account change during disk I/O.
                if self.syncEnabled, !self.isDemo, let pending = self.pendingSync {
                    self.enqueueSync(pending.0, histories: pending.1)
                }
            }
            while !Task.isCancelled, self.syncGeneration == requestGeneration,
                  let pending = self.pendingSync {
                self.pendingSync = nil
                let timestamp = self.now()
                await self.estimateCacheResetTask?.value
                // Collection is independent of card visibility. Previous-day tail is scanned too,
                // so tokens written just before sleep/midnight are exported on the next launch.
                let estimate = pending.0.syncAccountKey == nil ? nil
                    : try? await self.estimator.estimate(now: timestamp, includePreviousDay: true)
                guard !Task.isCancelled, self.syncGeneration == requestGeneration else { return }
                self.localEstimate = estimate
                do {
                    let result = try await self.syncEngine.exchange(snapshot: pending.0, local: pending.1,
                                                                   estimate: estimate, now: timestamp)
                    guard !Task.isCancelled, self.syncGeneration == requestGeneration,
                          pending.0.historyKey == self.snapshot?.historyKey else { return }
                    self.limitHistory = result.limits
                    self.history = result.periods
                    self.todayEstimate = result.estimate
                    self.syncDevices = result.devices
                    self.syncIssue = result.issue
                    self.syncFolder = result.folder
                } catch is CancellationError { return }
                catch {
                    guard self.syncGeneration == requestGeneration else { return }
                    self.syncIssue = "동기화를 완료하지 못했어요. 다음 갱신에서 다시 시도해요."
                    self.todayEstimate = estimate
                }
            }
        }
    }

    var syncStatus: String {
        if isDemo { return "샘플 모드에서는 동기화하지 않아요" }
        if !syncEnabled { return "이 Mac의 기록만 표시" }
        if isSyncing { return "기기 기록 확인 중…" }
        if let syncIssue { return syncIssue }
        if syncDevices.isEmpty { return "첫 동기화를 기다리고 있어요" }
        let stale = syncDevices.contains { !$0.isCurrentDevice && now().timeIntervalSince($0.lastSeen) > 1_800 }
        return "\(syncDevices.count)대의 기록 통합 · " + (stale ? "다른 기기 기록 지연" : "iCloud Drive")
    }

    func openSyncFolder() {
        if let syncFolder { NSWorkspace.shared.open(syncFolder) }
    }

    private func updateTokenCollection() {
        guard !isDemo, isDashboardVisible, showTokens, usageCardMode == .tokens, needsTokenRefresh else { return }
        refresh()
    }

    private var needsTokenRefresh: Bool {
        guard let lastTokenRequestAt else { return true }
        let current = now()
        let age = current.timeIntervalSince(lastTokenRequestAt)
        return age < 0 || age >= Double(refreshMinutes * 60)
            || !Calendar.current.isDate(lastTokenRequestAt, inSameDayAs: current)
            || tokenRequestTimeZone != .current
    }

    func shutdown() async {
        stop()
        await refreshTask?.value
        await estimateTask?.value
        await estimateCacheResetTask?.value
        await syncTask?.value
    }

    private func startTimer() {
        timerTask?.cancel()
        let interval = refreshMinutes * 60
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) }
                catch { return }
                self?.refresh()
            }
        }
    }
}
