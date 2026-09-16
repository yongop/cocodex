import Foundation
import CryptoKit
import Darwin
import IOKit

private final class SyncFileCoordinator: @unchecked Sendable {
    // NSFileCoordinator supports cancellation from another thread. All other access is
    // confined to one synchronous exchange on the engine actor.
    let value = NSFileCoordinator()
    func cancel() { value.cancel() }
}

/// Offline-first outbox and bounded iCloud exchange. All disk work runs on this actor, never
/// the UI actor. There is no shared manifest, shared counter, or read/modify/write of a peer file.
public actor UsageSyncEngine {
    public struct Metrics: Sendable {
        public fileprivate(set) var filesRead = 0
        public fileprivate(set) var bytesRead = 0
        public fileprivate(set) var localWrites = 0
        public fileprivate(set) var cloudWrites = 0
        public fileprivate(set) var bytesWritten = 0
    }
    public private(set) var lastMetrics = Metrics()
    public static let retentionDays = 9
    public static let maximumFileBytes = 16 * 1_024 * 1_024
    public static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Co-Count/UsageSync/v1", isDirectory: true)
    }

    private struct Stamp: Equatable {
        let modified: Date?
        let size: Int
        let identity: String
    }
    private struct Cached {
        let stamp: Stamp
        let bytes: Data
        let shard: UsageSyncDay
    }
    private let localRoot: URL
    private let cloudOverride: URL?
    private let deviceOverride: String?
    private let deviceName: String
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private var deviceID: String?
    private var activeAccount: String?
    private var own: [Int: UsageSyncDay] = [:]
    private var cached: [URL: Cached] = [:]
    private var failed: [URL: Stamp] = [:]
    private var downloadRequests: [URL: Date] = [:]
    private var lastCleanup: Int?
    private var activeCoordinator: NSFileCoordinator?

    public init(localRoot: URL? = nil, cloudRoot: URL? = nil, deviceID: String? = nil,
                deviceName: String? = nil) {
        self.localRoot = (localRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Co-Count/UsageSync/v1", isDirectory: true)).resolvingSymlinksInPath()
        self.cloudOverride = cloudRoot?.resolvingSymlinksInPath()
        self.deviceOverride = deviceID
        self.deviceName = String((deviceName ?? Host.current().localizedName ?? "Mac").prefix(100))
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
    }

    public func exchange(snapshot: UsageSnapshot, local: UsageHistories,
                         estimate: TodayTokenEstimate?, now: Date = .now) async throws -> UsageSyncResult {
        let coordinator = SyncFileCoordinator()
        return try await withTaskCancellationHandler {
            activeCoordinator = coordinator.value
            defer { activeCoordinator = nil }
            return try performExchange(snapshot: snapshot, local: local, estimate: estimate, now: now)
        } onCancel: {
            coordinator.cancel()
        }
    }

    private func performExchange(snapshot: UsageSnapshot, local: UsageHistories,
                                 estimate: TodayTokenEstimate?, now: Date) throws -> UsageSyncResult {
        try Task.checkCancellation()
        lastMetrics = Metrics()
        var result = UsageSyncResult(limits: local.limits, periods: local.periods, estimate: estimate)
        guard let account = snapshot.syncAccountKey, Self.isDigest(account) else {
            result.issue = "계정을 확인한 뒤 동기화할 수 있어요."
            return result
        }
        let fm = FileManager.default
        try fm.createDirectory(at: localRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Also serialize two executable copies on this Mac. Nonblocking acquisition leaves
        // normal quota refreshes usable while another process finishes its exchange.
        let lock = open(localRoot.appendingPathComponent("writer.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw UsageSyncError.unavailable }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw UsageSyncError.busy }
        defer { flock(lock, LOCK_UN) }
        let device = try identity()
        if activeAccount != account {
            own.removeAll(); cached.removeAll(); failed.removeAll(); downloadRequests.removeAll()
            activeAccount = account
            lastCleanup = nil
        }
        let today = UsageSyncDay.number(now)
        let oldest = today - Self.retentionDays
        let localFolder = localRoot.appendingPathComponent(account).appendingPathComponent(device)
        try fm.createDirectory(at: localFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Only our own durable outbox is authoritative for publication, including after restart.
        for day in oldest...today {
            let file = localFolder.appendingPathComponent("\(day).json")
            if fm.fileExists(atPath: file.path) {
                let shard = try read(file, account: account, device: device, day: day)
                own[day] = Self.union(own[day], shard)
            }
        }
        own = own.filter { $0.key >= oldest && $0.key <= today }
        func empty(_ day: Int) -> UsageSyncDay {
            UsageSyncDay(account: account, device: device, name: deviceName, day: day)
        }
        // Bootstrap only this device's observations and legacy summaries, never merged UI data.
        for observation in local.limits.observations {
            let day = UsageSyncDay.number(observation.date)
            guard day >= oldest, day <= today else { continue }
            var shard = own[day] ?? empty(day)
            if shard.observations.last.map({ observation.date > $0.date }) ?? true {
                // At most one coverage heartbeat per minute, even during repeated manual refresh.
                if let last = shard.observations.last, observation.date.timeIntervalSince(last.date) < 60 { continue }
                // Keep both ends of constant spans so compaction never bridges an unobserved gap.
                if shard.observations.count >= 2 {
                    let a = shard.observations[shard.observations.count - 2]
                    let b = shard.observations[shard.observations.count - 1]
                    if a.windows == observation.windows, b.windows == observation.windows,
                       observation.date.timeIntervalSince(a.date) <= LimitUsageHistory.maximumGap {
                        shard.observations.removeLast()
                    }
                }
                shard.observations.append(observation)
                own[day] = shard
            }
        }
        for summary in local.limits.closedDays {
            let day = UsageSyncDay.number(summary.start)
            guard day >= oldest, day <= today else { continue }
            var shard = own[day] ?? empty(day)
            // Raw sync observations already cover post-upgrade days; summaries are only for migration.
            if shard.observations.isEmpty && !shard.legacy.contains(where: { $0.id == summary.id }) {
                shard.legacy.append(summary)
                own[day] = shard
            }
        }
        if let estimate, estimate.tokens != nil {
            for (day, events) in Dictionary(grouping: estimate.events, by: { UsageSyncDay.number($0.date) })
                where day >= oldest && day <= today {
                var shard = own[day] ?? empty(day)
                shard.tokens = Self.mergeEvents(shard.tokens, events)
                own[day] = shard
            }
            var shard = own[today] ?? empty(today)
            // Scan freshness is useful coverage metadata, but sub-minute repeats do not cause writes.
            if shard.tokenScan.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
                shard.tokenScan = now
                shard.tokenPartial = estimate.isPartial
            }
            own[today] = shard
        }
        for day in own.keys.sorted() {
            try Task.checkCancellation()
            own[day]?.name = deviceName
            let shard = own[day]!
            try shard.validate(account: account, device: device, day: day)
            try save(shard, to: localFolder.appendingPathComponent("\(day).json"), cloud: false)
        }
        let cloud = cloudFolder()
        result.folder = cloud
        var cloudIssue: String?
        if let cloud {
            do {
                let folder = cloud.appendingPathComponent(account).appendingPathComponent(device)
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                for day in own.keys.sorted() {
                    try Task.checkCancellation()
                    let file = folder.appendingPathComponent("\(day).json")
                    // A restarted process compares actual bytes once; unchanged shards stay untouched.
                    if fm.fileExists(atPath: file.path), cached[file] == nil {
                        _ = try? read(file, account: account, device: device, day: day)
                    }
                    try save(own[day]!, to: file, cloud: true)
                }
                try importPeers(cloud.appendingPathComponent(account), account: account,
                                device: device, oldest: oldest, today: today, now: now)
                if lastCleanup != today {
                    try prune(localFolder, before: oldest)
                    try prune(folder, before: oldest)
                    lastCleanup = today
                }
            } catch is CancellationError { throw CancellationError() }
            catch { cloudIssue = "iCloud 동기화를 기다리고 있어요. 기록은 이 Mac에 보관되며 다음 갱신에서 재시도해요." }
        } else {
            cloudIssue = "iCloud Drive를 켜면 저장된 기록을 자동으로 동기화해요."
        }
        cached = cached.filter { $0.value.shard.day >= oldest }
        failed = failed.filter { Int($0.key.deletingPathExtension().lastPathComponent).map { $0 >= oldest } ?? false }
        downloadRequests = downloadRequests.filter { now.timeIntervalSince($0.value) < 86_400 }
        let peers = cached.filter { _, entry in
            entry.shard.device != device && entry.shard.account == account
                && entry.shard.day >= oldest && entry.shard.day <= today
        }.values.map(\.shard)
        let shards = Array(own.values) + peers
        result.limits = .merging(local: local.limits, observations: shards.flatMap(\.observations),
                                archives: shards.flatMap(\.legacy), now: now)
        var periods = local.periods.periods
        for observation in shards.flatMap(\.observations) {
            if let window = observation.windows.first(where: { $0.minutes == 10_080 })
                ?? observation.windows.max(by: { $0.minutes < $1.minutes }) {
                periods.append(UsagePeriod(start: window.reset.addingTimeInterval(-Double(window.minutes) * 60), end: window.reset))
            }
        }
        result.periods = PeriodHistory()
        for period in periods.sorted(by: { $0.start < $1.start }) { result.periods.record(period) }
        let devices = Dictionary(grouping: shards, by: \.device)
        result.devices = devices.compactMap { id, values in
            guard let latest = values.max(by: { $0.lastSeen < $1.lastSeen }), latest.lastSeen != .distantPast else { return nil }
            return UsageSyncDevice(id: id, name: latest.name, lastSeen: latest.lastSeen, isCurrentDevice: id == device)
        }.sorted { $0.id < $1.id }
        let stale = result.devices.contains { !$0.isCurrentDevice && now.timeIntervalSince($0.lastSeen) > 30 * 60 }
        let start = Calendar.current.startOfDay(for: now)
        let available = estimate?.tokens != nil || shards.contains { ($0.tokenScan ?? .distantPast) >= start }
        result.estimate = .merged(shards.flatMap(\.tokens), now: now, available: available,
                                  partial: estimate?.isPartial == true || stale || cloudIssue != nil
                                    || shards.contains { ($0.tokenScan ?? .distantPast) >= start && $0.tokenPartial })
        result.issue = cloudIssue
        return result
    }

    private func cloudFolder() -> URL? {
        if let cloudOverride { return cloudOverride }
        let folder = Self.defaultFolder.resolvingSymlinksInPath()
        let drive = folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // Do not manufacture a local lookalike when iCloud Drive is disabled.
        guard FileManager.default.ubiquityIdentityToken != nil,
              FileManager.default.fileExists(atPath: drive.path) else { return nil }
        return folder
    }

    private func identity() throws -> String {
        if let deviceID { return deviceID }
        if let deviceOverride {
            guard Self.isDigest(deviceOverride) else { throw UsageSyncError.invalidFile }
            deviceID = deviceOverride
            return deviceOverride
        }
        let file = localRoot.appendingPathComponent("installation-id")
        let installation: String
        if FileManager.default.fileExists(atPath: file.path) {
            installation = try String(contentsOf: file, encoding: .utf8)
            guard UUID(uuidString: installation) != nil else { throw UsageSyncError.invalidFile }
        } else {
            installation = UUID().uuidString
            try Data(installation.utf8).write(to: file, options: .atomic)
        }
        // A migrated home directory retains its installation ID, but must get a separate writer
        // namespace on the new Mac. Only the salted hash is stored in the cloud.
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { throw UsageSyncError.unavailable }
        defer { IOObjectRelease(service) }
        guard let host = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String else { throw UsageSyncError.unavailable }
        let id = usageSyncDigest("\(installation)|\(host)")
        deviceID = id
        return id
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }

    private func stamp(_ file: URL) throws -> Stamp {
        let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey,
                                                       .fileResourceIdentifierKey, .isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true,
              let size = values.fileSize, size > 0, size <= Self.maximumFileBytes else { throw UsageSyncError.invalidFile }
        return Stamp(modified: values.contentModificationDate, size: size,
                     identity: String(describing: values.fileResourceIdentifier))
    }

    private func read(_ file: URL, account: String, device: String, day: Int) throws -> UsageSyncDay {
        let signature = try stamp(file)
        if let entry = cached[file], entry.stamp == signature { return entry.shard }
        if failed[file] == signature { throw UsageSyncError.invalidFile }
        do {
            let bytes: Data = try coordinate(file, writing: false) { url in
                _ = try self.stamp(url)
                return try Data(contentsOf: url)
            }
            lastMetrics.filesRead += 1
            lastMetrics.bytesRead += bytes.count
            guard bytes.count <= Self.maximumFileBytes else { throw UsageSyncError.invalidFile }
            let shard = try decoder.decode(UsageSyncDay.self, from: bytes)
            try shard.validate(account: account, device: device, day: day)
            let merged = device == deviceID ? shard : Self.union(cached[file]?.shard, shard)
            cached[file] = Cached(stamp: signature, bytes: bytes, shard: merged)
            failed[file] = nil
            return merged
        } catch {
            if error is DecodingError || error is UsageSyncError { failed[file] = signature }
            throw error
        }
    }

    private func save(_ shard: UsageSyncDay, to file: URL, cloud: Bool) throws {
        if let entry = cached[file], entry.shard == shard, (try? stamp(file)) == entry.stamp { return }
        let data = try encoder.encode(shard)
        guard data.count <= Self.maximumFileBytes else { throw UsageSyncError.invalidFile }
        // Account for external deletion/replacement without reading unchanged file contents.
        if let entry = cached[file], entry.bytes == data, (try? stamp(file)) == entry.stamp { return }
        try coordinate(file, writing: true) { try data.write(to: $0, options: .atomic) }
        cached[file] = Cached(stamp: try stamp(file), bytes: data, shard: shard)
        failed[file] = nil
        if cloud { lastMetrics.cloudWrites += 1 } else { lastMetrics.localWrites += 1 }
        lastMetrics.bytesWritten += data.count
    }

    private func importPeers(_ folder: URL, account: String, device: String, oldest: Int, today: Int, now: Date) throws {
        let fm = FileManager.default
        let folders = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        var issue = false
        for peer in folders.sorted(by: { $0.path < $1.path }).prefix(64) {
            let id = peer.lastPathComponent
            guard id != device, Self.isDigest(id) else { continue }
            let values = try peer.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let files = try fm.contentsOfDirectory(at: peer, includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey])
            for candidate in files {
                try Task.checkCancellation()
                // Finder may expose evicted items as .<name>.icloud placeholders.
                var name = candidate.lastPathComponent
                if name.hasPrefix("."), name.hasSuffix(".icloud") { name = String(name.dropFirst().dropLast(7)) }
                guard name.hasSuffix(".json"), let day = Int(name.dropLast(5)), day >= oldest, day <= today,
                      name == "\(day).json" else { continue }
                let file = peer.appendingPathComponent(name)
                let status = try? candidate.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
                if candidate != file || status == .notDownloaded {
                    if downloadRequests[file].map({ now.timeIntervalSince($0) >= 300 }) ?? true {
                        try? fm.startDownloadingUbiquitousItem(at: file)
                        downloadRequests[file] = now
                    }
                    issue = true
                    continue
                }
                do { _ = try read(file, account: account, device: id, day: day) }
                catch { issue = true }
            }
        }
        if issue { throw UsageSyncError.unavailable }
    }

    private func prune(_ folder: URL, before day: Int) throws {
        // Delete only this device's expired shards. Offline peers own their own retention.
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            guard file.pathExtension == "json", let number = Int(file.deletingPathExtension().lastPathComponent), number < day else { continue }
            try coordinate(file, writing: true, deleting: true) { try FileManager.default.removeItem(at: $0) }
            cached[file] = nil
        }
    }

    private func coordinate<T>(_ file: URL, writing: Bool, deleting: Bool = false,
                               body: @escaping (URL) throws -> T) throws -> T {
        var failure: NSError?
        var result: Result<T, Error>?
        let accessor: (URL) -> Void = { url in result = Result { try body(url) } }
        try Task.checkCancellation()
        let coordinator = activeCoordinator ?? NSFileCoordinator()
        if writing {
            coordinator.coordinate(writingItemAt: file, options: deleting ? .forDeleting : .forReplacing,
                                   error: &failure, byAccessor: accessor)
        } else {
            coordinator.coordinate(readingItemAt: file, options: .withoutChanges, error: &failure, byAccessor: accessor)
        }
        if let failure { throw failure }
        guard let result else { throw UsageSyncError.unavailable }
        return try result.get()
    }

    private static func mergeEvents(_ first: [TokenUsageEvent], _ second: [TokenUsageEvent]) -> [TokenUsageEvent] {
        if first == second || second.isEmpty { return first }
        var events = Dictionary(first.map { ($0.id, $0) }, uniquingKeysWith: { $0.tokens >= $1.tokens ? $0 : $1 })
        for event in second where event.tokens > (events[event.id]?.tokens ?? 0) { events[event.id] = event }
        return events.values.sorted { $0.id < $1.id }
    }

    private static func union(_ previous: UsageSyncDay?, _ incoming: UsageSyncDay) -> UsageSyncDay {
        guard let previous, previous != incoming else { return incoming }
        var result = incoming
        result.tokens = mergeEvents(previous.tokens, incoming.tokens)
        // Own disk data is newer if another local process completed a serialized exchange.
        if previous.lastSeen > incoming.lastSeen {
            result.observations = previous.observations
            result.tokenScan = previous.tokenScan
            result.tokenPartial = previous.tokenPartial
        }
        return result
    }
}
