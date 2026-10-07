import ScoreDomain
import CommunityPersistence
import CommunityCore
import StorageCore
import ScoreInfrastructure
import Combine
import Compression
import Foundation
import OSLog

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
/// Plain JSON remains readable for snapshots written by earlier app versions.
nonisolated enum ScoreCacheSyncPayloadCodec {
    private static let magic = Data([0x42, 0x49, 0x54, 0x31, 0x30, 0x31, 0x4c, 0x5a, 0x46, 0x53, 0x45, 0x01])
    static let maximumDecodedSize = 32 * 1_024 * 1_024

    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let json = try JSONEncoder().encode(value)
        guard !json.isEmpty, json.count <= maximumDecodedSize else { return json }

        var compressed = Data(count: json.count + 64)
        let compressedCount = json.withUnsafeBytes { source in
            compressed.withUnsafeMutableBytes { destination in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_encode_buffer(
                    destinationBase,
                    destination.count,
                    sourceBase,
                    source.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }
        guard compressedCount > 0, compressedCount < json.count else { return json }

        compressed.count = compressedCount
        var result = magic
        var originalSize = UInt64(json.count).bigEndian
        withUnsafeBytes(of: &originalSize) { result.append(contentsOf: $0) }
        result.append(compressed)
        return result
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        guard data.starts(with: magic) else {
            return try JSONDecoder().decode(type, from: data)
        }

        let sizeStart = magic.count
        let payloadStart = sizeStart + MemoryLayout<UInt64>.size
        guard data.count > payloadStart else { throw CocoaError(.coderReadCorrupt) }

        let originalSize = data[sizeStart..<payloadStart].reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
        guard originalSize > 0, originalSize <= UInt64(maximumDecodedSize) else {
            throw CocoaError(.coderReadCorrupt)
        }

        var decoded = Data(count: Int(originalSize))
        let compressed = data.dropFirst(payloadStart)
        let decodedCount = compressed.withUnsafeBytes { source in
            decoded.withUnsafeMutableBytes { destination in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_decode_buffer(
                    destinationBase,
                    destination.count,
                    sourceBase,
                    source.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }
        guard decodedCount == Int(originalSize) else { throw CocoaError(.coderReadCorrupt) }
        return try JSONDecoder().decode(type, from: decoded)
    }
}

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
    static let shared = ExperimentalPreferenceCloudSync(settings: .shared, stores: .shared)

    private static let logger = Logger(subsystem: "BIT101", category: "PreferenceCloudSync")

    @Published private(set) var isEnabled = false
    @Published private(set) var syncIssue: String?
    private var syncIssueDomain: ExperimentalPreferenceSyncDomain?

    private let defaults: UserDefaults
    let settings: AppSettingsStore
    let stores: AppAccountStores
    private let cloudStore: any PreferenceCloudStoring
    private var cloudObserverTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var pendingReconciliationDomains = Set<ExperimentalPreferenceSyncDomain>()
    private var saveSubscriptions = Set<AnyCancellable>()

    init(
        settings: AppSettingsStore,
        stores: AppAccountStores,
        defaults: UserDefaults = AppFileDirectories.defaults,
        cloudStore: any PreferenceCloudStoring = NSUbiquitousKeyValueStore.default,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.cloudStore = cloudStore
        self.settings = settings
        self.stores = stores
        isEnabled = loadEnabledPreference()
        capturePreferenceBaselines()
        settings.localSaves.sink { [weak self] in self?.localValueDidChange(in: .appSettings, for: $0) }.store(in: &saveSubscriptions)
        stores.scoreCache.localSaves.sink { [weak self] in self?.localValueDidChange(in: .scoreCache, for: $0) }.store(in: &saveSubscriptions)
        stores.scoreFilterPreferences.localSaves.sink { [weak self] in self?.localValueDidChange(in: .scoreFilters, for: $0) }.store(in: &saveSubscriptions)
        stores.communityMessages.localSaves.sink { [weak self] in self?.localValueDidChange(in: .galleryMessageRead, for: $0) }.store(in: &saveSubscriptions)

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
            reconciliationTask?.cancel()
            reconciliationTask = nil
            pendingReconciliationDomains.removeAll()
            syncIssue = nil
            syncIssueDomain = nil
            return
        }

        cloudStore.synchronize()
        scheduleReconciliation(for: ExperimentalPreferenceSyncDomain.allCases)
    }

    /// 本地业务数据发生变化时记录时间；只有实验开关打开才立即上传。
    func localValueDidChange(
        in domain: ExperimentalPreferenceSyncDomain,
        for session: AppStorageSession? = nil
    ) {
        let owner = domain == .scoreCache ? stores.scoreSession() : stores.currentSession()
        guard session == nil || session == owner else { return }
        switch domain {
        case .appSettings:
            recordPreferences(AppSettingsSyncPayload(snapshot: settings.snapshot), domain: domain,
                apply: settings.applySyncedPreferences)
        case .scoreFilters:
            recordPreferences(stores.scoreFilterPreferences.load() ?? ScoreFilterPreferenceSnapshot(), domain: domain,
                apply: stores.scoreFilterPreferences.applySynced)
        case .scoreCache:
            let updatedAt = nextLocalUpdatedAt(for: domain, remoteUpdatedAt: remoteUpdatedAt(for: domain))
            setLocalUpdatedAt(updatedAt, for: domain)
            if isEnabled { Task { await uploadScoreCache(updatedAt: updatedAt, session: owner) } }
        case .galleryMessageRead:
            setLocalUpdatedAt(nextLocalUpdatedAt(for: domain), for: domain)
            if isEnabled { reconcileMessages() }
        }
    }

    /// 启动和回到前台时补做一次拉取，兼容系统没有及时投递外部变更通知的情况。
    @discardableResult
    func refreshFromCloudIfNeeded() -> Task<Void, Never>? {
        guard isEnabled else { return nil }
        cloudStore.synchronize()
        scheduleReconciliation(for: ExperimentalPreferenceSyncDomain.allCases)
        return reconciliationTask
    }

#if DEBUG || ICLOUD_CROSS_DEVICE_SMOKE
    func synchronizedVersion(for domain: ExperimentalPreferenceSyncDomain) -> Date? {
        localUpdatedAt(for: domain)
    }
#endif

    func reloadForCurrentAccount() {
        reconciliationTask?.cancel()
        reconciliationTask = nil
        pendingReconciliationDomains.removeAll()
        syncIssue = nil
        syncIssueDomain = nil
        isEnabled = loadEnabledPreference()
        capturePreferenceBaselines()
        guard isEnabled else { return }
        cloudStore.synchronize()
        scheduleReconciliation(for: ExperimentalPreferenceSyncDomain.allCases)
    }

    private func handleExternalChange(changedKeys: [String]?, changeReason: Int?) {
        guard isEnabled else { return }
        if changeReason == NSUbiquitousKeyValueStoreQuotaViolationChange {
            syncIssue = "iCloud 偏好同步空间已满。本机设置和成绩缓存继续保留；释放 iCloud 空间后重试。"
            syncIssueDomain = changedKeys?.compactMap { key in
                ExperimentalPreferenceSyncDomain.allCases.first { cloudKey(for: $0) == key }
            }.first
            Self.logger.error("iCloud KVS quota violation")
            return
        }
        let domains = ExperimentalPreferenceSyncDomain.allCases.filter {
            changedKeys == nil || changedKeys?.contains(cloudKey(for: $0)) == true
        }
        scheduleReconciliation(for: domains)
    }

    /// KVS 外部变更通知由系统内部串行队列派发；必须等通知栈退出后再读写 KVS，
    /// 否则在同步应用偏好并触发另一域写回时会造成 libdispatch 递归加锁崩溃。
    private func scheduleReconciliation(for domains: [ExperimentalPreferenceSyncDomain]) {
        guard !domains.isEmpty else { return }
        pendingReconciliationDomains.formUnion(domains)
        guard reconciliationTask == nil else { return }

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

            if !Task.isCancelled {
                self.reconciliationTask = nil
            }
        }
    }

    private func reconcile(domain: ExperimentalPreferenceSyncDomain) async {
        switch domain {
        case .appSettings:
            reconcilePreferences(AppSettingsSyncPayload(snapshot: settings.snapshot), domain: domain,
                apply: settings.applySyncedPreferences)
        case .scoreFilters:
            reconcilePreferences(stores.scoreFilterPreferences.load() ?? ScoreFilterPreferenceSnapshot(), domain: domain,
                apply: stores.scoreFilterPreferences.applySynced)
        case .scoreCache:
            let session = stores.scoreSession()
            guard let localPayload = await stores.scoreCache.syncPayload(for: session),
                  !Task.isCancelled,
                  stores.scoreSession() == session
            else { return }
            preserveLegacyLocalScoreCacheIfNeeded(localPayload)
            await reconcile(
                domain: domain,
                localPayload: localPayload,
                scoreSession: session,
                applyRemote: { payload in
                    await stores.scoreCache.applySynced(payload, for: session)
                }
            )
        case .galleryMessageRead:
            reconcileMessages()
        }
    }

    private func capturePreferenceBaselines() {
        captureBaseline(AppSettingsSyncPayload(snapshot: settings.snapshot), domain: .appSettings)
        captureBaseline(stores.scoreFilterPreferences.load() ?? ScoreFilterPreferenceSnapshot(), domain: .scoreFilters)
    }

    private func captureBaseline<Payload: Codable>(_ payload: Payload, domain: ExperimentalPreferenceSyncDomain) {
        let previous: ExperimentalPreferenceSyncEnvelope<Payload>? = localPreferenceEnvelope(for: domain)
        guard previous == nil else { return }
        do {
            let baseline = try PreferenceFieldMerge.recording(payload, previous: nil, at: localUpdatedAt(for: domain) ?? .distantPast)
            try storePreferenceEnvelope(baseline, for: domain)
        } catch { reportPreferenceError(error, domain: domain) }
    }

    private func recordPreferences<Payload: Codable & Equatable>(
        _ payload: Payload, domain: ExperimentalPreferenceSyncDomain, apply: (Payload) -> Void
    ) {
        do {
            let previous: ExperimentalPreferenceSyncEnvelope<Payload>? = localPreferenceEnvelope(for: domain)
            let value = try PreferenceFieldMerge.recording(payload, previous: previous, at: nextLocalUpdatedAt(for: domain))
            try storePreferenceEnvelope(value, for: domain)
            setLocalUpdatedAt(value.updatedAt, for: domain)
            guard isEnabled else { return }
            reconcilePreferences(payload, domain: domain, apply: apply)
        } catch { reportPreferenceError(error, domain: domain) }
    }

    private func reconcilePreferences<Payload: Codable & Equatable>(
        _ payload: Payload, domain: ExperimentalPreferenceSyncDomain, apply: (Payload) -> Void
    ) {
        do {
            let stored: ExperimentalPreferenceSyncEnvelope<Payload>? = localPreferenceEnvelope(for: domain)
            let local = try stored ?? PreferenceFieldMerge.recording(payload, previous: nil, at: localUpdatedAt(for: domain) ?? .distantPast)
            let remote: ExperimentalPreferenceSyncEnvelope<Payload>? = try remoteEnvelope(for: domain)
            let merged = try remote.map { try PreferenceFieldMerge.merging(local, $0) } ?? local
            if merged.payload != payload { apply(merged.payload) }
            try storePreferenceEnvelope(merged, for: domain)
            setLocalUpdatedAt(merged.updatedAt, for: domain)
            if remote?.payload != merged.payload || remote?.fieldUpdatedAt != merged.fieldUpdatedAt {
                upload(merged, domain: domain)
            }
        } catch { reportPreferenceError(error, domain: domain) }
    }

    private func reconcileMessages() {
        do {
            let domain = ExperimentalPreferenceSyncDomain.galleryMessageRead
            let local = stores.communityMessages.syncSnapshot()
            let remote: ExperimentalPreferenceSyncEnvelope<GalleryMessageReadSnapshot>? = try remoteEnvelope(for: domain)
            let merged = remote.map { local.mergingReadState($0.payload) } ?? local
            if merged != local { stores.communityMessages.applySyncedSnapshot(merged) }
            let updatedAt = max(localUpdatedAt(for: domain) ?? .distantPast, remote?.updatedAt ?? .distantPast)
            setLocalUpdatedAt(updatedAt, for: domain)
            if remote?.payload != merged { upload(payload: merged, domain: domain, updatedAt: updatedAt) }
        } catch { reportPreferenceError(error, domain: .galleryMessageRead) }
    }

    private func localPreferenceEnvelope<Payload: Codable>(for domain: ExperimentalPreferenceSyncDomain) -> ExperimentalPreferenceSyncEnvelope<Payload>? {
        guard let data = defaults.data(forKey: preferenceEnvelopeKey(for: domain)) else { return nil }
        return try? JSONDecoder().decode(ExperimentalPreferenceSyncEnvelope<Payload>.self, from: data)
    }

    private func storePreferenceEnvelope<Payload: Codable>(_ value: ExperimentalPreferenceSyncEnvelope<Payload>, for domain: ExperimentalPreferenceSyncDomain) throws {
        defaults.set(try JSONEncoder().encode(value), forKey: preferenceEnvelopeKey(for: domain))
    }

    private func preferenceEnvelopeKey(for domain: ExperimentalPreferenceSyncDomain) -> String {
        "experimental.preference-cloud-sync.local-envelope.\(localAccountIdentifier).\(domain.rawValue)"
    }

    private func reportPreferenceError(_ error: Error, domain: ExperimentalPreferenceSyncDomain) {
        syncIssue = "偏好同步数据处理失败，请稍后重试。"
        syncIssueDomain = domain
        Self.logger.error("Preference merge failed domain=\(domain.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
    }

    private func reconcile<Payload: Codable>(
        domain: ExperimentalPreferenceSyncDomain,
        localPayload: Payload,
        scoreSession: AppStorageSession? = nil,
        applyRemote: (Payload) async -> Bool
    ) async {
        if let scoreSession, stores.scoreSession() != scoreSession { return }
        do {
            let remote: ExperimentalPreferenceSyncEnvelope<Payload>? = try remoteEnvelope(for: domain)
            let localUpdatedAt = localUpdatedAt(for: domain)

            // 云端还没有该域时，把当前设备现有值作为初始值上传。
            if remote == nil, localUpdatedAt == nil {
                let updatedAt = nextLocalUpdatedAt(for: domain)
                setLocalUpdatedAt(updatedAt, for: domain)
                upload(
                    payload: localPayload,
                    domain: domain,
                    updatedAt: updatedAt
                )
                return
            }

            switch ExperimentalPreferenceSyncPolicy.decision(
                localUpdatedAt: localUpdatedAt,
                remoteUpdatedAt: remote?.updatedAt
            ) {
            case .applyRemote:
                guard let remote else { return }
                guard await applyRemote(remote.payload) else { return }
                guard !Task.isCancelled,
                      scoreSession == nil || stores.scoreSession() == scoreSession
                else { return }
                setLocalUpdatedAt(remote.updatedAt, for: domain)
            case .uploadLocal:
                guard let localUpdatedAt else { return }
                upload(
                    payload: localPayload,
                    domain: domain,
                    updatedAt: localUpdatedAt
                )
            case .noChange:
                break
            }
        } catch { reportPreferenceError(error, domain: domain) }
    }

    private func uploadScoreCache(updatedAt: Date, session: AppStorageSession) async {
        guard stores.scoreSession() == session,
              let payload = await stores.scoreCache.syncPayload(for: session),
              !Task.isCancelled,
              stores.scoreSession() == session
        else { return }
        upload(payload: payload, domain: .scoreCache, updatedAt: updatedAt)
    }

    /// 升级前已有的成绩缓存没有实验同步时间戳；云端为空时优先保留并上传本机成绩。
    private func preserveLegacyLocalScoreCacheIfNeeded(_ localPayload: ScoreCacheSyncPayload) {
        guard !localPayload.rows.isEmpty else { return }
        let domain = ExperimentalPreferenceSyncDomain.scoreCache
        guard localUpdatedAt(for: domain) == nil else { return }
        do {
            let remote: ExperimentalPreferenceSyncEnvelope<ScoreCacheSyncPayload>? = try remoteEnvelope(for: domain)
            guard remote?.payload.rows.isEmpty != false else { return }
            let updatedAt = nextLocalUpdatedAt(for: domain, remoteUpdatedAt: remote?.updatedAt)
            setLocalUpdatedAt(updatedAt, for: domain)
        } catch { reportPreferenceError(error, domain: domain) }
    }

    private func upload<Payload: Codable>(
        payload: Payload,
        domain: ExperimentalPreferenceSyncDomain,
        updatedAt: Date
    ) {
        upload(ExperimentalPreferenceSyncEnvelope(updatedAt: updatedAt, payload: payload), domain: domain)
    }

    private func upload<Payload: Codable>(
        _ envelope: ExperimentalPreferenceSyncEnvelope<Payload>,
        domain: ExperimentalPreferenceSyncDomain
    ) {
        let data: Data
        do {
            let remote: ExperimentalPreferenceSyncEnvelope<Payload>? = try remoteEnvelope(for: domain)
            var preserved = envelope
            preserved.additionalFields.merge(remote?.additionalFields ?? [:]) { local, _ in local }
            data = try domain == .scoreCache ? ScoreCacheSyncPayloadCodec.encode(preserved) : JSONEncoder().encode(preserved)
        } catch {
            reportPreferenceError(error, domain: domain)
            Self.logger.error("iCloud payload encoding failed domain=\(domain.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return
        }

        let key = cloudKey(for: domain)
        guard fitsCloudStore(data, replacing: key) else {
            let label = domain == .scoreCache ? "成绩缓存" : "偏好数据"
            syncIssue = "iCloud 空间不足，\(label)保留在本机。释放 iCloud 空间后重试。"
            syncIssueDomain = domain
            Self.logger.error("iCloud payload exceeds available quota domain=\(domain.rawValue, privacy: .public) bytes=\(data.count)")
            return
        }

        if syncIssueDomain == domain {
            syncIssue = nil
            syncIssueDomain = nil
        }
        cloudStore.set(data, forKey: key)
        cloudStore.synchronize()
    }

    private func remoteEnvelope<Payload: Codable>(
        for domain: ExperimentalPreferenceSyncDomain
    ) throws -> ExperimentalPreferenceSyncEnvelope<Payload>? {
        let key = cloudKey(for: domain)
        let legacyKey = "preference-sync.v1.\(accountIdentifier).\(domain.rawValue)"
        let selectedKey = cloudStore.dictionaryRepresentation[key] == nil ? legacyKey : key
        guard cloudStore.dictionaryRepresentation[selectedKey] != nil else { return nil }
        guard let data = cloudStore.data(forKey: selectedKey) else { throw CocoaError(.coderReadCorrupt) }
        return try ScoreCacheSyncPayloadCodec.decode(ExperimentalPreferenceSyncEnvelope<Payload>.self, from: data)
    }

    private func remoteUpdatedAt(for domain: ExperimentalPreferenceSyncDomain) -> Date? {
        struct TimestampEnvelope: Decodable {
            let updatedAt: Date
        }

        guard let data = cloudStore.data(forKey: cloudKey(for: domain)) else { return nil }
        return try? ScoreCacheSyncPayloadCodec.decode(TimestampEnvelope.self, from: data).updatedAt
    }

    private func fitsCloudStore(_ newValue: Data, replacing key: String) -> Bool {
        let values = cloudStore.dictionaryRepresentation
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
        remoteUpdatedAt: Date? = nil
    ) -> Date {
        var updatedAt = Date()
        if let localUpdatedAt = localUpdatedAt(for: domain),
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

    private func localUpdatedAtKey(for domain: ExperimentalPreferenceSyncDomain) -> String {
        "experimental.preference-cloud-sync.local-updated.\(localAccountIdentifier).\(domain.rawValue)"
    }

    private func legacyLocalUpdatedAtKey(for domain: ExperimentalPreferenceSyncDomain) -> String {
        "experimental.preference-cloud-sync.local-updated.\(accountIdentifier).\(domain.rawValue)"
    }

    private func cloudKey(for domain: ExperimentalPreferenceSyncDomain) -> String {
        "preference-sync.v2.\(accountIdentifier).\(domain.rawValue)"
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

    private func localUpdatedAt(for domain: ExperimentalPreferenceSyncDomain) -> Date? {
        if let value = defaults.object(forKey: localUpdatedAtKey(for: domain)) as? Date { return value }
        let legacyKey = legacyLocalUpdatedAtKey(for: domain)
        guard let value = defaults.object(forKey: legacyKey) as? Date else { return nil }
        defaults.set(value, forKey: localUpdatedAtKey(for: domain))
        defaults.removeObject(forKey: legacyKey)
        return value
    }

    private func setLocalUpdatedAt(_ value: Date, for domain: ExperimentalPreferenceSyncDomain) {
        defaults.set(value, forKey: localUpdatedAtKey(for: domain))
        if legacyLocalUpdatedAtKey(for: domain) != localUpdatedAtKey(for: domain) {
            defaults.removeObject(forKey: legacyLocalUpdatedAtKey(for: domain))
        }
    }
}
