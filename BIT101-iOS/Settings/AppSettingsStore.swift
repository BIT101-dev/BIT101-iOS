//
//  AppSettingsStore.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import StorageCore
import Combine
import Foundation

extension Notification.Name {
    /// 登录存储变化通知。
    ///
    /// 多账号隔离设置、小组件和日程缓存都会用这条通知感知账号切换。
    static let loginStorageDidChange = Notification.Name("BIT101.LoginStorageDidChange")
}

/// 持久化到 `UserDefaults` 的设置快照。
///
/// 设置快照统一承接 UI 层的修改、读写、账号隔离和默认值。
struct AppSettingsSnapshot: Codable, Equatable {
    /// 普通帖子页面按开关隐藏机器人帖子，机器人分栏保持显示。
    var galleryHideBotPosterInSearch = true
    /// 话廊普通内容中需要隐藏的用户 UID。
    var galleryHiddenUserIDs: [Int] = []
    /// 是否在话廊中过滤匿名内容。
    var galleryHideAnonymousContent = false
    /// 是否使用网页话廊。
    var galleryUseWebView = false
    /// 是否已经看过“导入分享课表”的使用提示。
    var hasSeenSharedScheduleImportGuide = false
    /// 当前账号第一次进入 app 的时间。
    var firstOpenDate: Date?
    /// 当前账号是否已经看过“鸣谢 LINUX DO”提示。
    var hasShownLinuxDoThanksNotice = false

    enum CodingKeys: String, CodingKey {
        case galleryHideBotPosterInSearch
        case galleryHiddenUserIDs
        case galleryHideAnonymousContent = "galleryStrictUserFilter"
        case galleryUseWebView
        case hasSeenSharedScheduleImportGuide
        case firstOpenDate
        case hasShownLinuxDoThanksNotice
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        galleryHideBotPosterInSearch = try container.decodeIfPresent(Bool.self, forKey: .galleryHideBotPosterInSearch) ?? true
        galleryHiddenUserIDs = try container.decodeIfPresent([Int].self, forKey: .galleryHiddenUserIDs) ?? []
        galleryHideAnonymousContent = try container.decodeIfPresent(Bool.self, forKey: .galleryHideAnonymousContent) ?? false
        galleryUseWebView = try container.decodeIfPresent(Bool.self, forKey: .galleryUseWebView) ?? false
        hasSeenSharedScheduleImportGuide = try container.decodeIfPresent(Bool.self, forKey: .hasSeenSharedScheduleImportGuide) ?? false
        firstOpenDate = try container.decodeIfPresent(Date.self, forKey: .firstOpenDate)
        hasShownLinuxDoThanksNotice = try container.decodeIfPresent(Bool.self, forKey: .hasShownLinuxDoThanksNotice) ?? false
    }
}

/// 同步载荷包含用户偏好字段；首次打开时间和一次性提示状态保留在本机。
struct AppSettingsSyncPayload: Codable, Equatable {
    var galleryHideBotPosterInSearch: Bool
    var galleryHiddenUserIDs: [Int]
    var galleryHideAnonymousContent: Bool
    var galleryUseWebView: Bool

    enum CodingKeys: String, CodingKey {
        case galleryHideBotPosterInSearch
        case galleryHiddenUserIDs
        case galleryHideAnonymousContent = "galleryStrictUserFilter"
        case galleryUseWebView
    }

    init(snapshot: AppSettingsSnapshot) {
        galleryHideBotPosterInSearch = snapshot.galleryHideBotPosterInSearch
        galleryHiddenUserIDs = snapshot.galleryHiddenUserIDs
        galleryHideAnonymousContent = snapshot.galleryHideAnonymousContent
        galleryUseWebView = snapshot.galleryUseWebView
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        galleryHideBotPosterInSearch = try container.decodeIfPresent(Bool.self, forKey: .galleryHideBotPosterInSearch) ?? true
        galleryHiddenUserIDs = try container.decodeIfPresent([Int].self, forKey: .galleryHiddenUserIDs) ?? []
        galleryHideAnonymousContent = try container.decodeIfPresent(Bool.self, forKey: .galleryHideAnonymousContent) ?? false
        galleryUseWebView = try container.decodeIfPresent(Bool.self, forKey: .galleryUseWebView) ?? false
    }
}

@MainActor
/// 应用设置仓库。
///
/// 当前账号的账号偏好和话廊筛选偏好都会统一写入这里，再由具体页面按需读取。
final class AppSettingsStore: ObservableObject {
    var didSave: (() -> Void)?
    static let shared = AppSettingsStore()
    /// 各账号设置快照在 `UserDefaults` 中使用的 key 前缀。
    nonisolated static let storageKeyPrefix = "app.settings.snapshot"
    /// 单一共享设置快照的迁移来源 key。
    nonisolated static let legacyStorageKey = "app.settings.snapshot"
    /// 尚未登录时使用的设置分区。
    nonisolated static let defaultAccountIdentifier = "__default__"
    /// 当前安装版本的更新内容版本号；每个版本展示一次。
    nonisolated static let currentStartupNoticeVersion = "1.8.3"
    /// 更新内容公告已读状态保存在全局 key，账号切换后继续复用该状态。
    nonisolated static let startupNoticeSeenKey = "app.startup.notice.seen.version"
    /// 历史成绩疑似补考学期筛选按账号保存。
    nonisolated static let courseHistoryHidesMakeupOutliersKey = "app.settings.courseHistory.hidesMakeupOutliers"
    /// App Store 自动更新检查使用全局 key，账号切换后继续复用该状态。
    nonisolated static let automaticUpdateChecksEnabledKey = "app.settings.automatic-update-checks.enabled"
    /// 机器人帖子隐藏默认值按账号完成一次迁移。
    nonisolated static let galleryBotFilterDefaultMigrationKeyPrefix = "app.settings.gallery-hide-bot-default"
    /// “鸣谢 LINUX DO”提示按账号映射到首周内的延迟天数，分散弹出时间。
    nonisolated static let linuxDoThanksNoticeSpreadDays = 7
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    @Published private(set) var snapshot = AppSettingsSnapshot()
    @Published private(set) var hidesCourseHistoryMakeupOutliers = true
    @Published private(set) var automaticUpdateChecksEnabled = true

    private let defaults: UserDefaults
    private let session: () -> AppStorageSession
    /// 初始化当前账号的设置快照。
    init(
        defaults: UserDefaults = AppFileDirectories.defaults,
        session: @escaping () -> AppStorageSession = { AppFileDirectories.currentSession }
    ) {
        self.defaults = defaults
        self.session = session
        load()
    }

    /// 账号生命周期协调器按顺序重载设置与社区偏好。
    func reloadForCurrentAccount() { load() }

    /// 以下计算属性为视图层提供读取入口；设置方法集中处理 snapshot 写入。
    var galleryHideBotPosterInSearch: Bool { snapshot.galleryHideBotPosterInSearch }
    var galleryHiddenUserIDs: [Int] { snapshot.galleryHiddenUserIDs }
    var galleryHideAnonymousContent: Bool { snapshot.galleryHideAnonymousContent }
    var galleryUseWebView: Bool { snapshot.galleryUseWebView }
    var hasSeenSharedScheduleImportGuide: Bool { snapshot.hasSeenSharedScheduleImportGuide }
    var shouldShowCurrentStartupNotice: Bool {
        defaults.string(forKey: Self.startupNoticeSeenKey) != Self.currentStartupNoticeVersion
    }
    var shouldShowLinuxDoThanksNotice: Bool {
        guard
            let firstOpenDate = snapshot.firstOpenDate,
            !snapshot.hasShownLinuxDoThanksNotice
        else {
            return false
        }

        let dueDate = Calendar.current.date(
            byAdding: .day,
            value: Self.linuxDoThanksNoticeDelayDays(for: currentAccountIdentifier),
            to: firstOpenDate
        ) ?? firstOpenDate
        return Date() >= dueDate
    }

    /// 修改普通帖子页面中的机器人帖子隐藏开关。
    func updateGallerySettings(
        hideBotPosterInSearch: Bool? = nil,
        hiddenUserIDs: [Int]? = nil,
        hideAnonymousContent: Bool? = nil,
        useWebView: Bool? = nil
    ) {
        if let hideBotPosterInSearch {
            snapshot.galleryHideBotPosterInSearch = hideBotPosterInSearch
        }
        if let hiddenUserIDs {
            snapshot.galleryHiddenUserIDs = Self.normalizedGalleryHiddenUserIDs(hiddenUserIDs)
        }
        if let hideAnonymousContent {
            snapshot.galleryHideAnonymousContent = hideAnonymousContent
        }
        if let useWebView {
            snapshot.galleryUseWebView = useWebView
        }
        save(syncPreferences: true)
    }

    /// 修改历史成绩中的疑似补考学期隐藏开关。
    func setHidesCourseHistoryMakeupOutliers(_ enabled: Bool) {
        hidesCourseHistoryMakeupOutliers = enabled
        defaults.set(enabled, forKey: currentCourseHistoryHidesMakeupOutliersKey)
    }

    /// 修改启动时的 App Store 自动检查开关。
    func setAutomaticUpdateChecksEnabled(_ enabled: Bool) {
        automaticUpdateChecksEnabled = enabled
        defaults.set(enabled, forKey: Self.automaticUpdateChecksEnabledKey)
    }

    /// 标记当前安装版本的更新内容已经展示。
    func markCurrentStartupNoticeSeen() {
        defaults.set(Self.currentStartupNoticeVersion, forKey: Self.startupNoticeSeenKey)
    }

    /// 标记“鸣谢 LINUX DO”提示已经弹出过。
    func markLinuxDoThanksNoticeShown() {
        snapshot.hasShownLinuxDoThanksNotice = true
        save()
    }

    /// 标记“导入分享课表”提示已读。
    func markSharedScheduleImportGuideSeen() {
        snapshot.hasSeenSharedScheduleImportGuide = true
        save()
    }

    /// 把设置恢复到默认值。
    func resetToDefaults() {
        snapshot = AppSettingsSnapshot()
        setHidesCourseHistoryMakeupOutliers(true)
        setAutomaticUpdateChecksEnabled(true)
        save(syncPreferences: true)
    }

    /// 应用来自 iCloud 的用户偏好，并保留当前设备的一次性提示状态。
    func applySyncedPreferences(_ payload: AppSettingsSyncPayload) {
        snapshot.galleryHideBotPosterInSearch = payload.galleryHideBotPosterInSearch
        snapshot.galleryHiddenUserIDs = Self.normalizedGalleryHiddenUserIDs(payload.galleryHiddenUserIDs)
        snapshot.galleryHideAnonymousContent = payload.galleryHideAnonymousContent
        snapshot.galleryUseWebView = payload.galleryUseWebView
        save()
    }

    /// 从 `UserDefaults` 加载设置快照。
    ///
    /// 账号切换通知会重新触发这里。缺少快照或 `firstOpenDate` 时，这里补齐默认值并保存快照；
    /// 已有快照直接恢复。
    private func load() {
        migrateLegacyScopedDefaults()
        loadCourseHistoryPreference()
        loadAutomaticUpdatePreference()
        let accountID = currentAccountIdentifier
        guard let snapshot = Self.loadSnapshotFromDefaults(for: accountID, defaults: defaults)
                ?? Self.migrateLegacySnapshotIfNeeded(for: accountID, defaults: defaults) else {
            self.snapshot = AppSettingsSnapshot()
            self.snapshot.firstOpenDate = Date()
            defaults.set(true, forKey: galleryBotFilterDefaultMigrationKey)
            save()
            return
        }
        self.snapshot = snapshot
        let normalizedHiddenUserIDs = Self.normalizedGalleryHiddenUserIDs(self.snapshot.galleryHiddenUserIDs)
        if self.snapshot.galleryHiddenUserIDs != normalizedHiddenUserIDs {
            self.snapshot.galleryHiddenUserIDs = normalizedHiddenUserIDs
            save(syncPreferences: true)
        }
        if defaults.object(forKey: galleryBotFilterDefaultMigrationKey) == nil {
            self.snapshot.galleryHideBotPosterInSearch = true
            defaults.set(true, forKey: galleryBotFilterDefaultMigrationKey)
            save(syncPreferences: true)
        }
        if self.snapshot.firstOpenDate == nil {
            self.snapshot.firstOpenDate = Date()
            save()
        }
    }

    /// 读取当前账号的历史成绩筛选偏好；首次使用时默认开启并立即持久化。
    private func loadCourseHistoryPreference() {
        let accountKey = currentCourseHistoryHidesMakeupOutliersKey
        if let storedValue = defaults.object(forKey: accountKey) as? Bool {
            hidesCourseHistoryMakeupOutliers = storedValue
        } else if let legacyValue = defaults.object(forKey: Self.courseHistoryHidesMakeupOutliersKey) as? Bool {
            hidesCourseHistoryMakeupOutliers = legacyValue
            defaults.set(legacyValue, forKey: accountKey)
            defaults.removeObject(forKey: Self.courseHistoryHidesMakeupOutliersKey)
        } else {
            hidesCourseHistoryMakeupOutliers = true
            defaults.set(true, forKey: accountKey)
        }
    }

    /// 读取启动时的 App Store 自动检查开关；首次使用时默认开启并立即持久化。
    private func loadAutomaticUpdatePreference() {
        if let storedValue = defaults.object(forKey: Self.automaticUpdateChecksEnabledKey) as? Bool {
            automaticUpdateChecksEnabled = storedValue
        } else {
            automaticUpdateChecksEnabled = true
            defaults.set(true, forKey: Self.automaticUpdateChecksEnabledKey)
        }
    }

    /// 把当前快照写回 `UserDefaults`。
    ///
    /// 设置快照编码后通过这里写回 `UserDefaults`；当前账号使用 `currentStorageKey`。
    private func save(syncPreferences: Bool = false) {
        if let data = try? Self.encoder.encode(snapshot) {
            defaults.set(data, forKey: currentStorageKey)
            let legacyKey = session().legacyKey(
                Self.storageKeyPrefix,
                guestIdentifier: Self.defaultAccountIdentifier
            )
            if legacyKey != currentStorageKey { defaults.removeObject(forKey: legacyKey) }
        }
        if syncPreferences {
            didSave?()
        }
    }

    /// 提供设置快照的静态读取入口。
    static func loadSnapshotFromDefaults() -> AppSettingsSnapshot? {
        loadSnapshotFromDefaults(for: shared.currentAccountIdentifier)
    }

    /// 读取指定账号对应的设置快照。
    static func loadSnapshotFromDefaults(for accountID: String, defaults: UserDefaults = AppFileDirectories.defaults) -> AppSettingsSnapshot? {
        let currentKey = storageKey(for: accountID)
        let legacyKey = legacyStorageKey(for: accountID)
        guard let data = defaults.data(forKey: currentKey) ?? defaults.data(forKey: legacyKey),
              let snapshot = try? decoder.decode(AppSettingsSnapshot.self, from: data) else { return nil }
        if defaults.data(forKey: currentKey) == nil {
            defaults.set(data, forKey: currentKey)
            if legacyKey != currentKey { defaults.removeObject(forKey: legacyKey) }
        }
        return snapshot
    }

    /// 把账号隔离前的快照迁移到当前账号分区。
    private static func migrateLegacySnapshotIfNeeded(for accountID: String, defaults: UserDefaults) -> AppSettingsSnapshot? {
        guard accountID != defaultAccountIdentifier else { return nil }
        guard
            let data = defaults.data(forKey: legacyStorageKey),
            let snapshot = try? decoder.decode(AppSettingsSnapshot.self, from: data)
        else {
            return nil
        }

        defaults.set(data, forKey: storageKey(for: accountID))
        defaults.removeObject(forKey: legacyStorageKey)
        return snapshot
    }

    private var currentStorageKey: String {
        session().key(
            Self.storageKeyPrefix,
            guestIdentifier: Self.defaultAccountIdentifier
        )
    }

    private var galleryBotFilterDefaultMigrationKey: String {
        session().key(
            Self.galleryBotFilterDefaultMigrationKeyPrefix,
            guestIdentifier: Self.defaultAccountIdentifier
        )
    }

    private var currentCourseHistoryHidesMakeupOutliersKey: String {
        session().key(
            Self.courseHistoryHidesMakeupOutliersKey,
            guestIdentifier: Self.defaultAccountIdentifier
        )
    }

    /// 按账号生成设置快照的存储 key。
    private static func storageKey(for accountID: String) -> String {
        AppStorageSession(accountIdentifier: accountID).key(
            storageKeyPrefix,
            guestIdentifier: defaultAccountIdentifier
        )
    }

    private static func legacyStorageKey(for accountID: String) -> String {
        AppStorageSession(accountIdentifier: accountID).legacyKey(
            storageKeyPrefix,
            guestIdentifier: defaultAccountIdentifier
        )
    }

    private func migrateLegacyScopedDefaults() {
        let session = session()
        for prefix in [
            Self.galleryBotFilterDefaultMigrationKeyPrefix,
            Self.courseHistoryHidesMakeupOutliersKey,
        ] {
            let currentKey = session.key(prefix, guestIdentifier: Self.defaultAccountIdentifier)
            let legacyKey = session.legacyKey(prefix, guestIdentifier: Self.defaultAccountIdentifier)
            guard currentKey != legacyKey,
                  defaults.object(forKey: currentKey) == nil,
                  let value = defaults.object(forKey: legacyKey)
            else { continue }
            defaults.set(value, forKey: currentKey)
            defaults.removeObject(forKey: legacyKey)
        }
    }

    private static func normalizedGalleryHiddenUserIDs(_ values: [Int]) -> [Int] {
        Array(Set(values.filter { $0 > 0 })).sorted()
    }

    /// 读取当前账号标识；学号为空时使用默认分区。
    private var currentAccountIdentifier: String {
        let session = session()
        return session.isGuest ? Self.defaultAccountIdentifier : session.accountIdentifier
    }

    /// 按账号稳定地映射到首周内的某一天。
    ///
    /// 哈希结果让首次打开当天有机会弹出，并把提示时间分散到 7 天。
    private static func linuxDoThanksNoticeDelayDays(for accountID: String) -> Int {
        guard linuxDoThanksNoticeSpreadDays > 0 else { return 0 }

        var hash: UInt64 = 1469598103934665603
        for byte in accountID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return Int(hash % UInt64(linuxDoThanksNoticeSpreadDays))
    }
}
