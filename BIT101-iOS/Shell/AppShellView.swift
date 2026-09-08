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
/// 底部导航使用固定顺序。
enum AppTab: String, Identifiable, Codable {
    case schedule
    case map
    case gallery
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
        case .map:
            return "地图"
        case .score:
            return "成绩"
        case .gallery:
            return "话廊"
        case .mine:
            return "我的"
        }
    }

    /// 底部栏对应的 SF Symbol。
    var systemImage: String {
        switch self {
        case .schedule:
            return "calendar"
        case .map:
            return "map"
        case .score:
            return "chart.bar.doc.horizontal"
        case .gallery:
            return "bubble.left.and.bubble.right"
        case .mine:
            return "person.crop.circle"
        }
    }

    /// 当前 tab 选中时使用的强调色。
    var tintColor: Color {
        switch self {
        case .schedule:
            return AppDesignSystem.Palette.scheduleTab
        case .map:
            return AppDesignSystem.Palette.mapTab
        case .score:
            return AppDesignSystem.Palette.scoreTab
        case .gallery:
            return AppDesignSystem.Palette.highlight
        case .mine:
            return AppDesignSystem.Palette.info
        }
    }
}

/// 登录后的应用壳层。
///
/// 壳层负责底部 tab、跨模块路由、全局提示和退出登录回调。
struct AppShellView: View {
    private static let startupNoticeTitle = "1.8.0 版本更新"
    private static let startupNoticeBody = """
    日程更好用：课程、待办、空教室和上课地点查看更清晰。
    查成绩更安心：登录、查成绩和成绩单查看更稳定，遇到问题时提示更明白。
    社区更顺手：发帖、评论、搜索、图片和个人主页体验更统一。
    多设备同步更及时：桌面小组件、Apple Watch 和灵动岛上的课表信息更可靠。
    另外还修复了一些问题，让页面加载和日常使用更流畅。
    """
    private static let linuxDoThanksTitle = "特别鸣谢 LINUX DO"
    private static let linuxDoThanksBody = "特别感谢 LINUX DO（L站）以及佬友们。这个 App 的诞生，离不开他们提供的免费 tokens 与无私的支持。L站倡导“真诚、友善、团结、专业，共建你我引以为荣之社区。”某种意义上，BIT101 也是在这样的氛围里，被一点点推出来的。\n\n如果你也想加入，可以向开发者发送邮件索要 L 站邀请码：systemd@linux.do"

    let studentID: String
    let onLogout: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var settings = AppSettingsStore.shared
    @ObservedObject private var schoolDataViewModels = SchoolDataViewModelStore.shared
    @ObservedObject private var promptCoordinator = AppPromptCoordinator.shared
    @State private var selectedTab: AppTab = .schedule
    @State private var requestedScheduleSection: ScheduleSection?
    @State private var requestedPaperID: Int?
    @State private var requestedPosterID: Int?
    @State private var requestedCourse: CourseNavigationRequest?
    @State private var requestedMapLocation: CampusMapLocationRequest?
    /// 系统全屏控制器关闭时壳层可能再次收到 `onAppear`；状态初始化按单次流程执行，当前 tab 保持不变。
    @State private var didInitializeSelectedTab = false

    /// 登录后的应用壳层主体。
    ///
    /// 这里负责：
    /// 1. 底部 tab 容器
    /// 2. 启动公告与运行时提示
    /// 3. 小组件和深链路由分发
    var body: some View {
        TabView(selection: tabSelection) {
            ForEach(AppTab.allCases) { tab in
                NavigationStack {
                    switch tab {
                    case .schedule:
                        ScheduleRootView(
                            requestedSection: $requestedScheduleSection,
                            onOpenAcademicCourse: { request in
                                selectTab(.score)
                                requestedCourse = request
                            },
                            onOpenCourseLocation: { request in
                                requestedMapLocation = request
                                selectTab(.map)
                            }
                        )
                    case .map:
                        CampusMapScreen(
                            scheduleViewModel: schoolDataViewModels.scheduleViewModel,
                            requestedLocation: requestedMapLocation
                        )
                    case .score:
                        ScoreRootView(requestedCourse: $requestedCourse)
                    case .gallery:
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
        .appSelectionFeedback(trigger: selectedTab.rawValue)
        .onAppear {
            if !didInitializeSelectedTab {
                didInitializeSelectedTab = true
                let initial = AppTab.allCases.first ?? .schedule
                if selectedTab != initial {
                    selectTab(initial)
                }
            }
            enqueueStartupPromptsIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            refreshScheduleNotificationPromptIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .scheduleCacheDidChange)) { _ in
            refreshScheduleNotificationPromptIfNeeded()
        }
        .onReceive(AppDeepLinkCoordinator.shared.$pendingURL.compactMap { $0 }) { url in
            handleIncomingURL(url)
            AppDeepLinkCoordinator.shared.consume(url)
        }
        .onReceive(schoolDataViewModels.scheduleViewModel.$notice.compactMap { $0 }) { notice in
            schoolDataViewModels.scheduleViewModel.notice = nil
            AppErrorPresenter.shared.present(notice)
        }
        .onReceive(schoolDataViewModels.scheduleViewModel.$pendingCourseReplacement.compactMap { $0 }) { pending in
            let scheduleViewModel = schoolDataViewModels.scheduleViewModel
            promptCoordinator.enqueue(AppPrompt(
                id: "course-replacement-\(pending.id.uuidString)",
                title: "确认替换课表",
                message: "本机有\(pending.existingCount)节课，获取到\(pending.incomingCount)节课，是否替换？",
                actions: [
                    AppPromptAction(id: "replace", title: "是", role: .destructive, isDefault: true) {
                        scheduleViewModel.resolvePendingCourseReplacement(replace: true)
                    },
                    AppPromptAction(id: "preserve", title: "否", role: .cancel) {
                        scheduleViewModel.resolvePendingCourseReplacement(replace: false)
                    }
                ],
                onDismiss: {
                    scheduleViewModel.resolvePendingCourseReplacement(replace: false)
                }
            ))
        }
    }

    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                selectTab(newTab)
            }
        )
    }

    private func selectTab(_ tab: AppTab) {
        selectedTab = tab
    }

    /// 处理来自小组件等入口的 app 深链。
    ///
    /// 同时接收 `bit101://` 内部链接和 `https://open.aihelpme.dev` Universal Link。
    private func handleIncomingURL(_ url: URL) {
        #if DEBUG || RELEASE_NETWORK_SMOKE
        if let smokeRequest = ReleaseNetworkSmokeLaunchRequest(url: url) {
            Task {
                _ = await ReleaseNetworkSmokeRunner().run(
                    scope: smokeRequest.scope,
                    runID: smokeRequest.runID
                )
            }
            return
        }

        #endif
        guard let route = AppDeepLinkRoute(url: url) else { return }

        switch route {
        case .scheduleCourses:
            selectTab(.schedule)
            requestedScheduleSection = .courses
        case let .paper(paperID):
            selectTab(.gallery)
            requestedPaperID = paperID
        case let .gallery(posterID):
            selectTab(.gallery)
            requestedPosterID = posterID
        case let .course(courseID):
            selectTab(.score)
            requestedCourse = CourseNavigationRequest(courseID: courseID)
        }
    }

    /// 统一刷新“灵动岛提醒的通知权限提示”状态。
    ///
    /// 这层检查由 `onAppear`、回前台和课表缓存变化共同触发：
    /// - 用户可以从系统设置修改通知权限后返回
    /// - 用户可以在课表设置里打开灵动岛提醒
    /// - 前后台切换会重新评估 fallback 能力
    ///
    /// 提示状态集中在这里处理，多个入口共享同一套判断。
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
