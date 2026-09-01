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
/// 这里是持久化层使用的主题枚举，而不是直接暴露 SwiftUI 的 `ColorScheme`，
/// 这样可以安全存储到 `UserDefaults`，也能保留“跟随系统”这一语义。
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

/// 被用户本地隐藏的帖子摘要。
///
/// 只保存恢复显示需要的最小字段，不复制整份帖子详情。
struct HiddenPosterRecord: Codable, Equatable, Identifiable, Hashable {
    let id: Int
    let title: String
    let userID: Int
    let userNickname: String
    let createdTime: String
}

/// 持久化到 `UserDefaults` 的设置快照。
///
/// 这是整个 app 的“设置真相来源”。UI 层只改这里，真正的读写、账号隔离和默认值全由这份快照承接。
struct AppSettingsSnapshot: Codable, Equatable {
    /// 启动后默认选中的 tab。
    var homeTab: AppTab = .schedule
    /// 底部栏页面顺序。
    var pageOrder: [AppTab] = AppTab.allCases
    /// 被用户隐藏的 tab。
    var hiddenTabs: [AppTab] = []
    /// 用户主动指定的主题模式。
    var themeMode: AppThemeMode = .system
    /// 是否允许界面自动旋转。
    var autoRotate = false
    /// 是否在搜索结果里也隐藏机器人帖子。
    var galleryHideBotPosterInSearch = false
    /// 是否启用更严格的画廊过滤。
    var galleryHideStrictMode = false
    /// 用户主动屏蔽的用户 ID 列表。
    var galleryHiddenUserIDs: [Int] = []
    /// 用户主动隐藏的帖子摘要。
    var galleryHiddenPosters: [HiddenPosterRecord] = []
    /// 用户主动隐藏的文章 ID 列表。
    var paperHiddenIDs: [Int] = []
    /// 当前设备接受过的社区规则版本号。
    var galleryCommunityRulesAcceptedVersion = 0
    /// 是否已经看过“导入分享课表”的使用提示。
    var hasSeenSharedScheduleImportGuide = false
    /// 当前设备已接受过的小组件使用提示版本号。
    var widgetUsageGuideAcceptedVersion = 0
    /// 当前账号第一次进入 app 的时间。
    var firstOpenDate: Date?
    /// 当前账号是否已经看过“鸣谢 LINUX DO”提示。
    var hasShownLinuxDoThanksNotice = false
}

/// 只同步真正属于用户偏好的字段；规则确认、首次打开时间和一次性提示仍保留在本机。
struct AppSettingsSyncPayload: Codable, Equatable {
    var homeTab: AppTab
    var pageOrder: [AppTab]
    var hiddenTabs: [AppTab]
    var themeMode: AppThemeMode
    var autoRotate: Bool
    var galleryHideBotPosterInSearch: Bool
    var galleryHideStrictMode: Bool
    var galleryHiddenUserIDs: [Int]
    var galleryHiddenPosters: [HiddenPosterRecord]
    var paperHiddenIDs: [Int]

    init(snapshot: AppSettingsSnapshot) {
        homeTab = snapshot.homeTab
        pageOrder = snapshot.pageOrder
        hiddenTabs = snapshot.hiddenTabs
        themeMode = snapshot.themeMode
        autoRotate = snapshot.autoRotate
        galleryHideBotPosterInSearch = snapshot.galleryHideBotPosterInSearch
        galleryHideStrictMode = snapshot.galleryHideStrictMode
        galleryHiddenUserIDs = snapshot.galleryHiddenUserIDs
        galleryHiddenPosters = snapshot.galleryHiddenPosters
        paperHiddenIDs = snapshot.paperHiddenIDs
    }
}

@MainActor
/// 全局设置仓库。
///
/// 页面顺序、主题、画廊过滤规则等都会统一写入这里，再由具体页面按需读取。
final class AppSettingsStore: ObservableObject {
    static let shared = AppSettingsStore()
    /// 各账号设置快照在 `UserDefaults` 中使用的 key 前缀。
    nonisolated static let storageKeyPrefix = "app.settings.snapshot"
    /// 当前社区规则版本号；版本提升后会强制重新弹出规则确认。
    nonisolated static let currentCommunityRulesVersion = 2
    /// 当前安装版本的更新内容公告；每个版本只展示一次。
    nonisolated static let currentStartupNoticeVersion = "1.7.6"
    /// 更新内容公告已读状态使用全局 key，避免切换账号后重复展示。
    nonisolated static let startupNoticeSeenKey = "app.startup.notice.seen.version"
    /// 当前“小组件使用提示”版本号；版本提升后会重新展示一次。
    nonisolated static let currentWidgetUsageGuideVersion = 1
    /// “鸣谢 LINUX DO”提示会在首周内按账号均匀散开弹出，避免集中到固定某一天。
    nonisolated static let linuxDoThanksNoticeSpreadDays = 7
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    @Published private(set) var snapshot = AppSettingsSnapshot()

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

    /// 以下计算属性用于给视图层提供只读入口，避免页面直接改写 snapshot。
    var homeTab: AppTab { snapshot.homeTab }
    var pageOrder: [AppTab] { snapshot.pageOrder }
    var hiddenTabs: [AppTab] { snapshot.hiddenTabs }
    var themeMode: AppThemeMode { snapshot.themeMode }
    var autoRotate: Bool { snapshot.autoRotate }
    var galleryHideBotPosterInSearch: Bool { snapshot.galleryHideBotPosterInSearch }
    var galleryHideStrictMode: Bool { snapshot.galleryHideStrictMode }
    var galleryHiddenUserIDs: [Int] { snapshot.galleryHiddenUserIDs }
    var galleryHiddenPosters: [HiddenPosterRecord] { snapshot.galleryHiddenPosters }
    var galleryHiddenPosterIDs: [Int] { snapshot.galleryHiddenPosters.map(\.id) }
    var paperHiddenIDs: [Int] { snapshot.paperHiddenIDs }
    var hasAcceptedCurrentCommunityRules: Bool { snapshot.galleryCommunityRulesAcceptedVersion >= Self.currentCommunityRulesVersion }
    var hasSeenSharedScheduleImportGuide: Bool { snapshot.hasSeenSharedScheduleImportGuide }
    var shouldShowCurrentStartupNotice: Bool {
        defaults.string(forKey: Self.startupNoticeSeenKey) != Self.currentStartupNoticeVersion
    }
    var hasAcceptedCurrentWidgetUsageGuide: Bool { snapshot.widgetUsageGuideAcceptedVersion >= Self.currentWidgetUsageGuideVersion }
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

    /// 当前真正可见的底部页面集合。
    var visibleTabs: [AppTab] {
        snapshot.pageOrder.filter { tab in
            tab == .mine || !snapshot.hiddenTabs.contains(tab)
        }
    }

    /// 修改默认启动页。
    func setHomeTab(_ tab: AppTab) {
        snapshot.homeTab = normalizedHomeTab(tab)
        save(syncPreferences: true)
    }

    /// 保存底部栏顺序。
    func setPageOrder(_ tabs: [AppTab]) {
        snapshot.pageOrder = normalizePageOrder(tabs)
        save(syncPreferences: true)
    }

    /// 保存被隐藏的 tab 集合。
    func setHiddenTabs(_ tabs: [AppTab]) {
        snapshot.hiddenTabs = tabs.filter { $0 != .mine && $0 != .paper && $0 != .course }
        if snapshot.hiddenTabs.contains(snapshot.homeTab) {
            snapshot.homeTab = visibleTabs.first ?? .schedule
        }
        save(syncPreferences: true)
    }

    /// 重置页面顺序和默认页设置。
    func resetPageSettings() {
        snapshot.pageOrder = AppTab.allCases
        snapshot.hiddenTabs = []
        snapshot.homeTab = .schedule
        save(syncPreferences: true)
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

    /// 一次性更新画廊治理相关设置。
    ///
    /// 这些偏好会和当前学号一起隔离存储，不会在切号后串到别的账号上。
    func updateGallerySettings(
        hideBotPosterInSearch: Bool? = nil,
        hideStrictMode: Bool? = nil,
        hiddenUserIDs: [Int]? = nil
    ) {
        if let hideBotPosterInSearch { snapshot.galleryHideBotPosterInSearch = hideBotPosterInSearch }
        if let hideStrictMode { snapshot.galleryHideStrictMode = hideStrictMode }
        if let hiddenUserIDs { snapshot.galleryHiddenUserIDs = hiddenUserIDs }
        save(syncPreferences: true)
    }

    /// 在隐藏匿名用户和恢复匿名用户之间切换。
    func toggleHideAnonymous() {
        if snapshot.galleryHiddenUserIDs.first == -1 {
            snapshot.galleryHiddenUserIDs.removeFirst()
        } else {
            snapshot.galleryHiddenUserIDs.insert(-1, at: 0)
        }
        save(syncPreferences: true)
    }

    /// 删除一条已屏蔽用户记录。
    func removeHiddenUser(at index: Int) {
        guard snapshot.galleryHiddenUserIDs.indices.contains(index) else { return }
        snapshot.galleryHiddenUserIDs.remove(at: index)
        save(syncPreferences: true)
    }

    /// 把一条帖子加入本地隐藏列表。
    func hidePoster(id: Int, title: String, userID: Int, userNickname: String, createdTime: String) {
        snapshot.galleryHiddenPosters.removeAll { $0.id == id }
        snapshot.galleryHiddenPosters.insert(
            HiddenPosterRecord(
                id: id,
                title: title,
                userID: userID,
                userNickname: userNickname,
                createdTime: createdTime
            ),
            at: 0
        )
        save(syncPreferences: true)
    }

    /// 删除一条已隐藏帖子记录。
    func removeHiddenPoster(at index: Int) {
        guard snapshot.galleryHiddenPosters.indices.contains(index) else { return }
        snapshot.galleryHiddenPosters.remove(at: index)
        save(syncPreferences: true)
    }

    /// 把一篇文章加入本地隐藏列表。
    func hidePaper(id: Int) {
        guard !snapshot.paperHiddenIDs.contains(id) else { return }
        snapshot.paperHiddenIDs.append(id)
        save(syncPreferences: true)
    }

    /// 记录当前设备已经同意最新社区规则。
    func acceptCurrentCommunityRules() {
        snapshot.galleryCommunityRulesAcceptedVersion = Self.currentCommunityRulesVersion
        save()
    }

    /// 撤销社区规则同意状态，方便重新验证 EULA。
    func revokeCommunityRulesAcceptance() {
        snapshot.galleryCommunityRulesAcceptedVersion = 0
        save()
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

    /// 记录当前设备已经接受最新的小组件使用提示。
    func markCurrentWidgetUsageGuideSeen() {
        snapshot.widgetUsageGuideAcceptedVersion = Self.currentWidgetUsageGuideVersion
        save()
    }

    /// 把设置恢复到默认值。
    func resetToDefaults() {
        snapshot = AppSettingsSnapshot()
        save(syncPreferences: true)
    }

    /// 应用来自 iCloud 的用户偏好，同时保留当前设备的一次性提示与规则确认状态。
    func applySyncedPreferences(_ payload: AppSettingsSyncPayload) {
        snapshot.homeTab = normalizedHomeTab(payload.homeTab)
        snapshot.pageOrder = normalizePageOrder(payload.pageOrder)
        snapshot.hiddenTabs = payload.hiddenTabs.filter { $0 != .mine && $0 != .paper && $0 != .course }
        if snapshot.hiddenTabs.contains(snapshot.homeTab) {
            snapshot.homeTab = visibleTabs.first ?? .schedule
        }
        snapshot.themeMode = payload.themeMode
        snapshot.autoRotate = payload.autoRotate
        snapshot.galleryHideBotPosterInSearch = payload.galleryHideBotPosterInSearch
        snapshot.galleryHideStrictMode = payload.galleryHideStrictMode
        snapshot.galleryHiddenUserIDs = payload.galleryHiddenUserIDs
        snapshot.galleryHiddenPosters = payload.galleryHiddenPosters
        snapshot.paperHiddenIDs = payload.paperHiddenIDs
        save()
        AppOrientationController.applyPreference(autoRotate: snapshot.autoRotate)
    }

    /// 从 `UserDefaults` 加载设置快照。
    ///
    /// 账号切换通知会重新触发这里，因此这里不做任何副作用操作，只负责恢复快照。
    private func load() {
        guard let snapshot = Self.loadSnapshotFromDefaults() else {
            self.snapshot = AppSettingsSnapshot()
            self.snapshot.firstOpenDate = Date()
            save()
            return
        }
        self.snapshot = snapshot
        self.snapshot.homeTab = normalizedHomeTab(self.snapshot.homeTab)
        self.snapshot.pageOrder = normalizePageOrder(self.snapshot.pageOrder)
        self.snapshot.hiddenTabs = self.snapshot.hiddenTabs.filter { $0 != .mine && $0 != .paper && $0 != .course }
        if self.snapshot.firstOpenDate == nil {
            self.snapshot.firstOpenDate = Date()
            save()
        }
    }

    /// 把当前快照写回 `UserDefaults`。
    ///
    /// 所有设置入口最终都汇总到这里落盘，保证同一账号只维护一份快照。
    private func save(syncPreferences: Bool = false) {
        if let data = try? Self.encoder.encode(snapshot) {
            defaults.set(data, forKey: currentStorageKey)
        }
        if syncPreferences {
            ExperimentalPreferenceCloudSync.shared.localValueDidChange(in: .appSettings)
        }
    }

    /// 提供给非主线程读取的只读快照加载入口。
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

    /// 读取当前账号标识；未登录时统一回退到默认分区。
    private static func currentAccountIdentifier() -> String {
        let raw = LoginStorage.shared.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "__default__" : raw
    }

    /// 按账号稳定地映射到首周内的某一天。
    ///
    /// 这样第一次打开当天也可能弹出，同时整体分布比固定“第 7 天”更均匀。
    private static func linuxDoThanksNoticeDelayDays(for accountID: String) -> Int {
        guard linuxDoThanksNoticeSpreadDays > 0 else { return 0 }

        var hash: UInt64 = 1469598103934665603
        for byte in accountID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return Int(hash % UInt64(linuxDoThanksNoticeSpreadDays))
    }

    /// 修正页面顺序，避免重复、缺失和旧版本快照造成的异常。
    private func normalizePageOrder(_ tabs: [AppTab]) -> [AppTab] {
        // 防止重复 tab、缺失 tab 或旧版本快照导致页面顺序异常。
        var ordered: [AppTab] = []
        for tab in tabs where tab != .paper && tab != .course && !ordered.contains(tab) {
            ordered.append(tab)
        }
        for tab in AppTab.allCases where !ordered.contains(tab) {
            ordered.append(tab)
        }
        if let mineIndex = ordered.firstIndex(of: .mine), mineIndex != ordered.count - 1 {
            let mineTab = ordered.remove(at: mineIndex)
            ordered.append(mineTab)
        }
        return ordered
    }

    /// 把旧版本已下线的 tab 映射到新的入口。
    private func normalizedHomeTab(_ tab: AppTab) -> AppTab {
        switch tab {
        case .paper:
            return .gallery
        case .course:
            return .score
        default:
            return tab
        }
    }
}
