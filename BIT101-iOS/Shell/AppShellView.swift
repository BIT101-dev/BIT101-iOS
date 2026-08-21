//
//  AppShellView.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import SwiftUI
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
    private static let startupNoticeTitle = "1.7.2 版本更新"
    private static let startupNoticeBody = "优化使用体验"
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
    @State private var selectedTab: AppTab = .schedule
    @State private var isShowingGalleryEULA = false
    @State private var isShowingStartupNotice = false
    @State private var isShowingWidgetUsageGuide = false
    @State private var isShowingLinuxDoThanksNotice = false
    @State private var isShowingScheduleNotificationPrompt = false
    @State private var requestedScheduleSection: ScheduleSection?
    @State private var requestedPaperID: Int?
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
                        ScoreRootView()
                    case .map:
                        CampusMapScreen(scheduleViewModel: schoolDataRefresh.scheduleViewModel)
                    case .score:
                        ScoreRootView()
                    case .gallery:
                        GalleryRootView(requestedPaperID: $requestedPaperID)
                    case .paper:
                        GalleryRootView(requestedPaperID: $requestedPaperID)
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
        .alert(Self.startupNoticeTitle, isPresented: $isShowingStartupNotice) {
            Button("确定") {
                settings.markCurrentStartupNoticeSeen()
                presentWidgetUsageGuideIfNeeded()
            }
        } message: {
            Text(Self.startupNoticeBody)
        }
        .alert(Self.widgetUsageGuideTitle, isPresented: $isShowingWidgetUsageGuide) {
            Button("知道了") {
                settings.markCurrentWidgetUsageGuideSeen()
                refreshScheduleNotificationPromptIfNeeded()
            }
        } message: {
            Text(Self.widgetUsageGuideBody)
        }
        .alert(Self.linuxDoThanksTitle, isPresented: $isShowingLinuxDoThanksNotice) {
            Button("知道了") {
                settings.markLinuxDoThanksNoticeShown()
                refreshScheduleNotificationPromptIfNeeded()
            }
            Button("发送邮件") {
                settings.markLinuxDoThanksNoticeShown()
                if let url = URL(string: "mailto:systemd@linux.do") {
                    openURL(url)
                }
                refreshScheduleNotificationPromptIfNeeded()
            }
        } message: {
            Text(Self.linuxDoThanksBody)
        }
        .alert(item: $schoolDataRefresh.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("知道了"))
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
            if settings.shouldShowCurrentStartupNotice {
                isShowingStartupNotice = true
            } else if !settings.hasAcceptedCurrentWidgetUsageGuide {
                isShowingWidgetUsageGuide = true
            } else if settings.shouldShowLinuxDoThanksNotice {
                isShowingLinuxDoThanksNotice = true
            } else {
                refreshScheduleNotificationPromptIfNeeded()
            }
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
        .onOpenURL { url in
            handleIncomingURL(url)
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
    /// 当前仅接 `bit101://schedule/courses` 这一类深链，但集中收口到这里，后续继续扩展其它页面入口会更顺。
    private func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "bit101" else { return }

        let pathComponents = url.pathComponents.filter { $0 != "/" }
        let routeHead = url.host ?? pathComponents.first ?? ""

        if routeHead == "schedule" {
            selectedTab = .schedule
            let routeTail = url.host == nil ? pathComponents.dropFirst().first : pathComponents.first
            if routeTail == "courses" {
                requestedScheduleSection = .courses
            }
            return
        }

        if routeHead == "paper" {
            let rawID = url.host == nil ? pathComponents.dropFirst().first : pathComponents.first
            guard let rawID, let paperID = Int(rawID) else { return }
            selectedTab = .gallery
            requestedPaperID = paperID
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
            let shouldContinue = await MainActor.run { () -> Bool in
                if settings.shouldShowCurrentStartupNotice {
                    isShowingStartupNotice = true
                    return false
                }

                if !settings.hasAcceptedCurrentWidgetUsageGuide {
                    isShowingWidgetUsageGuide = true
                    return false
                }

                if settings.shouldShowLinuxDoThanksNotice {
                    isShowingLinuxDoThanksNotice = true
                    return false
                }

                return true
            }

            guard shouldContinue else { return }

            let authorizationState = await ScheduleLiveActivityManager.shared.notificationAuthorizationStateForReminderFallback()
            guard authorizationState == .denied else { return }

            await MainActor.run {
                presentScheduleNotificationPromptIfNeeded()
            }
        }
    }

    /// After the release note closes, continue the existing one-time prompt chain.
    private func presentWidgetUsageGuideIfNeeded() {
        if !settings.hasAcceptedCurrentWidgetUsageGuide {
            isShowingWidgetUsageGuide = true
        } else if settings.shouldShowLinuxDoThanksNotice {
            isShowingLinuxDoThanksNotice = true
        } else {
            refreshScheduleNotificationPromptIfNeeded()
        }
    }

    private func presentScheduleNotificationPromptIfNeeded(retryCount: Int = 4) {
        if isShowingScheduleNotificationPrompt {
            return
        }

        guard let rootViewController = topViewController() else {
            guard retryCount > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                presentScheduleNotificationPromptIfNeeded(retryCount: retryCount - 1)
            }
            return
        }

        if let currentAlert = rootViewController as? UIAlertController,
           currentAlert.title == "请开启通知" {
            isShowingScheduleNotificationPrompt = true
            return
        }

        if let presentedAlert = rootViewController.presentedViewController as? UIAlertController,
           presentedAlert.title == "请开启通知" {
            isShowingScheduleNotificationPrompt = true
            return
        }

        // 这里故意使用 UIKit 的 `UIAlertController`，而不是再叠一层 SwiftUI `.alert`。
        //
        // 原因是壳层本身已经承载了启动公告等弹窗；如果继续在同一层叠多个 SwiftUI alert，
        // 启动时很容易出现提示互相抢占、状态算出来了但界面没有真正弹出的情况。
        // 这属于当前项目里一处明确的“非原生 SwiftUI UI 实现”，保留它只是为了稳定性，
        // 后续若要回收这条绕路实现，优先方向应该是统一顶层弹窗路由，而不是直接删回 `.alert`。
        let alert = UIAlertController(
            title: "请开启通知",
            message: "灵动岛需要应用常驻前台；应用未能自动启动时，会使用本地通知，以避免您错过上课。请在系统设置的通知页面中允许 BIT101 发送通知。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
            isShowingScheduleNotificationPrompt = false
        })
        alert.addAction(UIAlertAction(title: "转到设置", style: .default) { _ in
            isShowingScheduleNotificationPrompt = false
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                openURL(url)
            } else if let fallbackURL = URL(string: UIApplication.openSettingsURLString) {
                openURL(fallbackURL)
            }
        })

        isShowingScheduleNotificationPrompt = true
        rootViewController.present(alert, animated: true)
    }

    private func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }

        let scene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first(where: { $0.activationState == .foregroundInactive })
            ?? scenes.first

        let root = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
            ?? scene?.windows.first(where: { !$0.isHidden && $0.rootViewController != nil })?.rootViewController
            ?? scene?.windows.first?.rootViewController
        return topViewController(from: root)
    }

    /// 从当前场景的根控制器向上追到真正可展示提示的最顶层控制器。
    ///
    /// 由于通知权限提示使用的是 UIKit alert，这里必须自己处理导航栈、Tab 容器和已呈现控制器，
    /// 否则很容易把提示挂到一个当前并不可见的控制器上，表现出来就像“没有弹窗”。
    private func topViewController(from viewController: UIViewController?) -> UIViewController? {
        if let navigationController = viewController as? UINavigationController {
            return topViewController(from: navigationController.visibleViewController)
        }
        if let tabBarController = viewController as? UITabBarController {
            return topViewController(from: tabBarController.selectedViewController)
        }
        if let presented = viewController?.presentedViewController {
            return topViewController(from: presented)
        }
        return viewController
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
