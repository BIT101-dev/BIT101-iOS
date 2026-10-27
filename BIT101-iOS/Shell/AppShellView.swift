import ScoreDomain
import ScorePorts
import MineFeature
import GalleryFeature
import CourseFeature
import ScoreFeature
import ScheduleFeature
import MapFeature
import ScheduleDomain
import StorageCore
import DesignSystemKit
//
//  AppShellView.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import SwiftUI
import Combine
import CommunityTransport
import CommunityUI
import UIKit

enum AppInterfaceOrientationPolicy {
    static func supportedOrientations(for traits: UITraitCollection) -> UIInterfaceOrientationMask {
        if traits.userInterfaceIdiom == .phone {
            return traits.horizontalSizeClass == .regular && traits.verticalSizeClass == .regular
                ? .allButUpsideDown : .portrait
        }
        return .all
    }
}

struct AppInterfaceOrientationObserver: UIViewRepresentable {
    func makeUIView(context: Context) -> AppInterfaceOrientationView { AppInterfaceOrientationView() }
    func updateUIView(_ view: AppInterfaceOrientationView, context: Context) { view.updatePolicy() }
}

final class AppInterfaceOrientationView: UIView {
    private var supportedOrientations: UIInterfaceOrientationMask?
    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self, UITraitUserInterfaceIdiom.self]) {
            (view: AppInterfaceOrientationView, _: UITraitCollection) in view.updatePolicy()
        }
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    override func didMoveToWindow() { super.didMoveToWindow(); supportedOrientations = nil; updatePolicy() }
    func updatePolicy() {
        guard let window, let scene = window.windowScene else { return }
        let mask = AppInterfaceOrientationPolicy.supportedOrientations(for: scene.traitCollection)
        guard supportedOrientations != mask else { return }
        supportedOrientations = mask
        window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        if mask == .portrait && scene.effectiveGeometry.interfaceOrientation.isLandscape {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        }
    }
}

/// 应用主导航的稳定分组标识。
///
/// 主入口使用固定顺序。
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

    /// 主入口展示的标题。
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

    /// 主入口对应的 SF Symbol。
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
            return AppDesignSystem.Schedule.tabAccent
        case .map:
            return AppDesignSystem.Map.tabAccent
        case .score:
            return AppDesignSystem.Course.accent
        case .gallery:
            return AppDesignSystem.Gallery.tabAccent
        case .mine:
            return AppDesignSystem.Palette.Status.info
        }
    }
}

private enum AppDestination: String, CaseIterable, Identifiable, Hashable {
    case schedule, classroom, map, topics, papers, academics, mine
    var id: String { rawValue }
    var title: String {
        switch self {
        case .schedule: "日程 / DDL"
        case .classroom: "空教室"
        case .map: "地图"
        case .topics: "话题"
        case .papers: "文章"
        case .academics: "成绩 / 课程"
        case .mine: "我的"
        }
    }
    var tab: AppTab {
        switch self {
        case .schedule, .classroom: .schedule
        case .map: .map
        case .topics, .papers: .gallery
        case .academics: .score
        case .mine: .mine
        }
    }
    var systemImage: String {
        switch self {
        case .classroom: "building.2"
        case .papers: "doc.text"
        default: tab.systemImage
        }
    }
    var accessibilityIdentifier: String {
        switch self {
        case .classroom, .papers: "app.tab.\(rawValue)"
        default: "app.tab.\(tab.rawValue)"
        }
    }
}

/// 登录后的应用壳层。
///
/// 壳层负责原生 Tab、跨模块路由、全局提示和退出登录回调。
struct AppShellView: View {
    @Environment(AppCommunityDependencies.self) private var community
    @Environment(\.appWindowLayout) private var layout
    @State private var scoreSurface: ScoreSurface = .score
    @State private var gallerySurface: GallerySurface = .gallery
    @Environment(AppCommunityDestinations.self) private var destinations
    private static let startupNoticeTitle = "\(AppSettingsStore.currentStartupNoticeVersion) 版本更新"
    private static let startupNoticeBody = """
    优化学校服务认证与成绩查询。
    优化课表缓存恢复、刷新与显示。
    DDL 支持跳转学校网页，文章保留排序和浏览位置。
    优化界面样式与操作体验。
    """
    private static let linuxDoThanksTitle = "特别鸣谢 LINUX DO"
    private static let linuxDoThanksBody = "特别感谢 LINUX DO（L站）以及佬友们。这个 App 的诞生，离不开他们提供的免费 tokens 与无私的支持。L站倡导“真诚、友善、团结、专业，共建你我引以为荣之社区。”某种意义上，BIT101 也是在这样的氛围里，被一点点推出来的。"

    let transcriptService: any TrustedTranscriptServicing
    let studentID: String
    let onLogout: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.appInteractionEvidence) private var interactionEvidence
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var scheduleViewModel: ScheduleViewModel
    @EnvironmentObject private var lifecycle: AppAccountLifecycle
    @EnvironmentObject private var promptCoordinator: AppPromptCoordinator
#if BIT101_UI_TESTING
    @State private var selectedTab: AppTab = AppUITestBootstrap.environment["BIT101_UI_TEST_SETTINGS"] == nil
        ? AppTab(rawValue: AppUITestBootstrap.environment["BIT101_UI_TEST_TAB"] ?? "schedule") ?? .schedule : .mine
    @State private var uiTestSettingsRoute = AppUITestBootstrap.environment["BIT101_UI_TEST_SETTINGS"].flatMap(SettingsRoute.init(rawValue:))
#else
    @State private var selectedTab: AppTab = .schedule
#endif
    @State private var requestedScheduleSection: ScheduleSection?
    @State private var requestedCalendarRoute: AppDeepLinkRoute?
    @State private var requestedPaperID: Int?
    @State private var requestedPosterID: Int?
    @State private var requestedCourse: CourseNavigationRequest?
    @State private var requestedMapLocation: CampusMapLocationRequest?
    @State private var didEnqueueStartupPrompts = false
    @State private var notificationPromptTask: Task<Void, Never>?

    /// 登录后的应用壳层主体。
    ///
    /// 这里负责：
    /// 1. 原生 Tab 容器
    /// 2. 启动公告与运行时提示
    /// 3. 小组件和深链路由分发
    var body: some View {
        mainTabs
            .environment(\.appExpandedNavigation, usesExpandedNavigation)
            .tint(selectedTab.tintColor)
            .appScrollEdgeEffectHidden(layout.isLandscape)
    }

    private var mainTabs: some View {
        Group {
            if #available(iOS 18.0, *) { nativeTabs }
            else { compactTabs }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app.shell")
        .appSelectionFeedback(trigger: selectedTab.rawValue)
        .task(id: requestedCalendarRoute) {
            guard let route = requestedCalendarRoute,
                  case let .calendarEvent(markerID, term, account) = route else { return }
            let identity = lifecycle.accountIdentity
            defer { if requestedCalendarRoute == route { requestedCalendarRoute = nil } }
            await scheduleViewModel.loadIfNeeded()
            guard !Task.isCancelled, requestedCalendarRoute == route,
                  identity == lifecycle.accountIdentity,
                  account == AppAccountSession.currentSession.accountStorageIdentifier else { return }
            scheduleViewModel.requestSystemCalendarEntry(markerID: markerID, term: term)
        }
        .onChange(of: selectedTab) { _, _ in
            interactionEvidence?("app.shell", "tab-switch")
        }
        .onAppear {
#if BIT101_UI_TESTING
            guard !AppFileDirectories.isRunningUITest else { return }
#endif
            enqueueStartupPromptsIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { notificationPromptTask?.cancel(); return }
            refreshScheduleNotificationPromptIfNeeded()
        }
        .onDisappear {
            notificationPromptTask?.cancel()
            notificationPromptTask = nil
        }
        .onReceive(lifecycle.scheduleChanges) { session in
            guard session == lifecycle.currentSession() else { return }
            refreshScheduleNotificationPromptIfNeeded()
        }
        .onReceive(AppDeepLinkCoordinator.shared.$pendingURL.compactMap { $0 }) { url in
            handleIncomingURL(url)
            AppDeepLinkCoordinator.shared.consume(url)
        }
        .onReceive(scheduleViewModel.$notice.compactMap { $0 }) { notice in
            scheduleViewModel.dismissNotice()
            AppErrorPresenter.shared.present(notice)
        }
    }

    private var usesExpandedNavigation: Bool {
        if #available(iOS 18.0, *) { layout.usesExpandedNavigation }
        else { false }
    }

    @available(iOS 18.0, *) private var nativeTabs: some View {
        TabView(selection: destinationSelection) {
            ForEach(AppDestination.allCases) { destination in
                Tab(value: destination) {
                    destinationContent(destination)
                        .environment(\.appPageIsVisible, destination == destinationSelection.wrappedValue)
                } label: {
                    Label(usesExpandedNavigation ? destination.title : destination.tab.title,
                        systemImage: destination.systemImage)
                }
                .accessibilityIdentifier(destination.accessibilityIdentifier)
                .hidden(isHidden(destination))
            }
        }
        .accessibilityIdentifier("app.navigation.adaptive")
    }

    private var compactTabs: some View {
        TabView(selection: tabSelection) {
            ForEach(AppTab.allCases) { tab in
                Group {
                    if tab == .gallery { tabContent(tab) }
                    else { NavigationStack { tabContent(tab) } }
                }
                .environment(\.appPageIsVisible, tab == selectedTab)
                .tag(tab)
                .tabItem {
                    Label(tab.title, systemImage: tab.systemImage)
                        .accessibilityIdentifier("app.tab.\(tab.rawValue)")
                }
            }
        }
        .accessibilityIdentifier("app.navigation.grouped")
    }

    private func isHidden(_ destination: AppDestination) -> Bool {
        guard !usesExpandedNavigation else { return false }
        switch destination {
        case .schedule: return scheduleViewModel.selectedSection == .classroom
        case .classroom: return scheduleViewModel.selectedSection != .classroom
        case .topics: return gallerySurface == .paper
        case .papers: return gallerySurface != .paper
        default: return false
        }
    }

    @ViewBuilder private func destinationContent(_ destination: AppDestination) -> some View {
        switch destination {
        case .topics: galleryContent(includesPaperSurface: false)
        case .papers:
            VStack(spacing: AppDesignSystem.Spacing.none) {
                if !usesExpandedNavigation { GallerySurfacePicker(selection: $gallerySurface) }
                destinations.papers.papers($requestedPaperID, { gallerySurface = .gallery })
            }
        case .schedule, .classroom:
            NavigationStack { scheduleContent(showingClassrooms: destination == .classroom) }
        default:
            NavigationStack { tabContent(destination.tab) }
        }
    }

    @ViewBuilder private func tabContent(_ tab: AppTab) -> some View {
        switch tab {
        case .schedule:
            scheduleContent()
        case .map:
            TimelineView(.everyMinute) { context in
                CampusMapScreen(
                    nextCourseTarget: UpcomingCourseMapResolver.nextTarget(in: scheduleViewModel.courseSnapshot, now: context.date),
                    requestedLocation: requestedMapLocation
                )
            }
            .task { await scheduleViewModel.loadIfNeeded() }
        case .score:
            ScoreRootView(courses: community.course, transcriptService: transcriptService, requestedCourse: $requestedCourse, selection: $scoreSurface)
        case .gallery:
            galleryContent()
        case .mine:
            MineRootView(dependencies: community.mine, media: destinations.media, posters: destinations.posters, settings: destinations.settings, fallbackStudentID: studentID, onLogout: onLogout)
#if BIT101_UI_TESTING
                .navigationDestination(item: $uiTestSettingsRoute) { route in
                    SettingsRootView(initialRoute: route, studentID: studentID, onLogout: onLogout,
                                     dependencies: destinations.settingsDependencies)
                }
#endif
        }
    }

    private func scheduleContent(showingClassrooms: Bool? = nil) -> some View {
        ScheduleRootView(viewModel: scheduleViewModel, requestedSection: $requestedScheduleSection,
            destinations: .appDestinations(courses: community.course, onOpenAcademicCourse: { request in
                selectTab(.score); requestedCourse = request
            }, onOpenCourseLocation: { request in
                requestedMapLocation = request; selectTab(.map)
            }), showingClassrooms: showingClassrooms)
    }

    private func galleryContent(includesPaperSurface: Bool = true) -> some View {
        GalleryRootView(dependencies: community.gallery, media: destinations.media,
            profiles: destinations.profiles, papers: destinations.papers, courses: destinations.courses,
            requestedPaperID: includesPaperSurface ? $requestedPaperID : .constant(nil),
            requestedPosterID: $requestedPosterID, selection: $gallerySurface, includesPaperSurface: includesPaperSurface)
    }

    private var destinationSelection: Binding<AppDestination> {
        Binding(get: {
            switch selectedTab {
            case .schedule:
                switch scheduleViewModel.selectedSection {
                case .courses, .ddl: .schedule
                case .classroom: .classroom
                }
            case .map: .map
            case .gallery: gallerySurface == .gallery ? .topics : .papers
            case .score: .academics
            case .mine: .mine
            }
        }, set: { destination in
            switch destination {
            case .schedule, .classroom:
                if destination == .classroom { scheduleViewModel.selectedSection = .classroom }
                else if scheduleViewModel.selectedSection == .classroom { scheduleViewModel.selectedSection = .courses }
                selectTab(.schedule)
            case .map: selectTab(.map)
            case .topics, .papers:
                gallerySurface = destination == .topics ? .gallery : .paper
                selectTab(.gallery)
            case .academics: selectTab(.score)
            case .mine: selectTab(.mine)
            }
        })
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
        guard let route = AppDeepLinkRoute(url: url) else { return }
        requestedCalendarRoute = nil

        switch route {
        case .scheduleCourses:
            selectTab(.schedule)
            requestedScheduleSection = .courses
        case .scheduleDDL:
            selectTab(.schedule)
            requestedScheduleSection = .ddl
        case let .paper(paperID):
            gallerySurface = .paper
            selectTab(.gallery)
            requestedPaperID = paperID
        case let .gallery(posterID):
            gallerySurface = .gallery
            selectTab(.gallery)
            requestedPosterID = posterID
        case let .course(courseID):
            selectTab(.score)
            requestedCourse = CourseNavigationRequest(courseID: courseID)
        case let .calendarEvent(_, _, account):
            selectTab(.schedule)
            guard account == AppAccountSession.currentSession.accountStorageIdentifier else {
                AppErrorPresenter.shared.present(AppAlert(title: "日历事件账号", message: "请切换到创建该事件的账号后查看。"))
                return
            }
            requestedScheduleSection = nil
            requestedCalendarRoute = route
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
#if BIT101_UI_TESTING
        guard !AppFileDirectories.isRunningUITest else { return }
#endif
        notificationPromptTask?.cancel()
        notificationPromptTask = Task {
            guard let owner = await lifecycle.scheduleNotificationPromptAccount(),
                  !Task.isCancelled, owner == lifecycle.accountIdentity else { return }
            enqueueScheduleNotificationPrompt(account: owner)
        }
    }

    private func enqueueStartupPromptsIfNeeded() {
        guard !didEnqueueStartupPrompts else {
            refreshScheduleNotificationPromptIfNeeded()
            return
        }
        didEnqueueStartupPrompts = true

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
            let account = lifecycle.accountIdentity
            let session = lifecycle.currentSession()
            promptCoordinator.enqueue(AppPrompt(
                id: "linux-do-thanks",
                title: Self.linuxDoThanksTitle,
                message: Self.linuxDoThanksBody,
                actions: [
                    AppPromptAction(id: "dismiss", title: "知道了", isDefault: true) {
                        settings.markLinuxDoThanksNoticeShown(for: session)
                    }
                ],
                account: account
            ))
        }

        refreshScheduleNotificationPromptIfNeeded()
    }

    private func enqueueScheduleNotificationPrompt(account: CommunitySessionIdentity) {
        promptCoordinator.enqueue(AppPrompt(
            id: "schedule-notification-permission",
            title: "请开启通知",
            message: "当灵动岛提醒无法自动启动时，应用会使用本地通知，以避免您错过上课。请在系统设置的通知页面中允许 BIT101 发送通知。",
            actions: [
                AppPromptAction(id: "cancel", title: "取消", role: .cancel) {},
                AppPromptAction(id: "open-settings", title: "转到设置", isDefault: true) {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        openURL(url)
                    } else if let fallbackURL = URL(string: UIApplication.openSettingsURLString) {
                        openURL(fallbackURL)
                    }
                }
            ],
            account: account
        ))
    }
}
