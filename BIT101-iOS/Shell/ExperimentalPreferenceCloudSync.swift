import ScoreDomain
import ScorePorts
import CommunityPersistence
import CommunityCore
import StorageCore
import ScoreInfrastructure
import Combine
import Foundation
import CryptoKit
import OSLog
import TransportCore
import CloudKit
import os

/// 用户偏好和成绩缓存的实验性 iCloud 同步域。
nonisolated enum ExperimentalPreferenceSyncDomain: String, CaseIterable, Hashable {
    case appSettings = "app-settings"
    case scoreFilters = "score-filters"
    case scoreCache = "score-cache"
    case galleryMessageRead = "gallery-message-read"
}

nonisolated enum ExperimentalPreferenceSyncDecision: Equatable {
    case applyRemote
    case uploadLocal
    case noChange
}

nonisolated enum ExperimentalPreferenceSyncPolicy {
    static func decision(localUpdatedAt: Date?, remoteUpdatedAt: Date?) -> ExperimentalPreferenceSyncDecision {
        switch (localUpdatedAt, remoteUpdatedAt) {
        case (nil, nil): .noChange
        case (nil, .some): .applyRemote
        case (.some, nil): .uploadLocal
        case let (.some(local), .some(remote)) where remote > local: .applyRemote
        case let (.some(local), .some(remote)) where local > remote: .uploadLocal
        default: .noChange
        }
    }
}

/// Compresses the comparatively large score snapshot before placing it in iCloud KVS.

nonisolated enum ExperimentalPreferenceCloudQuotaPolicy {
    static let maximumValueSize = 1_048_576
    static let maximumValueCount = 1_024
    static let maximumKeyUTF16Count = 128

    static func canStore(
        valueSize: Int,
        existingValueBytes: Int,
        existingKeyCount: Int,
        replacingExistingKey: Bool,
        keyUTF16Count: Int
    ) -> Bool {
        guard keyUTF16Count <= maximumKeyUTF16Count,
              valueSize >= 0,
              valueSize <= maximumValueSize,
              existingValueBytes >= 0,
              existingValueBytes <= maximumValueSize - valueSize
        else { return false }
        return replacingExistingKey || existingKeyCount < maximumValueCount
    }
}

protocol PreferenceCloudStoring: AnyObject {
    var dictionaryRepresentation: [String: Any] { get }
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: PreferenceCloudStoring {}

/// 使用 iCloud Key-Value Store 同步设置、成绩筛选偏好、成绩缓存和消息已读状态。
///
/// 开关保存在当前设备并按学号隔离，默认关闭；设置与筛选按字段合并，已读取并集，成绩按快照版本同步。
@MainActor
final class ExperimentalPreferenceCloudSync: ObservableObject {
    nonisolated enum RecordCleanupScope { case currentAccount, otherAccounts }
    private nonisolated enum CloudValue: Equatable, Sendable { case missing, data(Data), invalid }
    private nonisolated struct RemoteSnapshot<Payload: Codable & Sendable>: Sendable {
        let envelope: ExperimentalPreferenceSyncEnvelope<Payload>?
        let key: String
        let records: [String: CloudValue]
    }

    static let shared = ExperimentalPreferenceCloudSync(settings: .shared, stores: .shared)

    private static var defaultCloudStore: any PreferenceCloudStoring {
#if BIT101_AUTOMATED_TESTING && !BIT101_UI_TESTING
        return AutomatedTestPreferenceCloudStore.shared
#else
        return NSUbiquitousKeyValueStore.default
#endif
    }

    private static let logger = Logger(subsystem: "BIT101", category: "PreferenceCloudSync")

    @Published private(set) var isEnabled = false
    @Published private(set) var syncIssue: String?
    private var syncIssueDomain: ExperimentalPreferenceSyncDomain?
    private var legacyRecordIssues: [ExperimentalPreferenceSyncDomain: String] = [:]

    private let defaults: UserDefaults
    let settings: AppSettingsStore
    let stores: AppAccountStores
    private let cloudStore: any PreferenceCloudStoring
    private let scoreEncryption: ScoreCacheSyncEncryption
    private let synchronizedDomains: Set<ExperimentalPreferenceSyncDomain>
    private var cloudObserverTask: Task<Void, Never>?
    private var reconciliationGeneration = 0
    private let cloudAccountGeneration = OSAllocatedUnfairLock(initialState: 0)
    private struct Generation: Equatable {
        let reconciliation: Int
        let cloudAccount: Int
    }
    private var currentGeneration: Generation {
        Generation(reconciliation: reconciliationGeneration, cloudAccount: cloudAccountGeneration.withLock { $0 })
    }
    private struct PendingScoreMutation {
        var updatedAt: Date
        let remoteSHA256: Data?
    }
    private var pendingScoreMutation: PendingScoreMutation? {
        get {
            guard let record = defaults.dictionary(forKey: pendingScoreKey), let date = record["updatedAt"] as? Date else { return nil }
            return PendingScoreMutation(updatedAt: date, remoteSHA256: record["remoteSHA256"] as? Data)
        }
        set {
            guard let newValue else { defaults.removeObject(forKey: pendingScoreKey); return }
            var record: [String: Any] = ["updatedAt": newValue.updatedAt]
            record["remoteSHA256"] = newValue.remoteSHA256
            defaults.set(record, forKey: pendingScoreKey)
        }
    }
    private var pendingScoreKey: String {
        "experimental.preference-cloud-sync.pending-score.\(localAccountIdentifier)"
    }
    private var reconciliationTask: Task<Void, Never>?
    private var pendingReconciliationDomains = Set<ExperimentalPreferenceSyncDomain>()
    private var saveSubscriptions = Set<AnyCancellable>()

    init(
        settings: AppSettingsStore,
        stores: AppAccountStores,
        defaults: UserDefaults = AppFileDirectories.defaults,
        cloudStore: any PreferenceCloudStoring = ExperimentalPreferenceCloudSync.defaultCloudStore,
        scoreEncryption: ScoreCacheSyncEncryption? = nil,
        synchronizedDomains: Set<ExperimentalPreferenceSyncDomain> = Set(ExperimentalPreferenceSyncDomain.allCases),
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.cloudStore = cloudStore
        self.scoreEncryption = scoreEncryption ?? .production(defaults: defaults)
        self.synchronizedDomains = synchronizedDomains
        self.settings = settings
        self.stores = stores
        isEnabled = loadEnabledPreference()
        capturePreferenceBaselines()
        settings.localSaves.sink { [weak self] in self?.localValueDidChange(in: .appSettings, for: $0) }.store(in: &saveSubscriptions)
        stores.scoreCache.localSaves.sink { [weak self] in self?.localValueDidChange(in: .scoreCache, for: $0) }.store(in: &saveSubscriptions)
        stores.scoreFilterPreferences.localSaves.sink { [weak self] in self?.localValueDidChange(in: .scoreFilters, for: $0) }.store(in: &saveSubscriptions)
        settings.recoveries.sink { [weak self] in self?.recoverPreferences(in: .appSettings, for: $0) }.store(in: &saveSubscriptions)
        stores.scoreFilterPreferences.recoveries.sink { [weak self] in self?.recoverPreferences(in: .scoreFilters, for: $0) }.store(in: &saveSubscriptions)
        stores.communityMessages.localSaves.sink { [weak self] in self?.localValueDidChange(in: .galleryMessageRead, for: $0) }.store(in: &saveSubscriptions)

        let accountChanges = notificationCenter.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)
            .filter { @Sendable [cloudIdentity = ObjectIdentifier(cloudStore)] notification in
                notification.object.map { ObjectIdentifier($0 as AnyObject) } == cloudIdentity
                    && (notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? NSNumber)?.intValue == NSUbiquitousKeyValueStoreAccountChange
            }
        accountChanges.merge(with: notificationCenter.publisher(for: .CKAccountChanged))
            .sink { @Sendable [weak self, cloudAccountGeneration] _ in
                cloudAccountGeneration.withLock { $0 &+= 1 }
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.reloadForCurrentAccount()
                }
            }.store(in: &saveSubscriptions)

        cloudObserverTask = Task { @MainActor [weak self, cloudStore] in
            for await notification in notificationCenter.notifications(
                named: NSUbiquitousKeyValueStore.didChangeExternallyNotification
            ) {
                guard (notification.object as AnyObject?) === cloudStore else { continue }
                let changedKeys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
                let changeReason = (notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? NSNumber)?.intValue
                guard let self else { return }
                self.handleExternalChange(changedKeys: changedKeys, changeReason: changeReason)
            }
        }

    }

    deinit {
        cloudObserverTask?.cancel()
        reconciliationTask?.cancel()
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        defaults.set(enabled, forKey: enabledKey)
        if legacyEnabledKey != enabledKey { defaults.removeObject(forKey: legacyEnabledKey) }
        isEnabled = enabled
        guard enabled else {
            reconciliationGeneration &+= 1
            reconciliationTask?.cancel()
            reconciliationTask = nil
            pendingReconciliationDomains.removeAll()
            syncIssue = nil
            syncIssueDomain = nil
            return
        }

        synchronizeCloudStore()
        scheduleReconciliation(for: ExperimentalPreferenceSyncDomain.allCases)
    }

    /// 本地业务数据发生变化时记录时间；只有实验开关打开才立即上传。
    func localValueDidChange(
        in domain: ExperimentalPreferenceSyncDomain,
        for session: AppStorageSession? = nil
    ) {
        guard synchronizedDomains.contains(domain) else { return }
        let owner = domain == .scoreCache ? stores.scoreSession() : stores.currentSession()
        if let session, session != owner {
            guard domain == .scoreCache || domain == .galleryMessageRead else { return }
            let updatedAt = nextLocalUpdatedAt(for: domain, owner: session)
            setLocalUpdatedAt(updatedAt, for: domain, owner: session)
            if domain == .scoreCache {
                var record: [String: Any] = ["updatedAt": updatedAt]
                record["remoteSHA256"] = Self.scoreDigest(scoreCloudData(owner: session))
                defaults.set(record, forKey: "experimental.preference-cloud-sync.pending-score.\(session.accountStorageIdentifier)")
            }
            return
        }
        guard localSnapshotIsReadable(domain) else { return }
        switch domain {
        case .appSettings:
            recordPreferences(AppSettingsSyncPayload(snapshot: settings.snapshot), domain: domain)
        case .scoreFilters:
            recordPreferences(stores.scoreFilterPreferences.load() ?? ScoreFilterPreferenceSnapshot(), domain: domain)
        case .scoreCache:
            let updatedAt = nextLocalUpdatedAt(for: domain)
            pendingScoreMutation = PendingScoreMutation(updatedAt: updatedAt, remoteSHA256: Self.scoreDigest(scoreCloudData()))
            setLocalUpdatedAt(updatedAt, for: domain)
            if isEnabled { scheduleReconciliation(for: [domain]) }
        case .galleryMessageRead:
            setLocalUpdatedAt(nextLocalUpdatedAt(for: domain), for: domain)
            if isEnabled { scheduleReconciliation(for: [domain]) }
        }
    }

    /// 启动和回到前台时补做一次拉取，兼容系统没有及时投递外部变更通知的情况。
    @discardableResult
    func refreshFromCloudIfNeeded() -> Task<Void, Never>? {
        guard isEnabled else { return nil }
        synchronizeCloudStore()
        scheduleReconciliation(for: ExperimentalPreferenceSyncDomain.allCases)
        return reconciliationTask
    }

#if DEBUG || ICLOUD_CROSS_DEVICE_SMOKE
    @discardableResult
    func reconcileCloudSnapshot() -> Task<Void, Never>? {
        guard isEnabled else { return nil }
        scheduleReconciliation(for: ExperimentalPreferenceSyncDomain.allCases)
        return reconciliationTask
    }

    func synchronizedVersion(for domain: ExperimentalPreferenceSyncDomain) -> Date? {
        localUpdatedAt(for: domain)
    }
#endif

    func reloadForCurrentAccount() {
        legacyRecordIssues.removeAll()
        stores.communityMessages.invalidateSnapshot()
        reconciliationGeneration &+= 1
        reconciliationTask?.cancel()
        reconciliationTask = nil
        pendingReconciliationDomains.removeAll()
        syncIssue = nil
        syncIssueDomain = nil
        isEnabled = loadEnabledPreference()
        capturePreferenceBaselines()
        guard isEnabled else { return }
        synchronizeCloudStore()
        scheduleReconciliation(for: ExperimentalPreferenceSyncDomain.allCases)
    }

    /// 用户确认后暂停本机同步，删除所选账号的既有偏好记录。
    @discardableResult
    func removeCloudRecords(in scope: RecordCleanupScope) -> Bool {
        setEnabled(false)
        let owner = accountIdentifier
        let keys = cloudStore.dictionaryRepresentation.keys.filter { key in
            let parts = key.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4, parts[0] == "preference-sync",
                  ["v1", "v2"].contains(String(parts[1])),
                  !parts[2].isEmpty, ExperimentalPreferenceSyncDomain(rawValue: String(parts[3])) != nil
            else { return false }
            return scope == .currentAccount ? parts[2] == owner : parts[2] != owner
        }
        for key in keys { cloudStore.set(nil, forKey: key) }
        guard keys.allSatisfy({ cloudStore.dictionaryRepresentation[$0] == nil }), synchronizeCloudStore() else {
            syncIssue = "云端偏好记录清理暂时失败。本机同步已暂停，数据继续保留，请稍后重试。"
            syncIssueDomain = nil
            return false
        }
        syncIssue = nil
        syncIssueDomain = nil
        return true
    }

    private func handleExternalChange(changedKeys: [String]?, changeReason: Int?) {
        guard isEnabled else { return }
        if changeReason == NSUbiquitousKeyValueStoreAccountChange { return }
        if changeReason == NSUbiquitousKeyValueStoreQuotaViolationChange {
            syncIssue = "BIT101 的 iCloud 同步记录达到应用容量上限。本机设置和成绩缓存继续保留；可在日历设置中清理云端偏好记录，再开启偏好同步。"
            syncIssueDomain = changedKeys?.compactMap { key in
                ExperimentalPreferenceSyncDomain.allCases.first { cloudKeys(for: $0).contains(key) }
            }.first
            Self.logger.error("iCloud KVS quota violation")
            return
        }
        let domains = ExperimentalPreferenceSyncDomain.allCases.filter {
            changedKeys == nil || cloudKeys(for: $0).contains { changedKeys?.contains($0) == true }
        }
        scheduleReconciliation(for: domains)
    }

    /// KVS 外部变更通知由系统内部串行队列派发；必须等通知栈退出后再读写 KVS，
    /// 否则在同步应用偏好并触发另一域写回时会造成 libdispatch 递归加锁崩溃。
    private func scheduleReconciliation(for domains: [ExperimentalPreferenceSyncDomain]) {
        let selected = Set(domains).intersection(synchronizedDomains)
        guard !selected.isEmpty else { return }
        pendingReconciliationDomains.formUnion(selected)
        guard reconciliationTask == nil else { return }

        let generation = currentGeneration
        reconciliationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, self.isEnabled else {
                return
            }

            while !Task.isCancelled, self.isEnabled, !self.pendingReconciliationDomains.isEmpty {
                let domains = self.pendingReconciliationDomains
                self.pendingReconciliationDomains.removeAll()

                for domain in ExperimentalPreferenceSyncDomain.allCases
                where domains.contains(domain) {
                    guard !Task.isCancelled, self.isEnabled else { return }
                    await self.reconcile(domain: domain)
                }
            }

            if !Task.isCancelled, self.currentGeneration == generation {
                self.reconciliationTask = nil
            }
        }
    }

    private func reconcile(domain: ExperimentalPreferenceSyncDomain) async {
        guard localSnapshotIsReadable(domain) else { return }
        switch domain {
        case .appSettings:
            await reconcilePreferences(AppSettingsSyncPayload(snapshot: settings.snapshot), domain: domain,
                apply: settings.applySyncedPreferences)
        case .scoreFilters:
            await reconcilePreferences(stores.scoreFilterPreferences.load() ?? ScoreFilterPreferenceSnapshot(), domain: domain,
                apply: stores.scoreFilterPreferences.applySynced)
        case .scoreCache:
            let session = stores.scoreSession()
            let version = localUpdatedAt(for: domain)
            do {
                guard let localPayload = try await stores.scoreCache.syncPayload(for: session),
                      !Task.isCancelled, stores.scoreSession() == session,
                      localUpdatedAt(for: domain) == version else { return }
                await reconcileScore(localPayload: localPayload, session: session)
            } catch {
                guard stores.scoreSession() == session, localUpdatedAt(for: domain) == version else { return }
                reportPreferenceError(error, domain: domain)
            }
        case .galleryMessageRead:
            await reconcileMessages()
        }
    }

    private func capturePreferenceBaselines() {
        if synchronizedDomains.contains(.appSettings), localSnapshotIsReadable(.appSettings) {
            captureBaseline(AppSettingsSyncPayload(snapshot: settings.snapshot), domain: .appSettings)
        }
        if synchronizedDomains.contains(.scoreFilters), localSnapshotIsReadable(.scoreFilters) {
            captureBaseline(stores.scoreFilterPreferences.load() ?? ScoreFilterPreferenceSnapshot(), domain: .scoreFilters)
        }
    }

    private func localSnapshotIsReadable(_ domain: ExperimentalPreferenceSyncDomain) -> Bool {
        let failed: Bool
        switch domain {
        case .appSettings: failed = settings.storageIssue != nil
        case .scoreFilters: failed = stores.scoreFilterPreferences.hasUnreadableSnapshot
        case .galleryMessageRead: failed = stores.communityMessages.hasUnreadableSnapshot
        case .scoreCache: failed = false
        }
        if failed { reportPreferenceError(PreferenceSyncRecordError.invalidStoredValue, domain: domain) }
        return !failed
    }

    private func captureBaseline<Payload: Codable>(_ payload: Payload, domain: ExperimentalPreferenceSyncDomain) {
        do {
            let previous: ExperimentalPreferenceSyncEnvelope<Payload>? = try localPreferenceEnvelope(for: domain)
            guard previous == nil else { return }
            let baseline = try PreferenceFieldMerge.recording(payload, previous: nil, at: localUpdatedAt(for: domain) ?? .distantPast)
            try storePreferenceEnvelope(baseline, for: domain)
        } catch { reportPreferenceError(error, domain: domain) }
    }

    /// 显式恢复业务设置时重建所属账号的派生合并基线。
    private func recoverPreferences(in domain: ExperimentalPreferenceSyncDomain, for owner: AppStorageSession) {
        guard owner == stores.currentSession(), synchronizedDomains.contains(domain), localSnapshotIsReadable(domain) else { return }
        switch domain {
        case .appSettings:
            recordPreferences(AppSettingsSyncPayload(snapshot: settings.snapshot), domain: domain, replacingEnvelope: true)
        case .scoreFilters:
            recordPreferences(stores.scoreFilterPreferences.load() ?? ScoreFilterPreferenceSnapshot(), domain: domain, replacingEnvelope: true)
        case .scoreCache, .galleryMessageRead: break
        }
    }

    private func recordPreferences<Payload: Codable & Equatable>(
        _ payload: Payload, domain: ExperimentalPreferenceSyncDomain, replacingEnvelope: Bool = false
    ) {
        do {
            let previous: ExperimentalPreferenceSyncEnvelope<Payload>?
            if replacingEnvelope { previous = nil }
            else { previous = try localPreferenceEnvelope(for: domain) }
            let value = try PreferenceFieldMerge.recording(payload, previous: previous, at: nextLocalUpdatedAt(for: domain))
            try storePreferenceEnvelope(value, for: domain)
            setLocalUpdatedAt(value.updatedAt, for: domain)
            clearPreferenceError(domain)
            guard isEnabled else { return }
            scheduleReconciliation(for: [domain])
        } catch { reportPreferenceError(error, domain: domain) }
    }

    private func reconcilePreferences<Payload: Codable & Equatable & Sendable>(
        _ payload: Payload, domain: ExperimentalPreferenceSyncDomain, apply: (Payload) -> Bool
    ) async {
        let owner = stores.currentSession()
        let generation = currentGeneration
        let version = localUpdatedAt(for: domain)
        do {
            let stored: ExperimentalPreferenceSyncEnvelope<Payload>? = try localPreferenceEnvelope(for: domain)
            let local = try stored ?? PreferenceFieldMerge.recording(payload, previous: nil, at: localUpdatedAt(for: domain) ?? .distantPast)
            let cloud: RemoteSnapshot<Payload> = try await remoteSnapshot(for: domain)
            let remote = cloud.envelope
            try requireCurrent(owner: owner, generation: generation)
            guard localUpdatedAt(for: domain) == version else { scheduleReconciliation(for: [domain]); return }
            let merged = try remote.map { try PreferenceFieldMerge.merging(local, $0) } ?? local
            if merged.payload != payload, !apply(merged.payload) { throw PreferenceSyncRecordError.localWriteFailed }
            try storePreferenceEnvelope(merged, for: domain)
            setLocalUpdatedAt(merged.updatedAt, for: domain)
            clearPreferenceError(domain)
            if remote?.payload != merged.payload || remote?.fieldUpdatedAt != merged.fieldUpdatedAt
                || remote?.additionalFields != merged.additionalFields {
                await upload(merged, domain: domain, remote: cloud)
            }
        } catch { reportPreferenceError(error, domain: domain) }
    }

    private func reconcileMessages() async {
        do {
            let domain = ExperimentalPreferenceSyncDomain.galleryMessageRead
            let owner = stores.currentSession()
            let generation = currentGeneration
            let version = localUpdatedAt(for: domain)
            guard await stores.communityMessages.prepareSnapshot() else { throw PreferenceSyncRecordError.invalidStoredValue }
            try requireCurrent(owner: owner, generation: generation)
            let local = stores.communityMessages.syncSnapshot()
            let cloud: RemoteSnapshot<GalleryMessageReadSnapshot> = try await remoteSnapshot(for: domain)
            let remote = cloud.envelope
            try requireCurrent(owner: owner, generation: generation)
            guard localUpdatedAt(for: domain) == version else { scheduleReconciliation(for: [domain]); return }
            let merged = remote.map { local.mergingReadState($0.payload) } ?? local
            if merged != local, !(await stores.communityMessages.applySyncedSnapshot(merged)) { throw PreferenceSyncRecordError.localWriteFailed }
            try requireCurrent(owner: owner, generation: generation)
            let updatedAt = max(localUpdatedAt(for: domain) ?? .distantPast, remote?.updatedAt ?? .distantPast)
            setLocalUpdatedAt(updatedAt, for: domain)
            clearPreferenceError(domain)
            if remote?.payload != merged { await upload(payload: merged, domain: domain, updatedAt: updatedAt, remote: cloud) }
        } catch { reportPreferenceError(error, domain: .galleryMessageRead) }
    }

    private func localPreferenceEnvelope<Payload: Codable>(for domain: ExperimentalPreferenceSyncDomain) throws -> ExperimentalPreferenceSyncEnvelope<Payload>? {
        guard let stored = defaults.object(forKey: preferenceEnvelopeKey(for: domain)) else { return nil }
        guard let data = stored as? Data else { throw PreferenceSyncRecordError.invalidStoredValue }
        return try JSONDecoder().decode(ExperimentalPreferenceSyncEnvelope<Payload>.self, from: data)
    }

    private func storePreferenceEnvelope<Payload: Codable>(_ value: ExperimentalPreferenceSyncEnvelope<Payload>, for domain: ExperimentalPreferenceSyncDomain) throws {
        defaults.set(try JSONEncoder().encode(value), forKey: preferenceEnvelopeKey(for: domain))
    }

    private func preferenceEnvelopeKey(for domain: ExperimentalPreferenceSyncDomain) -> String {
        "experimental.preference-cloud-sync.local-envelope.\(localAccountIdentifier).\(domain.rawValue)"
    }

    private func reportPreferenceError(_ error: Error, domain: ExperimentalPreferenceSyncDomain) {
        guard !TaskCancellation.matches(error), !Task.isCancelled else { return }
        syncIssue = (error as? PreferenceSyncRecordError)?.errorDescription
            ?? (error as? ScoreSyncEncryptionError)?.errorDescription
            ?? (error as? ScoreCacheReadError)?.errorDescription
            ?? (error as? ScoreCacheWriteError)?.errorDescription
            ?? "偏好同步数据处理失败，原始记录已保留。请联系维护者恢复记录后重试。"
        syncIssueDomain = domain
        Self.logger.error("Preference merge failed domain=\(domain.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
    }

    private func clearPreferenceError(_ domain: ExperimentalPreferenceSyncDomain) {
        if syncIssueDomain == domain {
            syncIssue = legacyRecordIssues[domain]
            if syncIssue == nil { syncIssueDomain = nil }
        }
    }

    private func reconcileScore(localPayload: ScoreCacheSyncPayload, session: AppStorageSession) async {
        let domain = ExperimentalPreferenceSyncDomain.scoreCache
        let owner = stores.currentSession()
        let generation = currentGeneration
        let version = localUpdatedAt(for: domain)
        let observedRemote = scoreCloudData()
        do {
            let cloud: RemoteSnapshot<ScoreCacheSyncPayload> = try await remoteSnapshot(for: domain)
            let remote = cloud.envelope
            try requireCurrent(owner: owner, generation: generation)
            guard stores.scoreSession() == session, localUpdatedAt(for: domain) == version else {
                scheduleReconciliation(for: [domain])
                return
            }
            var localVersion = version
            if pendingScoreMutation?.updatedAt == version && version != nil
                && pendingScoreMutation?.remoteSHA256 == Self.scoreDigest(observedRemote)
                || version == nil && (remote == nil || !localPayload.rows.isEmpty && remote?.payload.rows.isEmpty != false) {
                let timestamp = nextLocalUpdatedAt(for: domain, remoteUpdatedAt: remote?.updatedAt)
                localVersion = timestamp
                setLocalUpdatedAt(timestamp, for: domain)
                if var pending = pendingScoreMutation { pending.updatedAt = timestamp; pendingScoreMutation = pending }
            }
            switch ExperimentalPreferenceSyncPolicy.decision(localUpdatedAt: localVersion, remoteUpdatedAt: remote?.updatedAt) {
            case .applyRemote:
                guard let remote,
                      try await stores.scoreCache.applySynced(remote.payload, for: session, replacing: localPayload) else { return }
                try requireCurrent(owner: owner, generation: generation)
                guard stores.scoreSession() == session, localUpdatedAt(for: domain) == localVersion else { return }
                setLocalUpdatedAt(remote.updatedAt, for: domain)
                pendingScoreMutation = nil
                clearPreferenceError(domain)
            case .uploadLocal:
                guard let localVersion else { return }
                await upload(payload: localPayload, domain: domain, updatedAt: localVersion, remote: cloud)
            case .noChange:
                clearPreferenceError(domain)
            }
        } catch { reportPreferenceError(error, domain: domain) }
    }

    private func upload<Payload: Codable & Sendable>(
        payload: Payload,
        domain: ExperimentalPreferenceSyncDomain,
        updatedAt: Date,
        remote: RemoteSnapshot<Payload>
    ) async {
        await upload(ExperimentalPreferenceSyncEnvelope(updatedAt: updatedAt, payload: payload,
            additionalFields: remote.envelope?.additionalFields ?? [:]), domain: domain, remote: remote)
    }

    private func upload<Payload: Codable & Sendable>(
        _ envelope: ExperimentalPreferenceSyncEnvelope<Payload>,
        domain: ExperimentalPreferenceSyncDomain,
        remote: RemoteSnapshot<Payload>
    ) async {
        guard isEnabled, !Task.isCancelled else { return }
        let owner = stores.currentSession()
        let generation = currentGeneration
        let version = localUpdatedAt(for: domain)
        let key = remote.key
        let data: Data
        do {
            guard cloudValues(for: Array(remote.records.keys)) == remote.records else { scheduleReconciliation(for: [domain]); return }
            data = try await encodeCloudEnvelope(envelope, domain: domain)
            try requireCurrent(owner: owner, generation: generation)
            guard localUpdatedAt(for: domain) == version else {
                scheduleReconciliation(for: [domain])
                return
            }
        } catch {
            reportPreferenceError(error, domain: domain)
            return
        }

        let values = cloudStore.dictionaryRepresentation
        guard cloudValues(for: Array(remote.records.keys), in: values) == remote.records else { scheduleReconciliation(for: [domain]); return }
        guard fitsCloudStore(data, replacing: key, values: values) else {
            let label = domain == .scoreCache ? "成绩缓存" : "偏好数据"
            syncIssue = "BIT101 的 iCloud 同步记录达到应用容量上限，\(label)保留在本机。可在日历设置中清理云端偏好记录，再开启偏好同步。"
            syncIssueDomain = domain
            Self.logger.error("iCloud payload exceeds available quota domain=\(domain.rawValue, privacy: .public) bytes=\(data.count)")
            return
        }

        cloudStore.set(data, forKey: key)
        guard cloudStore.data(forKey: key) == data else {
            syncIssue = "iCloud 写入暂时失败，数据保留在本机。请稍后重试。"
            syncIssueDomain = domain
            return
        }
        if synchronizeCloudStore() {
            if domain == .scoreCache, pendingScoreMutation?.updatedAt == version { pendingScoreMutation = nil }
            clearPreferenceError(domain)
        }
    }

    @discardableResult
    private func synchronizeCloudStore() -> Bool {
        let failure = "iCloud 同步暂时失败，数据保留在本机。请稍后重试。"
        guard cloudStore.synchronize() else {
            syncIssue = failure
            syncIssueDomain = nil
            return false
        }
        if syncIssue == failure { syncIssue = nil }
        return true
    }

    private func encodeCloudEnvelope<Payload: Codable & Sendable>(_ envelope: ExperimentalPreferenceSyncEnvelope<Payload>,
        domain: ExperimentalPreferenceSyncDomain) async throws -> Data {
        let seal = domain == .scoreCache ? try scoreEncryption.prepareSeal(account: accountIdentifier) : nil
        return try await PreferenceCloudPayloadCodec.encode(envelope, seal: seal)
    }

    func decodeScoreCloudEnvelope<Payload: Codable>(_ type: Payload.Type, from data: Data) throws -> Payload {
        let value = try ScoreCacheSyncPayloadCodec.decode(type, from: scoreEncryption.open(data, account: accountIdentifier))
        try scoreEncryption.acceptReceivedKey(from: data, account: accountIdentifier)
        return value
    }

    private func cloudValues(for keys: [String], in stored: [String: Any]? = nil) -> [String: CloudValue] {
        let stored = stored ?? cloudStore.dictionaryRepresentation
        return Dictionary(uniqueKeysWithValues: keys.map { key in
            let value: CloudValue
            if let data = stored[key] as? Data { value = .data(data) }
            else { value = stored[key] == nil ? .missing : .invalid }
            return (key, value)
        })
    }

    private func remoteSnapshot<Payload: Codable & Sendable>(
        for domain: ExperimentalPreferenceSyncDomain
    ) async throws -> RemoteSnapshot<Payload> {
        let key = cloudKey(for: domain)
        let keys = cloudKeys(for: domain)
        let legacyKey = keys[1]
        var records = cloudValues(for: keys)
        legacyRecordIssues.removeValue(forKey: domain)
        let selectedKey = records[key] == .missing ? legacyKey : key
        if records[selectedKey] == .missing { return RemoteSnapshot(envelope: nil, key: key, records: records) }
        guard case let .data(data)? = records[selectedKey] else { throw CocoaError(.coderReadCorrupt) }
        let owner = stores.currentSession()
        let generation = currentGeneration
        let open = domain == .scoreCache ? try scoreEncryption.prepareOpen(data, account: accountIdentifier) : { @Sendable in data }
        var envelope = try await PreferenceCloudPayloadCodec.decode(Payload.self, open: open)
        try requireCurrent(owner: owner, generation: generation)
        guard cloudValues(for: keys) == records else {
            scheduleReconciliation(for: [domain])
            throw CancellationError()
        }
        if domain == .scoreCache { try scoreEncryption.acceptReceivedKey(from: data, account: accountIdentifier) }
        if syncIssueDomain == domain, syncIssue == ScoreSyncEncryptionError.keyPending.errorDescription {
            syncIssue = nil
            syncIssueDomain = nil
        }
        var mergedLegacy = false
        if selectedKey != legacyKey, case let .data(legacy)? = records[legacyKey] {
            do {
                let openLegacy = domain == .scoreCache ? try scoreEncryption.prepareOpen(legacy, account: accountIdentifier) : { @Sendable in legacy }
                let older = try await PreferenceCloudPayloadCodec.decode(Payload.self, open: openLegacy)
                try requireCurrent(owner: owner, generation: generation)
                guard cloudValues(for: keys) == records else {
                    scheduleReconciliation(for: [domain])
                    throw CancellationError()
                }
                switch domain {
                case .appSettings, .scoreFilters:
                    envelope = try PreferenceFieldMerge.merging(envelope, older)
                case .scoreCache:
                    if older.updatedAt > envelope.updatedAt { envelope = older }
                case .galleryMessageRead:
                    guard let current = envelope.payload as? GalleryMessageReadSnapshot,
                          let previous = older.payload as? GalleryMessageReadSnapshot,
                          let payload = current.mergingReadState(previous) as? Payload else { throw PreferenceSyncRecordError.invalidStoredValue }
                    envelope = ExperimentalPreferenceSyncEnvelope(updatedAt: max(envelope.updatedAt, older.updatedAt), payload: payload)
                }
                mergedLegacy = true
            } catch {
                try requireCurrent(owner: owner, generation: generation)
                if TaskCancellation.matches(error) { throw error }
                legacyRecordIssues[domain] = "当前偏好同步继续运行。历史记录已保留，等待恢复后合并。"
            }
        } else if selectedKey != legacyKey, records[legacyKey] == .invalid {
            legacyRecordIssues[domain] = "当前偏好同步继续运行。历史记录已保留，等待恢复后合并。"
        }
        if selectedKey == legacyKey || mergedLegacy || (domain == .scoreCache && !ScoreCacheSyncEncryption.isEncrypted(data)) {
            let migrated = try await encodeCloudEnvelope(envelope, domain: domain)
            try requireCurrent(owner: owner, generation: generation)
            let values = cloudStore.dictionaryRepresentation
            guard cloudValues(for: keys, in: values) == records else {
                scheduleReconciliation(for: [domain])
                throw CancellationError()
            }
            if fitsCloudStore(migrated, replacing: key, values: values) {
                cloudStore.set(migrated, forKey: key)
                if cloudStore.data(forKey: key) == migrated {
                    records[key] = .data(migrated)
                    if synchronizeCloudStore(), selectedKey == legacyKey || mergedLegacy {
                        cloudStore.set(nil, forKey: legacyKey)
                        records[legacyKey] = .missing
                        synchronizeCloudStore()
                    }
                }
            }
        }
        try requireCurrent(owner: owner, generation: generation)
        guard cloudValues(for: keys) == records else {
            scheduleReconciliation(for: [domain])
            throw CancellationError()
        }
        if let issue = legacyRecordIssues[domain] { syncIssue = issue; syncIssueDomain = domain }
        return RemoteSnapshot(envelope: envelope, key: records[key] == .missing ? legacyKey : key, records: records)
    }

    private func scoreCloudData(owner: AppStorageSession? = nil) -> Data? {
        let account = owner?.accountDirectoryName ?? accountIdentifier
        let domain = ExperimentalPreferenceSyncDomain.scoreCache.rawValue
        let keys = ["preference-sync.v2.\(account).\(domain)", "preference-sync.v1.\(account).\(domain)"]
        let records = cloudValues(for: keys)
        var snapshot = Data()
        for key in keys {
            switch records[key] {
            case .missing: snapshot.append(0)
            case .invalid: snapshot.append(1)
            case .data(let data):
                snapshot.append(2)
                var length = UInt64(data.count).bigEndian
                withUnsafeBytes(of: &length) { snapshot.append(contentsOf: $0) }
                snapshot.append(data)
            case nil: return nil
            }
        }
        return snapshot
    }

    private nonisolated static func scoreDigest(_ data: Data?) -> Data? {
        data.map { Data(SHA256.hash(data: $0)) }
    }

    private func requireCurrent(owner: AppStorageSession, generation: Generation) throws {
        try Task.checkCancellation()
        guard isEnabled, stores.currentSession() == owner, currentGeneration == generation else { throw CancellationError() }
    }

    private func fitsCloudStore(_ newValue: Data, replacing key: String, values: [String: Any]? = nil) -> Bool {
        let values = values ?? cloudStore.dictionaryRepresentation
        let alreadyExists = values[key] != nil
        let existingBytes = values.reduce(into: 0) { total, entry in
            guard entry.key != key else { return }
            total += Self.propertyListValueSize(entry.value)
        }
        return ExperimentalPreferenceCloudQuotaPolicy.canStore(
            valueSize: newValue.count,
            existingValueBytes: existingBytes,
            existingKeyCount: values.count,
            replacingExistingKey: alreadyExists,
            keyUTF16Count: key.utf16.count
        )
    }

    private nonisolated static func propertyListValueSize(_ value: Any) -> Int {
        if let data = value as? Data { return data.count }
        if let string = value as? String { return string.utf8.count }
        if value is NSNumber || value is Date { return 16 }
        if let values = value as? [Any] {
            return values.reduce(0) { $0 + propertyListValueSize($1) }
        }
        if let values = value as? [String: Any] {
            return values.reduce(0) { $0 + $1.key.utf8.count + propertyListValueSize($1.value) }
        }
        return 0
    }

    private func nextLocalUpdatedAt(
        for domain: ExperimentalPreferenceSyncDomain,
        remoteUpdatedAt: Date? = nil, owner: AppStorageSession? = nil
    ) -> Date {
        var updatedAt = Date()
        if let localUpdatedAt = localUpdatedAt(for: domain, owner: owner),
           updatedAt <= localUpdatedAt {
            updatedAt = laterDate(after: localUpdatedAt)
        }
        if let remoteUpdatedAt, updatedAt <= remoteUpdatedAt {
            updatedAt = laterDate(after: remoteUpdatedAt)
        }
        return updatedAt
    }

    private func laterDate(after date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.nextUp)
    }

    private var enabledKey: String {
        "experimental.preference-cloud-sync.enabled.\(localAccountIdentifier)"
    }

    private var legacyEnabledKey: String {
        "experimental.preference-cloud-sync.enabled.\(accountIdentifier)"
    }

    private func localUpdatedAtKey(for domain: ExperimentalPreferenceSyncDomain, owner: AppStorageSession? = nil) -> String {
        "experimental.preference-cloud-sync.local-updated.\(owner?.accountStorageIdentifier ?? localAccountIdentifier).\(domain.rawValue)"
    }

    private func legacyLocalUpdatedAtKey(for domain: ExperimentalPreferenceSyncDomain, owner: AppStorageSession? = nil) -> String {
        "experimental.preference-cloud-sync.local-updated.\(owner?.accountDirectoryName ?? accountIdentifier).\(domain.rawValue)"
    }

    private func cloudKey(for domain: ExperimentalPreferenceSyncDomain) -> String {
        "preference-sync.v2.\(accountIdentifier).\(domain.rawValue)"
    }

    private func cloudKeys(for domain: ExperimentalPreferenceSyncDomain) -> [String] {
        [cloudKey(for: domain), "preference-sync.v1.\(accountIdentifier).\(domain.rawValue)"]
    }

    private var accountIdentifier: String {
        stores.currentSession().accountDirectoryName
    }

    private var localAccountIdentifier: String {
        stores.currentSession().accountStorageIdentifier
    }

    private func loadEnabledPreference() -> Bool {
        if let value = defaults.object(forKey: enabledKey) as? Bool { return value }
        guard let legacyValue = defaults.object(forKey: legacyEnabledKey) as? Bool else { return false }
        defaults.set(legacyValue, forKey: enabledKey)
        if legacyEnabledKey != enabledKey { defaults.removeObject(forKey: legacyEnabledKey) }
        return legacyValue
    }

    private func localUpdatedAt(for domain: ExperimentalPreferenceSyncDomain, owner: AppStorageSession? = nil) -> Date? {
        if let value = defaults.object(forKey: localUpdatedAtKey(for: domain, owner: owner)) as? Date { return value }
        let legacyKey = legacyLocalUpdatedAtKey(for: domain, owner: owner)
        guard let value = defaults.object(forKey: legacyKey) as? Date else { return nil }
        defaults.set(value, forKey: localUpdatedAtKey(for: domain, owner: owner))
        defaults.removeObject(forKey: legacyKey)
        return value
    }

    private func setLocalUpdatedAt(_ value: Date, for domain: ExperimentalPreferenceSyncDomain, owner: AppStorageSession? = nil) {
        defaults.set(value, forKey: localUpdatedAtKey(for: domain, owner: owner))
        if legacyLocalUpdatedAtKey(for: domain, owner: owner) != localUpdatedAtKey(for: domain, owner: owner) {
            defaults.removeObject(forKey: legacyLocalUpdatedAtKey(for: domain, owner: owner))
        }
    }
}
