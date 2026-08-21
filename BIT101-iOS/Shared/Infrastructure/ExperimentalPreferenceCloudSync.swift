import Combine
import Foundation

/// 小体积用户偏好的实验性 iCloud 同步域。
nonisolated enum ExperimentalPreferenceSyncDomain: String, CaseIterable {
    case appSettings = "app-settings"
    case scoreFilters = "score-filters"
    case scoreCache = "score-cache"
    case galleryMessageRead = "gallery-message-read"
}

/// 每个同步域独立携带修改时间，避免一个偏好的改动覆盖其它域。
nonisolated struct ExperimentalPreferenceSyncEnvelope<Payload: Codable>: Codable {
    let updatedAt: Date
    let payload: Payload
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

/// 使用 iCloud Key-Value Store 同步设置、成绩筛选偏好和消息已读状态。
///
/// 开关只保存在当前设备并按学号隔离，默认关闭；同步内容按域独立做时间戳冲突决策。
@MainActor
final class ExperimentalPreferenceCloudSync: ObservableObject {
    static let shared = ExperimentalPreferenceCloudSync()

    @Published private(set) var isEnabled = false

    private let defaults: UserDefaults
    private let cloudStore: NSUbiquitousKeyValueStore
    private var cloudObserver: NSObjectProtocol?
    private var accountObserver: NSObjectProtocol?

    private init(
        defaults: UserDefaults = .standard,
        cloudStore: NSUbiquitousKeyValueStore = .default
    ) {
        self.defaults = defaults
        self.cloudStore = cloudStore
        isEnabled = defaults.bool(forKey: enabledKey)

        cloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloudStore,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.handleExternalChange(notification)
            }
        }
        accountObserver = NotificationCenter.default.addObserver(
            forName: .loginStorageDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.reloadForCurrentAccount()
            }
        }

        if isEnabled {
            cloudStore.synchronize()
            scheduleReconciliation(for: ExperimentalPreferenceSyncDomain.allCases)
        }
    }

    deinit {
        if let cloudObserver { NotificationCenter.default.removeObserver(cloudObserver) }
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        defaults.set(enabled, forKey: enabledKey)
        isEnabled = enabled
        guard enabled else { return }

        cloudStore.synchronize()
        scheduleReconciliation(for: ExperimentalPreferenceSyncDomain.allCases)
    }

    /// 本地业务数据发生变化时记录时间；只有实验开关打开才立即上传。
    func localValueDidChange(in domain: ExperimentalPreferenceSyncDomain) {
        let now = Date()
        defaults.set(now, forKey: localUpdatedAtKey(for: domain))
        guard isEnabled else { return }
        upload(domain: domain, updatedAt: now)
    }

    /// 启动和回到前台时补做一次拉取，兼容系统没有及时投递外部变更通知的情况。
    func refreshFromCloudIfNeeded() {
        guard isEnabled else { return }
        cloudStore.synchronize()
        scheduleReconciliation(for: ExperimentalPreferenceSyncDomain.allCases)
    }

    private func reloadForCurrentAccount() {
        isEnabled = defaults.bool(forKey: enabledKey)
        refreshFromCloudIfNeeded()
    }

    private func handleExternalChange(_ notification: Notification) {
        guard isEnabled else { return }
        let changedKeys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
        let domains = ExperimentalPreferenceSyncDomain.allCases.filter {
            changedKeys == nil || changedKeys?.contains(cloudKey(for: $0)) == true
        }
        scheduleReconciliation(for: domains)
    }

    /// KVS 外部变更通知由系统内部串行队列派发；必须等通知栈退出后再读写 KVS，
    /// 否则在同步应用偏好并触发另一域写回时会造成 libdispatch 递归加锁崩溃。
    private func scheduleReconciliation(for domains: [ExperimentalPreferenceSyncDomain]) {
        guard !domains.isEmpty else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.isEnabled else { return }
            domains.forEach(self.reconcile(domain:))
        }
    }

    private func reconcile(domain: ExperimentalPreferenceSyncDomain) {
        switch domain {
        case .appSettings:
            reconcile(
                domain: domain,
                localPayload: AppSettingsSyncPayload(snapshot: AppSettingsStore.shared.snapshot),
                applyRemote: { AppSettingsStore.shared.applySyncedPreferences($0) }
            )
        case .scoreFilters:
            reconcile(
                domain: domain,
                localPayload: ScoreFilterPreferenceStore.load() ?? ScoreFilterPreferenceSnapshot(),
                applyRemote: { ScoreFilterPreferenceStore.applySynced($0) }
            )
        case .scoreCache:
            let localPayload = ScoreCacheStore.syncPayload()
            preserveLegacyLocalScoreCacheIfNeeded(localPayload)
            reconcile(
                domain: domain,
                localPayload: localPayload,
                applyRemote: { ScoreCacheStore.applySynced($0) }
            )
        case .galleryMessageRead:
            reconcile(
                domain: domain,
                localPayload: GalleryMessageReadStore.shared.syncSnapshot(),
                applyRemote: { GalleryMessageReadStore.shared.applySyncedSnapshot($0) }
            )
        }
    }

    private func reconcile<Payload: Codable>(
        domain: ExperimentalPreferenceSyncDomain,
        localPayload: Payload,
        applyRemote: (Payload) -> Void
    ) {
        let remote: ExperimentalPreferenceSyncEnvelope<Payload>? = remoteEnvelope(for: domain)
        let localUpdatedAt = defaults.object(forKey: localUpdatedAtKey(for: domain)) as? Date

        // 云端还没有该域时，把当前设备现有值作为初始值上传。
        if remote == nil, localUpdatedAt == nil {
            let now = Date()
            defaults.set(now, forKey: localUpdatedAtKey(for: domain))
            upload(payload: localPayload, domain: domain, updatedAt: now)
            return
        }

        switch ExperimentalPreferenceSyncPolicy.decision(
            localUpdatedAt: localUpdatedAt,
            remoteUpdatedAt: remote?.updatedAt
        ) {
        case .applyRemote:
            guard let remote else { return }
            applyRemote(remote.payload)
            defaults.set(remote.updatedAt, forKey: localUpdatedAtKey(for: domain))
        case .uploadLocal:
            guard let localUpdatedAt else { return }
            upload(payload: localPayload, domain: domain, updatedAt: localUpdatedAt)
        case .noChange:
            break
        }
    }

    private func upload(domain: ExperimentalPreferenceSyncDomain, updatedAt: Date) {
        switch domain {
        case .appSettings:
            upload(
                payload: AppSettingsSyncPayload(snapshot: AppSettingsStore.shared.snapshot),
                domain: domain,
                updatedAt: updatedAt
            )
        case .scoreFilters:
            upload(
                payload: ScoreFilterPreferenceStore.load() ?? ScoreFilterPreferenceSnapshot(),
                domain: domain,
                updatedAt: updatedAt
            )
        case .scoreCache:
            upload(
                payload: ScoreCacheStore.syncPayload(),
                domain: domain,
                updatedAt: updatedAt
            )
        case .galleryMessageRead:
            upload(
                payload: GalleryMessageReadStore.shared.syncSnapshot(),
                domain: domain,
                updatedAt: updatedAt
            )
        }
    }

    /// 升级前已经存在的成绩没有实验同步时间戳；云端为空时优先保留并上传本机成绩。
    private func preserveLegacyLocalScoreCacheIfNeeded(_ localPayload: ScoreCacheSyncPayload) {
        guard !localPayload.rows.isEmpty else { return }
        let domain = ExperimentalPreferenceSyncDomain.scoreCache
        guard defaults.object(forKey: localUpdatedAtKey(for: domain)) == nil else { return }
        let remote: ExperimentalPreferenceSyncEnvelope<ScoreCacheSyncPayload>? = remoteEnvelope(for: domain)
        guard remote?.payload.rows.isEmpty != false else { return }
        defaults.set(Date(), forKey: localUpdatedAtKey(for: domain))
    }

    private func upload<Payload: Codable>(
        payload: Payload,
        domain: ExperimentalPreferenceSyncDomain,
        updatedAt: Date
    ) {
        let envelope = ExperimentalPreferenceSyncEnvelope(updatedAt: updatedAt, payload: payload)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        cloudStore.set(data, forKey: cloudKey(for: domain))
    }

    private func remoteEnvelope<Payload: Codable>(
        for domain: ExperimentalPreferenceSyncDomain
    ) -> ExperimentalPreferenceSyncEnvelope<Payload>? {
        guard let data = cloudStore.data(forKey: cloudKey(for: domain)) else { return nil }
        return try? JSONDecoder().decode(ExperimentalPreferenceSyncEnvelope<Payload>.self, from: data)
    }

    private var enabledKey: String {
        "experimental.preference-cloud-sync.enabled.\(accountIdentifier)"
    }

    private func localUpdatedAtKey(for domain: ExperimentalPreferenceSyncDomain) -> String {
        "experimental.preference-cloud-sync.local-updated.\(accountIdentifier).\(domain.rawValue)"
    }

    private func cloudKey(for domain: ExperimentalPreferenceSyncDomain) -> String {
        "preference-sync.v1.\(accountIdentifier).\(domain.rawValue)"
    }

    private var accountIdentifier: String {
        ScheduleCacheStore.currentAccountIdentifier()
    }
}
