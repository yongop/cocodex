import AppKit
import CocountCore
import Combine
import SwiftUI

enum UsageCardMode: String, CaseIterable {
    case limits, tokens
    var title: String { self == .limits ? "한도 사용" : "토큰 사용" }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var todayEstimate: TodayTokenEstimate?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var historyIssue: String?
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
    private var generation = 0
    // Quota-only refreshes must not extend the freshness of the token data.
    private var lastTokenRequestAt: Date?
    private var tokenRequestTimeZone: TimeZone?

    init(provider: any UsageProvider = AppServerUsageProvider(), demo: Bool = false,
         defaults: UserDefaults = .standard,
         historyPersistence: UsageHistoryPersistence = UsageHistoryPersistence(),
         estimator: LocalTokenEstimator = LocalTokenEstimator(),
         now: @escaping () -> Date = { .now }) {
        self.provider = provider
        self.defaults = defaults
        self.historyPersistence = historyPersistence
        self.estimator = estimator
        self.now = now
        isDemo = demo
        usageCardMode = defaults.string(forKey: "usageCardMode").flatMap(UsageCardMode.init(rawValue:)) ?? .limits
        showTokens = defaults.object(forKey: "showTokens") as? Bool ?? true
        let saved = defaults.integer(forKey: "refreshMinutes")
        refreshMinutes = [1, 5, 15].contains(saved) ? saved : 5
        appearance = defaults.string(forKey: "appearance") ?? "system"
        themePreset = defaults.string(forKey: "themePreset").flatMap(ThemePreset.init(rawValue:)) ?? .sage
        if demo {
            snapshot = .demo()
            updateDemoEstimate()
            updateHistory()
            updateLimitHistory()
        }
    }

    var colorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    var menuTitle: String {
        let value = UsageFormatting.percent(snapshot?.limits.featuredWindow?.remainingPercent)
        return isDemo ? "예시 \(value)" : "\(errorMessage == nil ? "" : "! ")\(value)"
    }

    func start() {
        refresh()
        startTimer()
    }

    func refreshIfNeeded() {
        if snapshot == nil || now().timeIntervalSince(snapshot!.fetchedAt) >= 60 { refresh() }
    }

    func refresh() {
        guard !isLoading else { return }
        if isDemo {
            snapshot = .demo()
            updateDemoEstimate()
            updateHistory()
            updateLimitHistory()
            errorMessage = nil
            return
        }
        isLoading = true
        let requestGeneration = generation
        let includeTokens = showTokens && usageCardMode == .tokens
        if includeTokens {
            // Also throttle failed attempts so switching cards cannot cause a retry loop.
            lastTokenRequestAt = now()
            tokenRequestTimeZone = .current
            refreshEstimate()
        }
        refreshTask = Task { [weak self, provider, historyPersistence] in
            do {
                let value = try await provider.fetch(includeTokens: includeTokens)
                guard self?.generation == requestGeneration, !Task.isCancelled else { return }
                let histories = try await historyPersistence.record(value)
                guard let self, self.generation == requestGeneration, !Task.isCancelled else { return }
                let sameAccount = value.historyKey != nil && value.historyKey == self.snapshot?.historyKey
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
                    resetCredits: value.resetCredits, historyKey: value.historyKey
                )
                self.history = histories.periods
                self.limitHistory = histories.limits
                self.historyIssue = histories.storageIssue
                self.errorMessage = nil
                self.isLoading = false
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
        timerTask?.cancel()
        refreshTask?.cancel()
        estimateTask?.cancel()
    }

    private func updateDemoEstimate() {
        guard let snapshot else { return }
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
    }

    private func refreshEstimate() {
        // Let an existing scan finish even if its card is temporarily out of view.
        guard estimateTask == nil else { return }
        let requestGeneration = generation
        let requestedAt = now()
        estimateTask = Task(priority: .utility) { [weak self, estimator, estimateCacheResetTask] in
            await estimateCacheResetTask?.value
            do {
                let result = try await estimator.estimate(now: requestedAt)
                guard let self, self.generation == requestGeneration, !Task.isCancelled else { return }
                self.todayEstimate = result
                self.estimateTask = nil
            } catch {
                guard let self, self.generation == requestGeneration, !Task.isCancelled else { return }
                self.todayEstimate = nil
                self.estimateTask = nil
            }
        }
    }

    private func updateTokenCollection() {
        guard !isDemo, showTokens, usageCardMode == .tokens, needsTokenRefresh else { return }
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

    private func updateLimitHistory() {
        guard let snapshot, isDemo else { return }
        limitHistory = .demo(now: snapshot.fetchedAt)
    }

    private func updateHistory() {
        guard let snapshot, isDemo, let window = snapshot.limits.featuredWindow,
              let period = UsagePeriod(window: window) else { history = PeriodHistory(); return }
        history = .demo(current: period)
    }

    func shutdown() async {
        stop()
        await refreshTask?.value
        await estimateTask?.value
        await estimateCacheResetTask?.value
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
