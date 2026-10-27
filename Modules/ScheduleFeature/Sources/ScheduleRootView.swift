#if os(iOS)
import ClientCore
import DesignSystemKit
//
//  ScheduleRootView.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import SwiftUI

private struct ScheduleCurrentDateKey: EnvironmentKey {
    static var defaultValue: Date { .now }
}

extension EnvironmentValues {
    var scheduleCurrentDate: Date {
        get { self[ScheduleCurrentDateKey.self] }
        set { self[ScheduleCurrentDateKey.self] = newValue }
    }
}

// MARK: - Schedule Root

/// 日程页根视图。
///
/// 竖屏沿顶部公共 segmented 切换分区，横屏并排呈现课表与 DDL。
/// 页面正文保持独立布局，底部玻璃效果稳定，轻扫切换继续可用。
public struct ScheduleRootView: View {
    @Environment(\.appExpandedNavigation) private var expandedNavigation
    @Environment(\.appPageIsVisible) private var isPageVisible
    @Environment(\.appWindowLayout) private var layout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 壳层深链请求的目标分栏，例如从小组件点进来直接落到课表。
    @Binding var requestedSection: ScheduleSection?
    let destinations: ScheduleDestinations
    private let showingClassrooms: Bool?
    private var displayedSection: ScheduleSection {
        guard let showingClassrooms else { return viewModel.selectedSection }
        if showingClassrooms { return .classroom }
        return viewModel.selectedSection == .ddl ? .ddl : .courses
    }
    private var isCurrentSectionVisible: Bool {
        isPageVisible && displayedSection == viewModel.selectedSection
    }
    @ObservedObject private var viewModel: ScheduleViewModel
    @State private var courseTabResetSignal = 0
    @State private var horizontalControlFrames: [CGRect] = []

    public init(viewModel: ScheduleViewModel, requestedSection: Binding<ScheduleSection?>, destinations: ScheduleDestinations,
        showingClassrooms: Bool? = nil) {
        self.viewModel = viewModel
        _requestedSection = requestedSection
        self.destinations = destinations
        self.showingClassrooms = showingClassrooms
    }

    /// 日程主页主体。
    public var body: some View {
        TimelineView(.everyMinute) { context in
            content.environment(\.scheduleCurrentDate, context.date)
        }
    }

    private var content: some View {
        GeometryReader { proxy in
            ZStack {
                if displayedSection == .classroom { FreeClassroomTabView(viewModel: viewModel.classroom) }
                else {
                    AppPairedPages(showsFirst: displayedSection == .courses) {
                        CourseScheduleTabView(viewModel: viewModel, resetSignal: courseTabResetSignal, destinations: destinations)
                    } second: { DDLScheduleTabView(viewModel: viewModel.ddl) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .onPreferenceChange(AppHorizontalControlFramesKey.self) { horizontalControlFrames = $0 }
            .simultaneousGesture(
                sectionSwitchGesture(
                    topDisabledY: proxy.frame(in: .global).minY + (viewModel.selectedSection == .courses
                        ? proxy.size.height * 0.25
                        : 0)
                )
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("schedule.section-surface")
        }
        .background(AppDesignSystem.Palette.Background.grouped)
        // 与成绩、话廊共用同一套 safeAreaInset 结构。列表内容从顶部切换栏之后开始，
        // 日程分栏保持单层 VStack 间距。
        .safeAreaInset(edge: .top, spacing: AppDesignSystem.Spacing.none) {
            if !expandedNavigation {
                if layout.isLandscape {
                    AppSegmentedPicker(title: "日程分区",
                        selection: Binding(get: { viewModel.selectedSection == .classroom },
                            set: { viewModel.selectedSection = $0 ? .classroom : .courses })) {
                        Text("课表与 DDL").tag(false); Text("空教室").tag(true)
                    }
                    .padding(.horizontal, AppDesignSystem.Spacing.section)
                    .padding(.vertical, AppDesignSystem.Spacing.regular)
                } else {
                    ScheduleSectionTabs(selectedSection: $viewModel.selectedSection, courseTitle: viewModel.activeCourseScheduleTitle)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: AppDesignSystem.Spacing.none) {
            // 课表自行布局上下间隙，列表分栏沿用公共底部间隙。
            Color.clear
                .frame(height: displayedSection == .courses
                    ? AppDesignSystem.Spacing.none : AppDesignSystem.Spacing.tiny)
        }
        .toolbar(.hidden, for: .navigationBar)
        .allowsHitTesting(!viewModel.isLoadingCache)
        .overlay {
            if viewModel.isLoadingCache { AppLoadingState(title: "正在读取日程").background(.regularMaterial) }
        }
        .task {
            await viewModel.loadIfNeeded()
        }
        .task(id: isCurrentSectionVisible && displayedSection == .classroom && !viewModel.isLoadingCache) {
            guard isCurrentSectionVisible, displayedSection == .classroom, !viewModel.isLoadingCache else { return }
            // 每个自然日首次进入更新学校数据，其余进入复用当天缓存。
            viewModel.classroom.startClassroomPageRefresh()
        }
        .onAppear {
            consumeRequestedSectionIfNeeded()
        }
        .onChange(of: requestedSection) { _, _ in
            consumeRequestedSectionIfNeeded()
        }
        .sheet(
            item: Binding(
                get: { isCurrentSectionVisible ? viewModel.smsChallenge : nil },
                set: { challenge in
                    if isCurrentSectionVisible, challenge == nil {
                        viewModel.dismissSMSChallenge()
                    }
                }
            )
        ) { challenge in
            AppSMSVerificationSheet(
                maskedPhone: challenge.maskedPhone,
                isSubmitting: viewModel.isSubmittingSMSCode,
                errorMessage: viewModel.smsVerificationError,
                submitTitle: "验证并继续",
                onCancel: viewModel.dismissSMSChallenge,
                onSubmit: { code in
                    await viewModel.submitSMSCode(code)
                }
            )
        }
        .scheduleSchoolVerification(viewModel: viewModel.ddl, isEnabled: isCurrentSectionVisible && displayedSection != .classroom)
        .safeAreaInset(edge: .top, spacing: AppDesignSystem.Spacing.none) {
            if viewModel.hasPersistenceConflict {
                SchedulePersistenceConflictView(repository: viewModel.repository)
                    .padding(AppDesignSystem.Spacing.content)
                    .background(AppDesignSystem.Palette.Background.grouped)
            } else if viewModel.hasCacheReadFailure || viewModel.requiresRecoveryConfirmation {
                ScheduleCacheRecoveryView(repository: viewModel.repository)
                    .padding(AppDesignSystem.Spacing.content)
                    .background(AppDesignSystem.Palette.Background.grouped)
            }
        }
        .environmentObject(viewModel)
        .environmentObject(viewModel.ddl)
    }

    /// 轻扫切换课表 / DDL / 空教室的手势。
    ///
    /// 课表上方四分之一专用于周次滑动条，剩余区域支持横向轻扫切换分区。
    private func sectionSwitchGesture(topDisabledY: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .global)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) > abs(vertical), abs(horizontal) >= 56 else { return }
                guard value.startLocation.y >= topDisabledY else { return }
                guard !horizontalControlFrames.contains(where: { $0.contains(value.startLocation) }) else { return }
                switchSection(step: horizontal < 0 ? 1 : -1)
            }
    }

    /// 根据方向切换一级分区。
    private func switchSection(step: Int) {
        let allSections: [ScheduleSection] = layout.isLandscape ? [.courses, .classroom] : ScheduleSection.allCases
        let currentSection = layout.isLandscape && viewModel.selectedSection == .ddl ? ScheduleSection.courses : viewModel.selectedSection
        guard let currentIndex = allSections.firstIndex(of: currentSection) else { return }

        let nextIndex = currentIndex + step
        guard allSections.indices.contains(nextIndex) else { return }

        withAnimation(AppDesignSystem.Motion.transition(reduceMotion: reduceMotion)) {
            viewModel.selectedSection = allSections[nextIndex]
        }
    }

    /// 消费来自 App 壳层的深链跳转请求。
    private func consumeRequestedSectionIfNeeded() {
        guard let requestedSection else { return }

        withAnimation(AppDesignSystem.Motion.transition(reduceMotion: reduceMotion)) {
            viewModel.selectedSection = requestedSection
            if requestedSection == .courses {
                // 从小组件、锁屏组件或灵动岛回到课表时，发一个“回首页”信号，
                // 让课表分栏按正常 dismiss 路径收起当前 sheet。
                courseTabResetSignal &+= 1
                viewModel.showCurrentPrimarySchedule()
            }
        }

        self.requestedSection = nil
    }
}

/// 页面与设置共用读取重试和部分恢复确认。
public struct ScheduleCacheRecoveryView: View {
    @ObservedObject private var repository: ScheduleRepository
    @State private var isConfirmingRebuild = false
    @State private var rebuildGeneration = 0

    public init(repository: ScheduleRepository) { self.repository = repository }

    public var body: some View {
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.content) {
            Text(repository.hasReadFailure ? "日程读取受阻" : "日程已部分恢复")
                .font(AppDesignSystem.Typography.title)
            Text(repository.hasReadFailure ? "原始数据已保留。请检查文件访问与 App 版本，再重试读取。" :
                "可用日程继续展示。请核对恢复结果，确认后保存并继续编辑。")
            Button("重试读取") { Task { await repository.reload() } }
                .accessibilityIdentifier("schedule.recovery.retry")
            if repository.canRebuildCache {
                Button("重建日程缓存", role: .destructive) {
                    rebuildGeneration = repository.accountGeneration
                    isConfirmingRebuild = true
                }
                    .accessibilityIdentifier("schedule.recovery.rebuild")
            }
            if repository.requiresRecoveryConfirmation && !repository.hasReadFailure {
                Button("确认恢复结果") { Task { await repository.confirmRecovery() } }
                    .accessibilityIdentifier("schedule.recovery.confirm")
            }
        }
        .buttonStyle(.borderless)
        .disabled(repository.isConfirmingRecovery)
        .alert("重建日程缓存？", isPresented: $isConfirmingRebuild) {
            Button("重建", role: .destructive) {
                let generation = rebuildGeneration
                Task { await repository.rebuildCache(expectedGeneration: generation) }
            }
                .accessibilityIdentifier("schedule.recovery.rebuild.confirm")
            Button("取消", role: .cancel) {}
                .accessibilityIdentifier("schedule.recovery.rebuild.cancel")
        } message: {
            Text("将以当前可用日程覆盖该账号的损坏缓存，原文件内容会清除。学校日程可重新同步。")
        }
    }
}

/// 页面与设置共用版本选择，保留待处理编辑及独立同步修改。
public struct SchedulePersistenceConflictView: View {
    @ObservedObject private var repository: ScheduleRepository

    public init(repository: ScheduleRepository) { self.repository = repository }

    public var body: some View {
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.content) {
            Text("日程版本发生变化").font(AppDesignSystem.Typography.title)
            Text("本机与同步版本修改了相同内容。独立修改将共同保留，请选择冲突内容的版本。")
            Button("保留本机冲突内容") { Task { await repository.resolvePersistenceConflict(.keepLocal) } }
                .accessibilityIdentifier("schedule.conflict.keep-local")
            Button("采用同步冲突内容") { Task { await repository.resolvePersistenceConflict(.useCloud) } }
                .accessibilityIdentifier("schedule.conflict.use-cloud")
        }
        .buttonStyle(.borderless)
        .disabled(repository.isResolvingPersistenceConflict)
    }
}

/// 顶部公共分段切换条。
///
/// 根视图专注处理路由和副作用，segmented 样式细节由子视图承载。
private struct ScheduleSectionTabs: View {
    @Binding var selectedSection: ScheduleSection
    let courseTitle: String

    /// 日程页顶部公共分段控件。
    var body: some View {
        AppTopSegmentedPicker(title: "日程模块", selection: $selectedSection) {
            Text(courseTitle).tag(ScheduleSection.courses)
            Text(ScheduleSection.ddl.title).tag(ScheduleSection.ddl)
            Text(ScheduleSection.classroom.title).tag(ScheduleSection.classroom)
        }
    }
}

#endif
