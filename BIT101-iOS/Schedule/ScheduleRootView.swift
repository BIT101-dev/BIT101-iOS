//
//  ScheduleRootView.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import SwiftUI

// MARK: - Schedule Root

/// 日程页根视图。
///
/// 顶部使用公共 segmented，正文按当前分区单独渲染。
/// 页面正文保持独立布局，底部玻璃效果稳定，轻扫切换继续可用。
struct ScheduleRootView: View {
    /// 壳层深链请求的目标分栏，例如从小组件点进来直接落到课表。
    @Binding var requestedSection: ScheduleSection?
    let onOpenAcademicCourse: (CourseNavigationRequest) -> Void
    let onOpenCourseLocation: (CampusMapLocationRequest) -> Void
    @StateObject private var viewModel = SchoolDataViewModelStore.shared.scheduleViewModel
    @State private var courseTabResetSignal = 0

    init(
        requestedSection: Binding<ScheduleSection?>,
        onOpenAcademicCourse: @escaping (CourseNavigationRequest) -> Void = { _ in },
        onOpenCourseLocation: @escaping (CampusMapLocationRequest) -> Void = { _ in }
    ) {
        _requestedSection = requestedSection
        self.onOpenAcademicCourse = onOpenAcademicCourse
        self.onOpenCourseLocation = onOpenCourseLocation
    }

    /// 日程主页主体。
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                selectedSectionView
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .simultaneousGesture(
                sectionSwitchGesture(
                    topDisabledHeight: viewModel.selectedSection == .courses
                        ? proxy.size.height * 0.25
                        : 0
                )
            )
        }
        .background(AppDesignSystem.Palette.groupedBackground)
        // 与成绩、话廊共用同一套 safeAreaInset 结构。列表内容从顶部切换栏之后开始，
        // 日程分栏保持单层 VStack 间距。
        .safeAreaInset(edge: .top, spacing: AppDesignSystem.Spacing.none) {
            ScheduleSectionTabs(
                selectedSection: $viewModel.selectedSection,
                courseTitle: viewModel.activeCourseScheduleTitle
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // 给课表、DDL、空教室统一保留到底部系统 Tab 栏的固定内容间隙。
            Color.clear
                .frame(height: AppDesignSystem.Spacing.tight)
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            viewModel.loadIfNeeded()
        }
        .task(id: viewModel.selectedSection) {
            guard viewModel.selectedSection == .classroom else { return }
            // 进入空教室分栏表示用户发起明确查询；查询从这里开始加载，
            // App 启动和回前台生命周期保持独立。
            viewModel.startClassroomPageRefresh()
        }
        .onAppear {
            consumeRequestedSectionIfNeeded()
        }
        .onChange(of: requestedSection) { _, _ in
            consumeRequestedSectionIfNeeded()
        }
        .sheet(
            item: Binding(
                get: { viewModel.smsChallenge },
                set: { challenge in
                    if challenge == nil {
                        viewModel.dismissSMSChallenge()
                    }
                }
            )
        ) { challenge in
            AppSMSVerificationSheet(
                challenge: challenge,
                isSubmitting: viewModel.isSubmittingSMSCode,
                errorMessage: viewModel.smsVerificationError,
                submitTitle: "验证并同步课表",
                onCancel: viewModel.dismissSMSChallenge,
                onSubmit: { code in
                    await viewModel.submitSMSCode(code)
                }
            )
        }
        .sheet(
            item: Binding(
                get: { viewModel.schoolSMSCodeRequest },
                set: { request in
                    if request == nil {
                        viewModel.dismissSchoolSMSCode()
                    }
                }
            )
        ) { request in
            AppSchoolSMSVerificationSheet(
                request: request,
                onCancel: viewModel.dismissSchoolSMSCode,
                onSubmit: viewModel.submitSchoolSMSCode
            )
        }
    }

    /// 根据当前分区切换渲染不同内容页。
    @ViewBuilder
    private var selectedSectionView: some View {
        switch viewModel.selectedSection {
        case .courses:
            CourseScheduleTabView(
                viewModel: viewModel,
                resetSignal: courseTabResetSignal,
                onOpenAcademicCourse: onOpenAcademicCourse,
                onOpenCourseLocation: onOpenCourseLocation
            )
        case .ddl:
            DDLScheduleTabView(viewModel: viewModel)
        case .classroom:
            FreeClassroomTabView(viewModel: viewModel)
        }
    }

    /// 轻扫切换课表 / DDL / 空教室的手势。
    ///
    /// 课表上方四分之一专用于周次滑动条，剩余区域支持横向轻扫切换分区。
    private func sectionSwitchGesture(topDisabledHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) > abs(vertical), abs(horizontal) >= 56 else { return }
                guard value.startLocation.y >= topDisabledHeight else { return }
                switchSection(step: horizontal < 0 ? 1 : -1)
            }
    }

    /// 根据方向切换一级分区。
    private func switchSection(step: Int) {
        let allSections = ScheduleSection.allCases
        guard let currentIndex = allSections.firstIndex(of: viewModel.selectedSection) else { return }

        let nextIndex = currentIndex + step
        guard allSections.indices.contains(nextIndex) else { return }

        withAnimation(.easeInOut) {
            viewModel.selectedSection = allSections[nextIndex]
        }
    }

    /// 消费来自 App 壳层的深链跳转请求。
    private func consumeRequestedSectionIfNeeded() {
        guard let requestedSection else { return }

        withAnimation(.easeInOut) {
            viewModel.selectedSection = requestedSection
            if requestedSection == .courses {
                // 从小组件、锁屏组件或灵动岛回到课表时，发一个“回首页”信号，
                // 让课表分栏按正常 dismiss 路径收起当前 sheet。
                courseTabResetSignal &+= 1
                viewModel.resetToCurrentWeek()
            }
        }

        self.requestedSection = nil
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
