import Combine
import CommunityTransport
import CommunityUI
import CourseFeature
import DesignSystemKit
import GalleryFeature
import MapFeature
import MineFeature
import Observation
import ScheduleDomain
import ScheduleFeature
import ScoreDomain
import ScoreFeature
import ScorePorts
import StorageCore
import SwiftUI
import UIKit

/// 正式页面与性能验收共享账号能力的组合和视图更新路径。
struct AppAccountEnvironment: ViewModifier {
    let lifecycle: AppAccountLifecycle

    func body(content: Content) -> some View {
        content
            .environment(lifecycle.communityDestinations)
            .environment(lifecycle.community)
            .environment(lifecycle.communityDestinations.media)
            .environment(lifecycle.scheduleViewModel)
            .environment(lifecycle)
            .environment(lifecycle.scheduleViewModel.ddl)
            .environment(lifecycle.scoreViewModel)
            .environment(lifecycle.settings)
            .environment(lifecycle.preferenceCloudSync)
            .environment(lifecycle.prompts)
    }
}

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
    func makeUIView(context: Context) -> AppInterfaceOrientationView {
        AppInterfaceOrientationView()
    }
    func updateUIView(_ view: AppInterfaceOrientationView, context: Context) { view.updatePolicy() }
}

final class AppInterfaceOrientationView: UIView {
    private var supportedOrientations: UIInterfaceOrientationMask?
    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        registerForTraitChanges([
            UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self,
            UITraitUserInterfaceIdiom.self,
        ]) {
            (view: AppInterfaceOrientationView, _: UITraitCollection) in view.updatePolicy()
        }
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        supportedOrientations = nil
        updatePolicy()
    }
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
nonisolated enum AppTab: String, Identifiable, Codable, Sendable {
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
        .mine,
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
    @MainActor var tintColor: Color {
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

private nonisolated enum AppDestination: String, CaseIterable, Identifiable, Hashable, Sendable {
    case schedule, classroom, map, topics, papers, scores, courses, mine
    var id: String { rawValue }
    var title: String {
        switch self {
        case .schedule: "日程 / DDL"
        case .classroom: "空教室"
        case .map: "地图"
        case .topics: "话题"
        case .papers: "文章"
        case .scores: "成绩"
        case .courses: "课程"
        case .mine: "我的"
        }
    }
    var tab: AppTab {
        switch self {
        case .schedule, .classroom: .schedule
        case .map: .map
        case .topics, .papers: .gallery
        case .scores, .courses: .score
        case .mine: .mine
        }
    }
    var systemImage: String {
        switch self {
        case .classroom: "building.2"
        case .papers: "doc.text"
        case .courses: "books.vertical"
        default: tab.systemImage
        }
    }
    var accessibilityIdentifier: String {
        switch self {
        case .classroom, .papers, .courses: "app.tab.\(rawValue)"
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
    @State private var navigation = AppShellNavigation()
    @State private var mapPreparation = CampusMapPreparation()
    private var scoreSurface: ScoreSurface {
        get { navigation.scoreSurface }
        nonmutating set { navigation.scoreSurface = newValue }
    }
    private var gallerySurface: GallerySurface {
        get { navigation.gallerySurface }
        nonmutating set {
            if settings.galleryUseWebView {
                community.gallery.beginWebPresentation(for: newValue)
            }
            navigation.gallerySurface = newValue
        }
    }
    private var selectedTab: AppTab {
        get { navigation.selectedTab }
        nonmutating set {
            if newValue == .gallery, navigation.selectedTab != .gallery,
                settings.galleryUseWebView
            {
                community.gallery.beginWebPresentation(for: gallerySurface)
            }
            navigation.selectedTab = newValue
        }
    }
    private var scoreSelection: Binding<ScoreSurface> {
        let navigation = navigation
        return Binding(
            get: { navigation.scoreSurface },
            set: { navigation.scoreSurface = $0 })
    }
    private var gallerySelection: Binding<GallerySurface> {
        let navigation = navigation
        let settings = settings
        let gallery = community.gallery
        return Binding(
            get: { navigation.gallerySurface },
            set: { surface in
                if settings.galleryUseWebView { gallery.beginWebPresentation(for: surface) }
                navigation.gallerySurface = surface
            })
    }
    @Environment(AppCommunityDestinations.self) private var destinations
    private static let startupNoticeTitle = "\(AppSettingsStore.currentStartupNoticeVersion) 版本更新"
    private static let startupNoticeBody = """
        优化课表与空教室布局，改善横竖屏及分栏适配。
        修复学校短信验证中断后的恢复问题，优化成绩查询。
        扩大帖子点击范围，优化图片预览与评论操作。
        改进页面状态保留、缓存恢复和网络切换体验。
        """
    private static let linuxDoThanksTitle = "特别鸣谢 LINUX DO"
    static let linuxDoThanksBody =
        """
        特别感谢 LINUX DO（L站）以及佬友们。这个 App 的诞生，离不开他们提供的免费 tokens 与无私的支持。L站倡导“真诚、友善、团结、专业，共建你我引以为荣之社区\
        。”某种意义上，BIT101 也是在这样的氛围里，被一点点推出来的。
        """

    let transcriptService: any TrustedTranscriptServicing
    let studentID: String
    let onLogout: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppSettingsStore.self) private var settings: AppSettingsStore
    @Environment(ScheduleViewModel.self) private var scheduleViewModel: ScheduleViewModel
    @Environment(AppAccountLifecycle.self) private var lifecycle: AppAccountLifecycle
    @Environment(AppPromptCoordinator.self) private var promptCoordinator: AppPromptCoordinator
    #if DEBUG
    @State private var uiTestSettingsRoute: SettingsRoute? =
        AppFileDirectories.isRunningUITest
        ? AppUITestBootstrap.environment["BIT101_UI_TEST_SETTINGS"]
            .flatMap(SettingsRoute.init(rawValue:))
        : nil
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
    }

    private var mainTabs: some View {
        Group {
            if #available(iOS 18.0, *), usesExpandedNavigation { nativeTabs } else { compactTabs }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app.shell")
        .background { AppShellSelectionPresentation(navigation: navigation) }
        .background {
            ZStack {
                AppMapSurfaceView(
                    schedule: scheduleViewModel, requestedLocation: requestedMapLocation,
                    preparation: mapPreparation, isPreparing: true)
                if settings.galleryUseWebView {
                    GalleryWebPreparationHost(dependencies: community.gallery)
                }
                AppDesignSystem.Palette.Background.system
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .task(id: settings.galleryUseWebView, priority: .background) {
            if settings.galleryUseWebView {
                community.gallery.prepareWebContent(size: layout.size)
            } else {
                community.gallery.releasePreparedWebContent()
            }
        }
        .task(id: requestedCalendarRoute) {
            guard let route = requestedCalendarRoute,
                case .calendarEvent(let markerID, let term, let account) = route
            else { return }
            let identity = lifecycle.accountIdentity
            defer { if requestedCalendarRoute == route { requestedCalendarRoute = nil } }
            await scheduleViewModel.loadIfNeeded()
            guard !Task.isCancelled, requestedCalendarRoute == route,
                identity == lifecycle.accountIdentity,
                account == AppAccountSession.currentSession.accountStorageIdentifier
            else { return }
            scheduleViewModel.requestCalendarEntry(markerID: markerID, term: term)
        }
        .onAppear {
            #if DEBUG
            guard !AppFileDirectories.isRunningUITest else { return }
            #endif
            enqueueStartupPrompts()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else {
                notificationPromptTask?.cancel()
                return
            }
            refreshReminderPrompt()
        }
        .onDisappear {
            notificationPromptTask?.cancel()
            notificationPromptTask = nil
        }
        .onReceive(lifecycle.scheduleChanges) { session in
            guard session == lifecycle.currentSession() else { return }
            refreshReminderPrompt()
        }
        .onChange(of: AppDeepLinkCoordinator.shared.pendingURL, initial: true) { _, url in
            guard let url else { return }
            handleIncomingURL(url)
            AppDeepLinkCoordinator.shared.consume(url)
        }
        .diagnosticAlert(
            item: Binding(
                get: { scheduleViewModel.notice }, set: { _ in scheduleViewModel.dismissNotice() }))
    }

    private var usesExpandedNavigation: Bool {
        if #available(iOS 18.0, *) { layout.usesExpandedNavigation } else { false }
    }

    @available(iOS 18.0, *) private var nativeTabs: some View {
        AppExpandedTabs(selection: { destinationSelection }) { destination in
            destinationContent(destination)
                .tint(destination.tab.tintColor)
                .appNativeTabBarBackground(isPresented: layout.usesOpaqueNavigation)
                .modifier(
                    AppShellPageVisibility {
                        destination == destinationSelection.wrappedValue
                    })
        }
    }

    private var compactTabs: some View {
        AppCompactTabs(
            selection: { selectedTab }, onSelect: { selectedTab = $0 }
        ) { tab in
            tabItemView(for: tab)
        }
    }

    @ViewBuilder
    private func tabItemView(for tab: AppTab) -> some View {
        Group {
            if tab == .schedule || tab == .gallery || tab == .score || tab == .mine {
                tabContent(tab)
            } else {
                NavigationStack { tabContent(tab) }
            }
        }
        .modifier(AppShellPageVisibility { tab == selectedTab })
        .tint(tab.tintColor)
        .appNativeTabBarBackground(isPresented: layout.usesOpaqueNavigation)
        .tag(tab)
        .tabItem {
            Label(tab.title, systemImage: tab.systemImage)
                .accessibilityIdentifier("app.tab.\(tab.rawValue)")
        }
    }

    private func destinationContent(_ destination: AppDestination) -> AnyView {
        switch destination {
        case .topics: AnyView(galleryContent(includesPaperSurface: false))
        case .papers:
            AnyView(
                paperContent
                    .appBrowserHeader(isPresented: !usesExpandedNavigation) {
                        GallerySurfacePicker(selection: gallerySelection)
                    })
        case .schedule, .classroom:
            AnyView(scheduleContent(showingClassrooms: destination == .classroom))
        case .scores, .courses:
            AnyView(
                AppScoreSurfaceView(
                    courses: community.course, transcriptService: transcriptService,
                    requestedCourse: $requestedCourse,
                    selection: scoreSelection, showingCourses: destination == .courses))
        case .mine: tabContent(.mine)
        default:
            AnyView(NavigationStack { tabContent(destination.tab) })
        }
    }

    private func tabContent(_ tab: AppTab) -> AnyView {
        switch tab {
        case .schedule:
            AnyView(scheduleContent())
        case .map:
            AnyView(
                AppMapSurfaceView(
                    schedule: scheduleViewModel, requestedLocation: requestedMapLocation,
                    preparation: mapPreparation))
        case .score:
            AnyView(
                AppScoreSurfaceView(
                    courses: community.course, transcriptService: transcriptService,
                    requestedCourse: $requestedCourse, selection: scoreSelection))
        case .gallery:
            AnyView(galleryContent())
        case .mine:
            AnyView(
                MineRootView(
                    dependencies: community.mine, media: destinations.media,
                    posters: destinations.posters,
                    settings: destinations.settings, fallbackStudentID: studentID,
                    onLogout: onLogout,
                    requestedSettings: requestedMineSettings))
        }
    }

    private var requestedMineSettings: Binding<CommunitySettingsEntry?> {
        #if DEBUG
        guard AppFileDirectories.isRunningUITest else { return .constant(nil) }
        return Binding(
            get: {
                uiTestSettingsRoute.flatMap { route in
                    destinations.settings.settingsEntries.first { $0.id == route.rawValue }
                }
            }, set: { uiTestSettingsRoute = $0.flatMap { SettingsRoute(rawValue: $0.id) } })
        #else
        .constant(nil)
        #endif
    }

    private func scheduleContent(showingClassrooms: Bool? = nil) -> some View {
        AppScheduleSurfaceView(
            viewModel: scheduleViewModel, courses: community.course, navigation: navigation,
            requestedSection: $requestedScheduleSection, requestedCourse: $requestedCourse,
            requestedMapLocation: $requestedMapLocation, showingClassrooms: showingClassrooms
        )
        .equatable()
    }

    private func galleryContent(includesPaperSurface: Bool = true) -> some View {
        GalleryRootView(
            dependencies: community.gallery, media: destinations.media,
            profiles: destinations.profiles, papers: destinations.papers,
            courses: destinations.courses,
            requestedPaperID: includesPaperSurface ? $requestedPaperID : .constant(nil),
            requestedPosterID: $requestedPosterID, selection: gallerySelection,
            includesPaperSurface: includesPaperSurface)
    }

    @ViewBuilder private var paperContent: some View {
        if settings.galleryUseWebView {
            GalleryWebContentView(
                dependencies: community.gallery, surface: .paper,
                requestedPaperID: $requestedPaperID)
        } else {
            destinations.papers.papers($requestedPaperID, { gallerySurface = .gallery })
        }
    }

    private var destinationSelection: Binding<AppDestination> {
        Binding(
            get: {
                switch selectedTab {
                case .schedule:
                    switch scheduleViewModel.selectedSection {
                    case .courses, .ddl: .schedule
                    case .classroom: .classroom
                    }
                case .map: .map
                case .gallery: gallerySurface == .gallery ? .topics : .papers
                case .score: scoreSurface == .score ? .scores : .courses
                case .mine: .mine
                }
            },
            set: { destination in
                switch destination {
                case .schedule, .classroom:
                    if destination == .classroom {
                        scheduleViewModel.selectedSection = .classroom
                    } else if scheduleViewModel.selectedSection == .classroom {
                        scheduleViewModel.selectedSection = .courses
                    }
                    selectedTab = .schedule
                case .map: selectedTab = .map
                case .topics, .papers:
                    gallerySurface = destination == .topics ? .gallery : .paper
                    selectedTab = .gallery
                case .scores, .courses:
                    scoreSurface = destination == .scores ? .score : .course
                    selectedTab = .score
                case .mine: selectedTab = .mine
                }
            })
    }

    /// 处理来自小组件等入口的 app 深链。
    ///
    /// 同时接收 `bit101://` 内部链接和 `https://open.aihelpme.dev` Universal Link。
    private func handleIncomingURL(_ url: URL) {
        guard let route = AppDeepLinkRoute(url: url) else { return }
        requestedCalendarRoute = nil

        switch route {
        case .scheduleCourses:
            selectedTab = .schedule
            requestedScheduleSection = .courses
        case .scheduleDDL:
            selectedTab = .schedule
            requestedScheduleSection = .ddl
        case .paper(let paperID):
            gallerySurface = .paper
            selectedTab = .gallery
            requestedPaperID = paperID
        case .gallery(let posterID):
            gallerySurface = .gallery
            selectedTab = .gallery
            requestedPosterID = posterID
        case .course(let courseID):
            scoreSurface = .course
            selectedTab = .score
            requestedCourse = CourseNavigationRequest(courseID: courseID)
        case .calendarEvent(_, _, let account):
            selectedTab = .schedule
            guard account == AppAccountSession.currentSession.accountStorageIdentifier else {
                AppErrorPresenter.shared.present(
                    AppAlert(title: "日历事件账号", message: "请切换到创建该事件的账号后查看。"))
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
    private func refreshReminderPrompt() {
        #if DEBUG
        guard !AppFileDirectories.isRunningUITest else { return }
        #endif
        notificationPromptTask?.cancel()
        notificationPromptTask = Task {
            guard let owner = await lifecycle.reminderPromptAccount(),
                !Task.isCancelled, owner == lifecycle.accountIdentity
            else { return }
            enqueueReminderPrompt(account: owner)
        }
    }

    private func enqueueStartupPrompts() {
        guard !didEnqueueStartupPrompts else {
            refreshReminderPrompt()
            return
        }
        didEnqueueStartupPrompts = true

        if settings.shouldShowCurrentStartupNotice {
            promptCoordinator.enqueue(
                AppPrompt(
                    id: "startup-notice-\(Self.startupNoticeTitle)",
                    title: Self.startupNoticeTitle,
                    message: Self.startupNoticeBody,
                    actions: [
                        AppPromptAction(id: "confirm", title: "确定", isDefault: true) {
                            settings.markStartupNoticeSeen()
                        }
                    ]
                ))
        }

        if settings.shouldShowLinuxDoThanksNotice {
            let account = lifecycle.accountIdentity
            let session = lifecycle.currentSession()
            promptCoordinator.enqueue(
                AppPrompt(
                    id: "linux-do-thanks",
                    title: Self.linuxDoThanksTitle,
                    message: Self.linuxDoThanksBody,
                    actions: [
                        AppPromptAction(id: "dismiss", title: "知道了", isDefault: true) {
                            settings.markThanksNoticeShown(for: session)
                        }
                    ],
                    account: account
                ))
        }

        refreshReminderPrompt()
    }

    private func enqueueReminderPrompt(account: CommunitySessionIdentity) {
        promptCoordinator.enqueue(
            AppPrompt(
                id: "schedule-notification-permission",
                title: "请开启通知",
                message: "灵动岛提醒无法自动启动时，应用会发送本地通知。请在系统设置中允许 BIT101 发送通知。",
                actions: [
                    AppPromptAction(id: "cancel", title: "取消", role: .cancel) {},
                    AppPromptAction(id: "open-settings", title: "转到设置", isDefault: true) {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            openURL(url)
                        } else if let fallbackURL = URL(string: UIApplication.openSettingsURLString)
                        {
                            openURL(fallbackURL)
                        }
                    },
                ],
                account: account
            ))
    }
}

/// 选择绑定在容器内部创建，让选择变化只更新 Tab 内容。
@available(iOS 18.0, *)
private struct AppExpandedTabs<Content: View>: View {
    let selection: () -> Binding<AppDestination>
    let content: (AppDestination) -> Content

    var body: some View {
        TabView(selection: selection()) {
            ForEach(AppDestination.allCases) { destination in
                Tab(value: destination) {
                    content(destination)
                } label: {
                    Label(destination.title, systemImage: destination.systemImage)
                        .accessibilityIdentifier(destination.accessibilityIdentifier)
                }
                .accessibilityIdentifier(destination.accessibilityIdentifier)
            }
        }
        .accessibilityIdentifier("app.navigation.adaptive")
    }
}

private struct AppCompactTabs<Content: View>: View {
    let selection: () -> AppTab
    let onSelect: (AppTab) -> Void
    let content: (AppTab) -> Content

    var body: some View {
        TabView(selection: Binding(get: { selection() }, set: { onSelect($0) })) {
            ForEach(AppTab.allCases) { tab in content(tab) }
        }
        .tint(selection().tintColor)
        .accessibilityIdentifier("app.navigation.grouped")
    }
}

private struct AppScheduleSurfaceView: View, Equatable {
    let viewModel: ScheduleViewModel
    let courses: CourseDependencies
    let navigation: AppShellNavigation
    @Binding var requestedSection: ScheduleSection?
    @Binding var requestedCourse: CourseNavigationRequest?
    @Binding var requestedMapLocation: CampusMapLocationRequest?
    let showingClassrooms: Bool?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.viewModel === rhs.viewModel && lhs.courses === rhs.courses
            && lhs.navigation === rhs.navigation && lhs.showingClassrooms == rhs.showingClassrooms
            && lhs.requestedSection == rhs.requestedSection
    }

    var body: some View {
        ScheduleRootView(
            viewModel: viewModel, requestedSection: $requestedSection,
            destinations: .appDestinations(
                courses: courses,
                onOpenAcademicCourse: { request in
                    navigation.scoreSurface = .course
                    navigation.selectedTab = .score
                    requestedCourse = request
                },
                onOpenCourseLocation: { request in
                    requestedMapLocation = request
                    navigation.selectedTab = .map
                }), showingClassrooms: showingClassrooms)
    }
}

@MainActor
@Observable
private final class AppShellNavigation {
    var scoreSurface: ScoreSurface = .score
    var gallerySurface: GallerySurface = .gallery
    #if DEBUG
    var selectedTab: AppTab = {
        guard AppFileDirectories.isRunningUITest else { return .schedule }
        return AppUITestBootstrap.environment["BIT101_UI_TEST_SETTINGS"] == nil
            ? AppTab(rawValue: AppUITestBootstrap.environment["BIT101_UI_TEST_TAB"] ?? "schedule")
                ?? .schedule : .mine
    }()
    #else
    var selectedTab: AppTab = .schedule
    #endif
}

private struct AppShellPageVisibility: ViewModifier {
    let isVisible: () -> Bool
    func body(content: Content) -> some View {
        content.environment(\.appPageIsVisible, isVisible())
    }
}

private struct AppShellSelectionPresentation: View {
    @Environment(\.appInteractionEvidence) private var interactionEvidence
    let navigation: AppShellNavigation
    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .appSelectionFeedback(trigger: navigation.selectedTab.rawValue)
            .onChange(of: navigation.selectedTab) { _, _ in
                interactionEvidence?("app.shell", "tab-switch")
                interactionEvidence?("app.navigation.adaptive", "tab-switch")
                interactionEvidence?("app.navigation.grouped", "tab-switch")
            }
    }
}

private struct AppMapSurfaceView: View {
    let schedule: ScheduleViewModel
    let requestedLocation: CampusMapLocationRequest?
    let preparation: CampusMapPreparation
    var isPreparing = false
    @State private var courseTarget = UpcomingCourseMapProjection()

    var body: some View {
        Group {
            if isPreparing {
                CampusMapPreparationHost(
                    preparation: preparation,
                    nextCourseTarget: courseTarget.resolve(
                        in: schedule.courseSnapshot, now: Date())
                )
                .ignoresSafeArea(edges: [.top, .bottom])
            } else {
                TimelineView(.everyMinute) { context in
                    CampusMapScreen(
                        nextCourseTarget: courseTarget.resolve(
                            in: schedule.courseSnapshot, now: context.date),
                        requestedLocation: requestedLocation,
                        preparation: preparation)
                }
            }
        }
        .task { await schedule.loadIfNeeded() }
    }
}
