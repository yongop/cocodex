import Foundation
import CryptoKit

public struct UsageHistories: Sendable {
    public var periods = PeriodHistory()
    public var limits = LimitUsageHistory()
    public var storageIssue: String?
}

/// One active JSON per account plus immutable, checksummed day files. Only JSON is rewritten
/// on normal refreshes. Its archive references are the commit point for a rollover/migration.
public actor UsageHistoryPersistence {
    private struct ActiveState: Codable {
        let version: Int
        let history: LimitUsageHistory
        let archives: [String]
    }

    public struct WriteMetrics: Sendable {
        public fileprivate(set) var activeBytes = 0
        public fileprivate(set) var archiveBytes = 0
        public fileprivate(set) var archiveFiles = 0
    }
    public private(set) var lastWrite = WriteMetrics()
    private let defaults: UserDefaults
    private let root: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var accountKey: String?
    private var cached = UsageHistories()
    private var needsLoad = true
    private var lastPrunedDay: Date?
    private var savedPeriods: [UsagePeriod] = []
    private var needsCleanup = true
    private var requiresInitialCommit = true
    // A narrow injection point allows tests to simulate a failed atomic commit.
    private let write: @Sendable (Data, URL) throws -> Void

    public init(suiteName: String? = nil, root: URL? = nil,
                write: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Co-Count/UsageHistory/v2", isDirectory: true)
        self.write = write
    }

    func directory(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(digest, isDirectory: true)
    }

    public func record(_ snapshot: UsageSnapshot, calendar: Calendar = .current) throws -> UsageHistories {
        try Task.checkCancellation()
        lastWrite = WriteMetrics()
        guard let key = snapshot.historyKey else {
            accountKey = nil
            cached = UsageHistories()
            needsLoad = true
            cached.limits.record(snapshot)
            if let window = snapshot.limits.featuredWindow, let period = UsagePeriod(window: window) {
                cached.periods.record(period)
            }
            return cached
        }
        if accountKey != key {
            cached = UsageHistories()
            accountKey = key
            needsLoad = true
        }
        if needsLoad {
            do {
                var loaded = try load(key: key)
                // Keep observations made while a temporarily unreadable store was being retried.
                for observation in cached.limits.observations { loaded.limits.recordObservation(observation) }
                cached = loaded
                savedPeriods = loaded.periods.periods
                needsCleanup = true
                needsLoad = false
            } catch {
                cached.limits.record(snapshot)
                cached.storageIssue = "저장된 이력을 읽지 못했어요. 현재 사용량은 갱신되며 다음 조회에서 다시 시도해요."
                return cached
            }
        }
        let previousDate = cached.limits.observations.last?.date
        cached.limits.record(snapshot)
        let period = snapshot.limits.featuredWindow.flatMap(UsagePeriod.init(window:))
        if let period { cached.periods.record(period) }
        guard cached.limits.observations.last?.date != previousDate || cached.storageIssue != nil || requiresInitialCommit else {
            return cached
        }
        var candidate = cached
        candidate.limits.closePastDays(now: snapshot.fetchedAt, calendar: calendar)
        do {
            try Task.checkCancellation()
            try commit(candidate.limits, key: key)
            cached = candidate
            cached.storageIssue = nil
            requiresInitialCommit = false
            if cached.periods.periods != savedPeriods, let data = try? encoder.encode(cached.periods) {
                defaults.set(data, forKey: "periodHistory.v1.\(key)")
                savedPeriods = cached.periods.periods
            }
            pruneExpiredAccounts(now: snapshot.fetchedAt, calendar: calendar)
        } catch is CancellationError { throw CancellationError() }
        catch {
            // Keep the unclosed raw backlog in memory. The previous on-disk commit and legacy
            // data remain available; a later successful refresh retries the entire rollover.
            cached.storageIssue = "이력 저장을 완료하지 못했어요. 현재 사용량은 갱신되며 다음 조회에서 다시 저장해요."
        }
        var result = cached
        if period == nil { result.periods = PeriodHistory() }
        return result
    }

    private func load(key: String) throws -> UsageHistories {
        var result = UsageHistories()
        let folder = directory(for: key)
        let stateURL = folder.appendingPathComponent("today.json")
        requiresInitialCommit = !FileManager.default.fileExists(atPath: stateURL.path)
        if !requiresInitialCommit {
            let state = try decoder.decode(ActiveState.self, from: read(stateURL, maximumBytes: 8 * 1_024 * 1_024))
            guard state.version == 2, state.archives.count <= 256,
                  Set(state.archives).count == state.archives.count else { throw HistoryStorageError.invalidArchive }
            var days: [LimitUsageDay] = []
            for name in state.archives {
                guard isDayFile(name) else { throw HistoryStorageError.invalidArchive }
                let day = try LimitUsageDay.decode(read(folder.appendingPathComponent(name), maximumBytes: 256 * 1_024))
                guard day.fileName == name else { throw HistoryStorageError.invalidArchive }
                days.append(day)
            }
            result.limits = state.history
            try result.limits.restoreClosedDays(days)
        } else if let data = defaults.data(forKey: "limitUsageHistory.v1.\(key)") {
            // Do not silently discard corrupt legacy data or overwrite it with an empty history.
            result.limits = try decoder.decode(LimitUsageHistory.self, from: data)
        }
        result.periods = defaults.data(forKey: "periodHistory.v1.\(key)")
            .flatMap { try? decoder.decode(PeriodHistory.self, from: $0) } ?? PeriodHistory()
        return result
    }

    private func commit(_ history: LimitUsageHistory, key: String) throws {
        let fm = FileManager.default
        let folder = directory(for: key)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        guard history.closedDays.count <= 256 else { throw HistoryStorageError.invalidArchive }
        let committed = Set(cached.limits.closedDays.map(\.fileName))
        let names = history.closedDays.map(\.fileName)
        let stateURL = folder.appendingPathComponent("today.json")
        var created: [URL] = []
        var stateCommitted = false
        defer {
            if !stateCommitted {
                // Avoid accumulating new UUID files on repeated handled failures. A write may
                // have committed before reporting an error, so preserve on-disk references.
                let state = try? decoder.decode(ActiveState.self,
                    from: read(stateURL, maximumBytes: 8 * 1_024 * 1_024))
                let live = Set(state?.archives ?? [])
                for url in created where !live.contains(url.lastPathComponent) { try? fm.removeItem(at: url) }
            }
        }
        for day in history.closedDays where !committed.contains(day.fileName) {
            let data = try day.encoded()
            let url = folder.appendingPathComponent(day.fileName)
            created.append(url)
            try write(data, url)
            // Verify new summaries before the raw observations may be dropped from disk.
            guard try LimitUsageDay.decode(read(url, maximumBytes: 256 * 1_024)) == day else {
                throw HistoryStorageError.invalidArchive
            }
            lastWrite.archiveBytes += data.count
            lastWrite.archiveFiles += 1
        }
        let state = ActiveState(version: 2, history: history, archives: names)
        let data = try encoder.encode(state)
        try write(data, stateURL)
        stateCommitted = true
        lastWrite.activeBytes = data.count
        let legacyKey = "limitUsageHistory.v1.\(key)"
        if defaults.data(forKey: legacyKey) != nil {
            guard try read(stateURL, maximumBytes: 8 * 1_024 * 1_024) == data else {
                throw HistoryStorageError.invalidArchive
            }
            defaults.removeObject(forKey: legacyKey)
        }
        // Unreferenced files include expired summaries and interrupted, uncommitted rollovers.
        if needsCleanup || committed != Set(names),
           let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            needsCleanup = false
            let live = Set(names)
            for file in files where isDayFile(file.lastPathComponent) && !live.contains(file.lastPathComponent) {
                try? fm.removeItem(at: file)
            }
        }
    }

    private func read(_ url: URL, maximumBytes: Int) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= maximumBytes else { throw HistoryStorageError.invalidArchive }
        return try Data(contentsOf: url)
    }

    private func isDayFile(_ name: String) -> Bool {
        name.hasPrefix("day-") && name.hasSuffix(".bin") && name.count == 44
            && UUID(uuidString: String(name.dropFirst(4).dropLast(4))) != nil
    }

    private func pruneExpiredAccounts(now: Date, calendar: Calendar) {
        let today = calendar.startOfDay(for: now)
        guard lastPrunedDay != today else { return }
        lastPrunedDay = today
        let cutoff = calendar.date(byAdding: .day, value: -8, to: today)!
        for (name, value) in defaults.dictionaryRepresentation() where name.hasPrefix("limitUsageHistory.v1.") {
            guard let data = value as? Data, let history = try? decoder.decode(LimitUsageHistory.self, from: data),
                  history.observations.last.map({ $0.date < cutoff }) ?? true else { continue }
            defaults.removeObject(forKey: name)
        }
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for folder in folders {
            let name = folder.lastPathComponent
            guard name.count == 64, name.allSatisfy({ $0.isHexDigit }),
                  (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                  folder != accountKey.map(directory(for:)) else { continue }
            let stateURL = folder.appendingPathComponent("today.json")
            if !fm.fileExists(atPath: stateURL.path) {
                // A process killed before its first commit can leave an unreferenced folder.
                if let modified = try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   modified < cutoff { try? fm.removeItem(at: folder) }
                continue
            }
            guard let data = try? read(stateURL, maximumBytes: 8 * 1_024 * 1_024),
                  let state = try? decoder.decode(ActiveState.self, from: data), state.version == 2,
                  let last = state.history.observations.last, last.date < cutoff else { continue }
            try? fm.removeItem(at: folder)
        }
    }
}
