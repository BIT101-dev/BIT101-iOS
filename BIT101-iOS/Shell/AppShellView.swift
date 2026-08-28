//
//  AppShellView.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import SwiftUI
import Combine
import UIKit

/// 应用底部 Tab 的稳定标识。
///
/// 页面设置和启动默认页都依赖这个枚举持久化。
enum AppTab: String, Identifiable, Codable {
    case schedule
    /// 仅用于兼容旧版本持久化出来的页面顺序和默认页配置。
    ///
    /// 课程入口现已并入“成绩”页顶部的二级栏位，不再作为独立底部 tab 展示。
    case course
    case map
    case gallery
    /// 仅用于兼容旧版本持久化出来的页面顺序和默认页配置。
    ///
    /// 文章入口现已并入“话廊”页顶部的二级栏位，不再作为独立底部 tab 展示。
    case paper
    case score = "home"
    case mine

    static let allCases: [AppTab] = [
        .schedule,
        .map,
        .gallery,
        .score,
        .mine
    ]

    /// 供 `TabView` 和设置持久化使用的稳定标识。
    var id: String { rawValue }

    /// 底部栏上展示的标题。
    var title: String {
        switch self {
        case .schedule:
            return "日程"
        case .course:
            return "课程"
        case .map:
            return "地图"
        case .score:
            return "学业"
        case .gallery:
            return "话廊"
        case .paper:
            return "文章"
        case .mine:
            return "我的"
        }
    }

    /// 底部栏对应的 SF Symbol。
    var systemImage: String {
        switch self {
        case .schedule:
            return "calendar"
        case .course:
            return "books.vertical"
        case .map:
            return "map"
        case .score:
            return "chart.bar.doc.horizontal"
        case .gallery:
            return "bubble.left.and.bubble.right"
        case .paper:
            return "doc.text"
        case .mine:
            return "person.crop.circle"
        }
    }

    /// 当前 tab 选中时使用的强调色。
    var tintColor: Color {
        switch self {
        case .schedule:
            return .indigo
        case .course:
            return .teal
        case .map:
            return .green
        case .score:
            return .pink
        case .gallery:
            return .orange
        case .paper:
            return .brown
        case .mine:
            return .blue
        }
    }
}

/// 登录后真正进入的应用壳层。
///
/// 壳层只关心两件事：按照设置中心决定展示哪些 tab，以及把退出登录回调继续往下传。
struct AppShellView: View {
    private static let startupNoticeTitle = "1.7.4 版本更新"
    private static let startupNoticeBody = "新增课表导入系统日历，优化使用体验"
    private static let widgetUsageGuideTitle = "非常有用的几个用法"
    private static let widgetUsageGuideBody = """
    推荐在锁屏添加锁屏小组件（如果你习惯使用息屏显示）。
    桌面小组件也很实用，可以尝试一波。
    """
    private static let linuxDoThanksTitle = "特别鸣谢 LINUX DO"
    private static let linuxDoThanksBody = "特别感谢 LINUX DO（L站）以及佬友们。这个 App 的诞生，离不开他们提供的免费 tokens 与无私的支持。L站倡导“真诚、友善、团结、专业，共建你我引以为荣之社区。”某种意义上，BIT101 也是在这样的氛围里，被一点点推出来的。\n\n如果你也想加入，可以向开发者发送邮件索要 L 站邀请码：systemd@linux.do"

    let studentID: String
    let onLogout: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var settings = AppSettingsStore.shared
    @ObservedObject private var schoolDataRefresh = SchoolDataRefreshCoordinator.shared
    @ObservedObject private var promptCoordinator = AppPromptCoordinator.shared
    @State private var selectedTab: AppTab = .schedule
    @State private var isShowingGalleryEULA = false
    @State private var requestedScheduleSection: ScheduleSection?
    @State private var requestedPaperID: Int?
    @State private var requestedPosterID: Int?
    @State private var requestedCourseID: Int?
    /// 系统全屏控制器关闭时壳层可能再次收到 `onAppear`，不能因此重置当前 tab。
    @State private var didInitializeSelectedTab = false

    /// 登录后的应用壳层主体。
    ///
    /// 这里同时承担：
    /// 1. 底部 tab 容器
    /// 2. 话廊 EULA 拦截
    /// 3. 版本更新内容与一次性使用提示
    /// 4. 小组件/深链路由分发
    var body: some View {
        TabView(selection: tabSelection) {
            ForEach(settings.visibleTabs) { tab in
                NavigationStack {
                    switch tab {
                    case .schedule:
                        ScheduleRootView(requestedSection: $requestedScheduleSection)
                    case .course:
                        ScoreRootView(requestedCourseID: $requestedCourseID)
                    case .map:
                        CampusMapScreen(scheduleViewModel: schoolDataRefresh.scheduleViewModel)
                    case .score:
                        ScoreRootView(requestedCourseID: $requestedCourseID)
                    case .gallery:
                        GalleryRootView(
                            requestedPaperID: $requestedPaperID,
                            requestedPosterID: $requestedPosterID
                        )
                    case .paper:
                        GalleryRootView(
                            requestedPaperID: $requestedPaperID,
                            requestedPosterID: $requestedPosterID
                        )
                    case .mine:
                        MineRootView(fallbackStudentID: studentID, onLogout: onLogout)
                    }
                }
                .tag(tab)
                .tabItem {
                    Label(tab.title, systemImage: tab.systemImage)
                }
            }
        }
        .tint(selectedTab.tintColor)
        .sheet(isPresented: $isShowingGalleryEULA) {
            GalleryCommunityRulesSheet(
                contactEmail: CommunitySupport.email,
                onAccept: {
                    settings.acceptCurrentCommunityRules()
                    selectedTab = .gallery
                    isShowingGalleryEULA = false
                },
                onDecline: {
                    isShowingGalleryEULA = false
                }
            )
        }
        .onAppear {
            if !didInitializeSelectedTab {
                didInitializeSelectedTab = true
                let initial = settings.visibleTabs.contains(settings.homeTab) ? settings.homeTab : (settings.visibleTabs.first ?? .schedule)
                if selectedTab != initial {
                    selectTab(initial)
                }
            }
            enqueueStartupPromptsIfNeeded()
        }
        .onChange(of: settings.snapshot) { _, _ in
            if !settings.visibleTabs.contains(selectedTab) {
                selectedTab = settings.visibleTabs.first ?? .schedule
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            refreshScheduleNotificationPromptIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .scheduleCacheDidChange)) { _ in
            refreshScheduleNotificationPromptIfNeeded()
        }
        .onReceive(schoolDataRefresh.$alert.compactMap { $0 }) { alert in
            promptCoordinator.enqueue(AppPrompt(
                id: "school-data-\(alert.id.uuidString)",
                title: alert.title,
                message: alert.message,
                actions: [
                    AppPromptAction(id: "dismiss", title: "知道了") {
                        schoolDataRefresh.alert = nil
                    }
                ]
            ))
        }
        .onReceive(AppDeepLinkCoordinator.shared.$pendingURL.compactMap { $0 }) { url in
            handleIncomingURL(url)
            AppDeepLinkCoordinator.shared.consume(url)
        }
    }

    /// 统一拦截 tab 切换，把话题 EULA 的弹出逻辑收束到这里。
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                selectTab(newTab)
            }
        )
    }

    /// 切换底部 tab，必要时先要求用户同意社区规则。
    private func selectTab(_ tab: AppTab) {
        if tab == .gallery, !settings.hasAcceptedCurrentCommunityRules {
            isShowingGalleryEULA = true
            return
        }
        selectedTab = tab
    }

    /// 处理来自小组件等入口的 app 深链。
    ///
    /// 同时接收 `bit101://` 内部链接和 `https://open.aihelpme.dev` Universal Link。
    private func handleIncomingURL(_ url: URL) {
        guard let route = AppDeepLinkRoute(url: url) else { return }

        switch route {
        case .scheduleCourses:
            selectedTab = .schedule
            requestedScheduleSection = .courses
        case let .paper(paperID):
            selectTab(.gallery)
            requestedPaperID = paperID
        case let .gallery(posterID):
            selectTab(.gallery)
            requestedPosterID = posterID
        case let .course(courseID):
            selectTab(.score)
            requestedCourseID = courseID
        }
    }

    /// 统一刷新“灵动岛提醒的通知权限提示”状态。
    ///
    /// 这层检查不能只放在 `onAppear`：
    /// - 用户可能刚从系统设置改完通知权限返回
    /// - 用户可能刚在课表设置里打开了灵动岛提醒
    /// - 用户也可能在前后台切换后才需要重新评估 fallback 能力
    ///
    /// 因此这里把提示状态集中收口，供 onAppear / 回前台 / 课表缓存变化共同复用。
    private func refreshScheduleNotificationPromptIfNeeded() {
        Task {
            let authorizationState = await ScheduleLiveActivityManager.shared.notificationAuthorizationStateForReminderFallback()
            guard authorizationState == .denied else { return }

            await MainActor.run {
                enqueueScheduleNotificationPrompt()
            }
        }
    }

    private func enqueueStartupPromptsIfNeeded() {
        if settings.shouldShowCurrentStartupNotice {
            promptCoordinator.enqueue(AppPrompt(
                id: "startup-notice-\(Self.startupNoticeTitle)",
                title: Self.startupNoticeTitle,
                message: Self.startupNoticeBody,
                actions: [
                    AppPromptAction(id: "confirm", title: "确定", isDefault: true) {
                        settings.markCurrentStartupNoticeSeen()
                    }
                ]
            ))
        }

        if !settings.hasAcceptedCurrentWidgetUsageGuide {
            promptCoordinator.enqueue(AppPrompt(
                id: "widget-usage-guide",
                title: Self.widgetUsageGuideTitle,
                message: Self.widgetUsageGuideBody,
                actions: [
                    AppPromptAction(id: "confirm", title: "知道了", isDefault: true) {
                        settings.markCurrentWidgetUsageGuideSeen()
                    }
                ]
            ))
        }

        if settings.shouldShowLinuxDoThanksNotice {
            promptCoordinator.enqueue(AppPrompt(
                id: "linux-do-thanks",
                title: Self.linuxDoThanksTitle,
                message: Self.linuxDoThanksBody,
                actions: [
                    AppPromptAction(id: "dismiss", title: "知道了", isDefault: true) {
                        settings.markLinuxDoThanksNoticeShown()
                    },
                    AppPromptAction(id: "send-email", title: "发送邮件") {
                        settings.markLinuxDoThanksNoticeShown()
                        if let url = URL(string: "mailto:systemd@linux.do") {
                            openURL(url)
                        }
                    }
                ]
            ))
        }

        refreshScheduleNotificationPromptIfNeeded()
    }

    private func enqueueScheduleNotificationPrompt() {
        promptCoordinator.enqueue(AppPrompt(
            id: "schedule-notification-permission",
            title: "请开启通知",
            message: "灵动岛需要应用常驻前台；应用未能自动启动时，会使用本地通知，以避免您错过上课。请在系统设置的通知页面中允许 BIT101 发送通知。",
            actions: [
                AppPromptAction(id: "cancel", title: "取消", role: .cancel) {},
                AppPromptAction(id: "open-settings", title: "转到设置", isDefault: true) {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        openURL(url)
                    } else if let fallbackURL = URL(string: UIApplication.openSettingsURLString) {
                        openURL(fallbackURL)
                    }
                }
            ]
        ))
    }
}

/// 首次进入话题前展示的社区规则弹层。
private struct GalleryCommunityRulesSheet: View {
    let contactEmail: String
    let onAccept: () -> Void
    let onDecline: () -> Void

    /// 首次进入话题前的社区规则确认页。
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("在继续进入话廊前，请确认你已阅读并同意社区规则。")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("1. 禁止发布政治敏感、色情低俗、辱骂骚扰、隐私泄露、谣言和广告刷屏内容。")
                        Text("2. 话廊内容会在本地进行敏感词过滤，以通过 Apple 审查；命中的帖子会被直接隐藏，因此显示的帖子数量可能会比网页端少。")
                        Text("3. 你可以在帖子菜单中举报并隐藏帖子，或举报并屏蔽用户。")
                        Text("4. 举报信息会异步提交给开发者进行处理。")
                        Text("5. 如需联系开发者，请使用邮箱：\(contactEmail)")
                    }
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text("继续使用话廊功能即表示你同意遵守以上规则。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .navigationTitle("社区规则")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("暂不进入", action: onDecline)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("同意并继续", action: onAccept)
                }
            }
        }
    }
}
