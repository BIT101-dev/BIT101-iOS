//
//  AppSettingsStore.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Combine
import Foundation
import SwiftUI

extension Notification.Name {
    /// 登录存储变化通知。
    ///
    /// 多账号隔离设置、小组件和日程缓存都会用这条通知感知账号切换。
    static let loginStorageDidChange = Notification.Name("BIT101.LoginStorageDidChange")
}

/// 应用层主题模式。
///
/// 持久化层使用这个主题枚举；`colorScheme` 提供 SwiftUI 的 `ColorScheme` 映射。
/// 枚举使用 `String` 原始值和 `Codable`，可安全存入 `UserDefaults`，`system` 保留“跟随系统”语义。
enum AppThemeMode: String, CaseIterable, Identifiable, Codable {
    case system
    case light
    case dark

    /// 供 `Picker` 和持久化使用的稳定标识。
    var id: String { rawValue }

    /// 设置页展示的主题标题。
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// 对应 SwiftUI 使用的 `ColorScheme`。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// 持久化到 `UserDefaults` 的设置快照。
///
/// 设置快照统一承接 UI 层的修改、读写、账号隔离和默认值。
struct AppSettingsSnapshot: Codable, Equatable {
    /// 用户主动指定的主题模式。
    var themeMode: AppThemeMode = .system
    /// 是否允许界面自动旋转。
    var autoRotate = false
    /// 普通帖子页面按开关隐藏机器人帖子，机器人分栏保持显示。
    var galleryHideBotPosterInSearch = false
    /// 是否已经看过“导入分享课表”的使用提示。
    var hasSeenSharedScheduleImportGuide = false
    /// 当前账号第一次进入 app 的时间。
    var firstOpenDate: Date?
    /// 当前账号是否已经看过“鸣谢 LINUX DO”提示。
    var hasShownLinuxDoThanksNotice = false

    enum CodingKeys: String, CodingKey {
        case themeMode
        case autoRotate
        case galleryHideBotPosterInSearch
        case hasSeenSharedScheduleImportGuide
        case firstOpenDate
        case hasShownLinuxDoThanksNotice
    }
}

/// 同步载荷包含用户偏好字段；首次打开时间和一次性提示状态保留在本机。
struct AppSettingsSyncPayload: Codable, Equatable {
    var themeMode: AppThemeMode
    var autoRotate: Bool
    var galleryHideBotPosterInSearch: Bool

    init(snapshot: AppSettingsSnapshot) {
        themeMode = snapshot.themeMode
        autoRotate = snapshot.autoRotate
        galleryHideBotPosterInSearch = snapshot.galleryHideBotPosterInSearch
    }
}

@MainActor
/// 应用设置仓库。
///
/// 主题、账号偏好和全局筛选偏好都会统一写入这里，再由具体页面按需读取。
final class AppSettingsStore: ObservableObject {
    static let shared = AppSettingsStore()
    /// 各账号设置快照在 `UserDefaults` 中使用的 key 前缀。
    nonisolated static let storageKeyPrefix = "app.settings.snapshot"
    /// 当前安装版本的更新内容版本号；每个版本展示一次。
    nonisolated static let currentStartupNoticeVersion = "1.8.1"
    /// 更新内容公告已读状态保存在全局 key，账号切换后继续复用该状态。
    nonisolated static let startupNoticeSeenKey = "app.startup.notice.seen.version"
    /// 历史成绩疑似补考学期筛选使用全局 key，账号切换后继续复用该状态。
    nonisolated static let courseHistoryHidesMakeupOutliersKey = "app.settings.courseHistory.hidesMakeupOutliers"
    /// “鸣谢 LINUX DO”提示按账号映射到首周内的延迟天数，分散弹出时间。
    nonisolated static let linuxDoThanksNoticeSpreadDays = 7
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    @Published private(set) var snapshot = AppSettingsSnapshot()
    @Published private(set) var hidesCourseHistoryMakeupOutliers = true

    private let defaults = UserDefaults.standard
    private var accountObserver: NSObjectProtocol?

    /// 初始化设置仓库，并监听账号切换。
    private init() {
        load()
        accountObserver = NotificationCenter.default.addObserver(
            forName: .loginStorageDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.load()
            }
        }
    }

    deinit {
        if let accountObserver {
            NotificationCenter.default.removeObserver(accountObserver)
        }
    }

    /// 以下计算属性为视图层提供读取入口；设置方法集中处理 snapshot 写入。
    var themeMode: AppThemeMode { snapshot.themeMode }
    var autoRotate: Bool { snapshot.autoRotate }
    var galleryHideBotPosterInSearch: Bool { snapshot.galleryHideBotPosterInSearch }
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
            value: Self.linuxDoThanksNoticeDelayDays(for: Self.currentAccountIdentifier()),
            to: firstOpenDate
        ) ?? firstOpenDate
        return Date() >= dueDate
    }

    /// 修改固定主题模式。
    func setThemeMode(_ mode: AppThemeMode) {
        snapshot.themeMode = mode
        save(syncPreferences: true)
    }

    /// 修改自动旋转开关。
    func setAutoRotate(_ enabled: Bool) {
        snapshot.autoRotate = enabled
        save(syncPreferences: true)
        AppOrientationController.applyPreference(autoRotate: enabled)
    }

    /// 修改普通帖子页面中的机器人帖子隐藏开关。
    func updateGallerySettings(hideBotPosterInSearch: Bool) {
        snapshot.galleryHideBotPosterInSearch = hideBotPosterInSearch
        save(syncPreferences: true)
    }

    /// 修改历史成绩中的疑似补考学期隐藏开关。
    func setHidesCourseHistoryMakeupOutliers(_ enabled: Bool) {
        hidesCourseHistoryMakeupOutliers = enabled
        defaults.set(enabled, forKey: Self.courseHistoryHidesMakeupOutliersKey)
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
        save(syncPreferences: true)
    }

    /// 应用来自 iCloud 的用户偏好，并保留当前设备的一次性提示状态。
    func applySyncedPreferences(_ payload: AppSettingsSyncPayload) {
        snapshot.themeMode = payload.themeMode
        snapshot.autoRotate = payload.autoRotate
        snapshot.galleryHideBotPosterInSearch = payload.galleryHideBotPosterInSearch
        save()
        AppOrientationController.applyPreference(autoRotate: snapshot.autoRotate)
    }

    /// 从 `UserDefaults` 加载设置快照。
    ///
    /// 账号切换通知会重新触发这里。缺少快照或 `firstOpenDate` 时，这里补齐默认值并保存快照；
    /// 已有快照直接恢复。
    private func load() {
        loadCourseHistoryPreference()
        guard let snapshot = Self.loadSnapshotFromDefaults() else {
            self.snapshot = AppSettingsSnapshot()
            self.snapshot.firstOpenDate = Date()
            save()
            return
        }
        self.snapshot = snapshot
        if self.snapshot.firstOpenDate == nil {
            self.snapshot.firstOpenDate = Date()
            save()
        }
    }

    /// 读取全局历史成绩筛选偏好；首次使用时默认开启并立即持久化。
    private func loadCourseHistoryPreference() {
        if let storedValue = defaults.object(forKey: Self.courseHistoryHidesMakeupOutliersKey) as? Bool {
            hidesCourseHistoryMakeupOutliers = storedValue
        } else {
            hidesCourseHistoryMakeupOutliers = true
            defaults.set(true, forKey: Self.courseHistoryHidesMakeupOutliersKey)
        }
    }

    /// 把当前快照写回 `UserDefaults`。
    ///
    /// 设置快照编码后通过这里写回 `UserDefaults`；当前账号使用 `currentStorageKey`。
    private func save(syncPreferences: Bool = false) {
        if let data = try? Self.encoder.encode(snapshot) {
            defaults.set(data, forKey: currentStorageKey)
        }
        if syncPreferences {
            ExperimentalPreferenceCloudSync.shared.localValueDidChange(in: .appSettings)
        }
    }

    /// 提供设置快照的静态读取入口。
    static func loadSnapshotFromDefaults() -> AppSettingsSnapshot? {
        loadSnapshotFromDefaults(for: currentAccountIdentifier())
    }

    /// 读取指定账号对应的设置快照。
    static func loadSnapshotFromDefaults(for accountID: String) -> AppSettingsSnapshot? {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey(for: accountID)),
            let snapshot = try? decoder.decode(AppSettingsSnapshot.self, from: data)
        else {
            return nil
        }
        return snapshot
    }

    private var currentStorageKey: String {
        Self.storageKey(for: Self.currentAccountIdentifier())
    }

    /// 按账号生成设置快照的存储 key。
    private static func storageKey(for accountID: String) -> String {
        "\(storageKeyPrefix).\(accountID)"
    }

    /// 读取当前账号标识；学号为空时使用默认分区。
    private static func currentAccountIdentifier() -> String {
        let raw = LoginStorage.shared.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "__default__" : raw
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
