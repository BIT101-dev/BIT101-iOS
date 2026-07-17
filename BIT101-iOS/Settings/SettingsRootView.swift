//
//  SettingsRootView.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import PhotosUI
import SwiftUI
import UIKit
import WebKit

let mitLicenseText = "MIT License Copyright (c) 2026 BIT101 Contributors Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the \"Software\"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE."

/// 设置中心支持的一级菜单。
///
/// “设置首页卡片”与“从其它页面直达某一设置子页”都依赖这个枚举作为统一路由源。
enum SettingsRoute: String, CaseIterable, Identifiable {
    case account
    case pages
    case theme
    case calendar
    case ddl
    case gallery
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: return "账号设置"
        case .pages: return "页面设置"
        case .theme: return "外观设置"
        case .calendar: return "课程表设置"
        case .ddl: return "DDL设置"
        case .gallery: return "话廊设置"
        case .about: return "关于"
        }
    }

    var subtitle: String {
        switch self {
        case .account: return "个人信息编辑及登录状态管理"
        case .pages: return "启动页及页面顺序"
        case .theme: return "主题及暗黑模式"
        case .calendar: return "课程表数据及显示方式"
        case .ddl: return "日程数据及显示方式"
        case .gallery: return "话廊数据及显示方式"
        case .about: return "关于 BIT101"
        }
    }

    var systemImage: String {
        switch self {
        case .account: return "person.crop.circle"
        case .pages: return "square.grid.2x2"
        case .theme: return "paintpalette"
        case .calendar: return "calendar.badge.clock"
        case .ddl: return "list.bullet.clipboard"
        case .gallery: return "bubble.left.and.bubble.right"
        case .about: return "info.circle"
        }
    }
}

/// 全局设置中心入口。
///
/// “我的”页右上角设置、课程表页齿轮、DDL 页齿轮都应当汇入这里。
struct SettingsRootView: View {
    let initialRoute: SettingsRoute?
    let studentID: String
    let onLogout: () -> Void
    var showsCloseButton = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let initialRoute {
                SettingsRoutePage(route: initialRoute, studentID: studentID, onLogout: onLogout)
            } else {
                SettingsIndexPage(studentID: studentID, onLogout: onLogout)
            }
        }
        .navigationTitle(initialRoute?.title ?? "设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
    }
}

/// 设置首页，负责列出全部一级菜单。
///
/// 这里仍然保留卡片式入口，而不是直接用 `List`，是为了和“我的”页的入口风格区分开。
private struct SettingsIndexPage: View {
    let studentID: String
    let onLogout: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(SettingsRoute.allCases) { route in
                    NavigationLink {
                        SettingsRoutePage(route: route, studentID: studentID, onLogout: onLogout)
                    } label: {
                        SettingsIndexCard(route: route)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .background(Color(.systemGroupedBackground))
    }
}

/// 设置首页卡片样式。
private struct SettingsIndexCard: View {
    let route: SettingsRoute

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: route.systemImage)
                .frame(width: 24, height: 24)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 3) {
                Text(route.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(route.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// 根据 route 分发到具体设置页面。
///
/// 这一层的意义是把“路由选择”和“具体页面实现”解耦，便于其它模块直接按 route 深链进来。
private struct SettingsRoutePage: View {
    let route: SettingsRoute
    let studentID: String
    let onLogout: () -> Void

    var body: some View {
        switch route {
        case .account:
            AccountSettingsPage(studentID: studentID, onLogout: onLogout)
        case .pages:
            PagesSettingsPage()
        case .theme:
            ThemeSettingsPage()
        case .calendar:
            CalendarSettingsPage()
        case .ddl:
            DDLSettingsPage()
        case .gallery:
            GallerySettingsPage()
        case .about:
            AboutSettingsPage(onLogout: onLogout)
        }
    }
}

/// 账号设置页。
///
/// 包含个人资料编辑、头像上传、登录状态检查和退出登录。
private struct AccountSettingsPage: View {
    let studentID: String
    let onLogout: () -> Void

    @State private var profile: MineUserInfo?
    @State private var isCheckingLogin = false
    @State private var isLoggedIn = true
    @State private var isUpdating = false
    @State private var showNicknameEditor = false
    @State private var showMottoEditor = false
    @State private var nicknameText = ""
    @State private var mottoText = ""
    @State private var isShowingStudentID = false
    @State private var isShowingUID = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var alert: AppAlert?

    private let service = SettingsNetworkService()

    var body: some View {
        List {
            if let profile {
                Section("个人信息") {
                    HStack {
                        Text("头像")
                        Spacer()
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            CachedRemoteImage(url: URL(string: profile.user.avatar.url)) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Circle().fill(Color.blue.opacity(0.15))
                            }
                            .frame(width: 40, height: 40)
                            .clipShape(Circle())
                        }
                        .disabled(isUpdating)
                    }

                    Button {
                        nicknameText = profile.user.nickname
                        showNicknameEditor = true
                    } label: {
                        LabeledContent("昵称", value: profile.user.nickname)
                    }
                    .disabled(isUpdating)

                    Button {
                        mottoText = profile.user.motto
                        showMottoEditor = true
                    } label: {
                        LabeledContent("个性签名", value: profile.user.motto.isEmpty ? "空" : profile.user.motto)
                    }
                    .disabled(isUpdating)

                    SettingsSensitiveValueRow(
                        title: "学号",
                        value: studentID,
                        isRevealed: $isShowingStudentID
                    )

                    SettingsSensitiveValueRow(
                        title: "UID",
                        value: String(profile.user.id),
                        isRevealed: $isShowingUID
                    )
                }
            }

            Section("登录状态") {
                Button {
                    Task { await checkLogin() }
                } label: {
                    HStack {
                        Text("登录状态检查")
                        Spacer()
                        if isCheckingLogin {
                            ProgressView()
                        } else {
                            Text(isLoggedIn ? "已登录" : "未登录")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(isCheckingLogin)

                Button("退出登录", role: .destructive, action: onLogout)
            }
        }
        .task {
            await loadProfile()
        }
        .onChange(of: selectedPhoto) { _, newValue in
            guard let newValue else { return }
            Task { await updateAvatar(with: newValue) }
        }
        .sheet(isPresented: $showNicknameEditor) {
            SettingsTextEditSheet(
                title: "修改昵称",
                text: $nicknameText,
                onSubmit: {
                    Task { await updateProfile(nickname: nicknameText, motto: nil) }
                }
            )
        }
        .sheet(isPresented: $showMottoEditor) {
            SettingsTextEditSheet(
                title: "修改个性签名",
                text: $mottoText,
                axis: .vertical,
                onSubmit: {
                    Task { await updateProfile(nickname: nil, motto: mottoText) }
                }
            )
        }
        .alert(item: $alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("知道了")))
        }
    }

    /// 拉取当前登录用户资料卡。
    private func loadProfile() async {
        do {
            profile = try await service.fetchMyInfo()
            isLoggedIn = true
        } catch {
            alert = AppAlert(title: "加载失败", message: error.localizedDescription)
        }
    }

    /// 触发一次显式登录状态检查。
    private func checkLogin() async {
        isCheckingLogin = true
        defer { isCheckingLogin = false }
        do {
            isLoggedIn = try await service.checkLogin()
        } catch {
            alert = AppAlert(title: "检查失败", message: error.localizedDescription)
        }
    }

    /// 更新昵称或签名。
    ///
    /// 接口要求整份资料一起提交，所以未改动字段也要回填旧值。
    private func updateProfile(nickname: String?, motto: String?) async {
        guard let profile else { return }
        isUpdating = true
        defer { isUpdating = false }
        do {
            try await service.updateUser(
                nickname: nickname ?? profile.user.nickname,
                motto: motto ?? profile.user.motto,
                avatarMid: profile.user.avatar.mid
            )
            await loadProfile()
            showNicknameEditor = false
            showMottoEditor = false
        } catch {
            alert = AppAlert(title: "更新失败", message: error.localizedDescription)
        }
    }

    /// 上传并绑定新头像。
    private func updateAvatar(with item: PhotosPickerItem) async {
        guard let profile else { return }
        isUpdating = true
        defer { isUpdating = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw SettingsServiceError.uploadFailed
            }
            let image = try await service.uploadAvatar(data: data)
            try await service.updateUser(
                nickname: profile.user.nickname,
                motto: profile.user.motto,
                avatarMid: image.mid
            )
            await loadProfile()
        } catch {
            alert = AppAlert(title: "头像更新失败", message: error.localizedDescription)
        }
    }
}

/// 设置页里用于按需显示学号、UID 这类敏感标识。
///
/// 默认做轻度模糊，点击后再完全展开，避免在公共场合一眼暴露账号信息。
private struct SettingsSensitiveValueRow: View {
    let title: String
    let value: String
    @Binding var isRevealed: Bool

    var body: some View {
        Button {
            isRevealed.toggle()
        } label: {
            HStack(spacing: 10) {
                Text(title)
                Spacer()
                if isRevealed {
                    Text(value)
                        .foregroundStyle(.secondary)
                } else {
                    Text(value)
                        .foregroundStyle(.secondary)
                        .blur(radius: 7)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// 页面设置页。
///
/// 负责底部 tab 的显示顺序、默认页和可见性配置。
private struct PagesSettingsPage: View {
    @ObservedObject private var settings = AppSettingsStore.shared
    @State private var pageOrder = AppTab.allCases
    @State private var homeTab: AppTab = .schedule
    @State private var hiddenTabs: Set<AppTab> = []
    @State private var editMode: EditMode = .inactive

    var body: some View {
        List {
            Section {
                Text("按住右侧拖动可以调整顺序；勾选默认项表示启动时默认页面；隐藏会从底部导航栏移除，“我的”页面不能隐藏。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(pageOrder) { tab in
                    HStack {
                        Text(tab.title)
                        Spacer()
                        Toggle("显示", isOn: Binding(
                            get: { !hiddenTabs.contains(tab) || tab == .mine },
                            set: { visible in
                                if tab != .mine {
                                    if visible { hiddenTabs.remove(tab) } else { hiddenTabs.insert(tab) }
                                    if hiddenTabs.contains(homeTab) {
                                        homeTab = pageOrder.first(where: { !hiddenTabs.contains($0) || $0 == .mine }) ?? .schedule
                                    }
                                    persist()
                                }
                            }
                        ))
                        .labelsHidden()
                        Button {
                            homeTab = tab
                            persist()
                        } label: {
                            Image(systemName: homeTab == tab ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(homeTab == tab ? Color.accentColor : .secondary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .onMove { from, to in
                    pageOrder.move(fromOffsets: from, toOffset: to)
                    persist()
                }
            } header: {
                Text("页面编辑")
            }
        }
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editMode.isEditing ? "完成" : "编辑") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        editMode = editMode.isEditing ? .inactive : .active
                    }
                }
            }
        }
        .task { syncFromStore() }
    }

    /// 把当前全局设置同步到本页可编辑状态。
    private func syncFromStore() {
        pageOrder = settings.pageOrder
        homeTab = settings.homeTab
        hiddenTabs = Set(settings.hiddenTabs)
    }

    /// 把当前页面编辑结果一次性写回设置仓库。
    private func persist() {
        settings.setPageOrder(pageOrder)
        settings.setHiddenTabs(Array(hiddenTabs))
        settings.setHomeTab(homeTab)
    }
}

/// 外观设置页。
///
/// 目前只保留外观模式和自动旋转两项全局开关。
private struct ThemeSettingsPage: View {
    @ObservedObject private var settings = AppSettingsStore.shared

    var body: some View {
        Form {
            Section {
                Picker("外观模式", selection: Binding(
                    get: { settings.themeMode },
                    set: settings.setThemeMode
                )) {
                    ForEach(AppThemeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                Toggle("自动旋转", isOn: Binding(
                    get: { settings.autoRotate },
                    set: settings.setAutoRotate
                ))
            }
        }
    }
}

/// 课程表设置页。
///
/// 这里既承载“数据同步入口”，也承载“课表显示项”和“灵动岛提醒”相关配置。
private struct CalendarSettingsPage: View {
    @ObservedObject private var appSettings = AppSettingsStore.shared

    private struct ExportedScheduleCode: Identifiable {
        let id = UUID()
        let code: String
    }

    private struct ScheduleImportDraft: Identifiable {
        let id = UUID()
        var text = ""
    }

    private struct RenamingScheduleTarget: Identifiable {
        enum Kind {
            case primary
            case shared(String)
        }

        let id = UUID()
        let kind: Kind
        let currentName: String
        let title: String
    }

    @StateObject private var viewModel = ScheduleViewModel()
    @State private var isShowingTimeTableEditor = false
    @State private var timeTableText = ""
    @State private var isShowingCustomSchedules = false
    @State private var isShowingLiveActivityLeadMinutesPicker = false
    @State private var isShowingFirstDayEditor = false
    @State private var firstDayDraft = Date()
    @State private var isShowingEmptyScheduleExportConfirmation = false
    @State private var isShowingSharedScheduleImportGuide = false
    @State private var isShowingLiveActivityExperimentalWarning = false
    @State private var shouldOpenImportSheetAfterGuide = false
    @State private var exportedScheduleCode: ExportedScheduleCode?
    @State private var importDraft: ScheduleImportDraft?
    @State private var renamingScheduleTarget: RenamingScheduleTarget?

    private var normalizedLeadMinutes: Int {
        min(max(viewModel.cache.courseLiveActivityLeadMinutes, 1), 60)
    }

    var body: some View {
        List {
            Section("数据设置") {
                NavigationLink {
                    ScheduleTermPickerPage(viewModel: viewModel)
                } label: {
                    LabeledContent("当前学期", value: viewModel.cache.currentTerm.isEmpty ? "未设置" : viewModel.cache.currentTerm)
                }
                Button {
                    firstDayDraft = viewModel.cache.firstDay ?? Date()
                    isShowingFirstDayEditor = true
                } label: {
                    LabeledContent("学期起始日期", value: viewModel.firstDayDescription)
                        .foregroundStyle(.primary)
                }

                Button {
                    Task { await viewModel.syncSelectedTerm() }
                } label: {
                    HStack {
                        Text("重新同步课表与考试")
                        Spacer()
                        if viewModel.isSyncingCourses {
                            ProgressView()
                        }
                    }
                }
                .disabled(viewModel.isSyncingCourses || viewModel.isLoadingTerms)

                Button("时间表") {
                    timeTableText = viewModel.cache.timeTable.map { "\($0.start), \($0.end)" }.joined(separator: "\n")
                    isShowingTimeTableEditor = true
                }

                Button("自定义日程") {
                    isShowingCustomSchedules = true
                }

                Button("分享课表") {
                    exportScheduleCode()
                }

                Button("导入课表") {
                    presentImportGuideIfNeeded(openImportAfterGuide: true)
                }
            }

            Section("课表名称") {
                Button {
                    renamingScheduleTarget = RenamingScheduleTarget(
                        kind: .primary,
                        currentName: viewModel.cache.primaryScheduleTitle,
                        title: "重命名课表"
                    )
                } label: {
                    LabeledContent("我的课表", value: viewModel.cache.primaryScheduleTitle)
                }

                ForEach(viewModel.cache.sharedSchedules) { schedule in
                    Button {
                        renamingScheduleTarget = RenamingScheduleTarget(
                            kind: .shared(schedule.id),
                            currentName: schedule.title,
                            title: "重命名分享课表"
                        )
                    } label: {
                        LabeledContent("分享课表", value: schedule.title)
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.compactMap { index in
                        viewModel.cache.sharedSchedules.indices.contains(index) ? viewModel.cache.sharedSchedules[index].id : nil
                    }
                    ids.forEach(viewModel.deleteSharedSchedule)
                }
            }

            Section {
                Toggle("显示周六", isOn: Binding(get: { viewModel.cache.showSaturday }, set: viewModel.setShowSaturday))
                Toggle("显示周日", isOn: Binding(get: { viewModel.cache.showSunday }, set: viewModel.setShowSunday))
                Toggle("显示课程卡片边框", isOn: Binding(get: { viewModel.cache.showBorder }, set: viewModel.setShowBorder))
                Toggle("高亮今日", isOn: Binding(get: { viewModel.cache.showHighlightToday }, set: viewModel.setShowHighlightToday))
                Toggle("显示节次分割线", isOn: Binding(get: { viewModel.cache.showDivider }, set: viewModel.setShowDivider))
                Toggle("显示当前时间线", isOn: Binding(get: { viewModel.cache.showCurrentTime }, set: viewModel.setShowCurrentTime))
                Toggle("显示考试安排", isOn: Binding(get: { viewModel.cache.showExamInfo }, set: viewModel.setShowExamInfo))
                Toggle("显示灵动岛提醒（实验性）", isOn: Binding(
                    get: { viewModel.cache.showCourseLiveActivityReminder },
                    set: { enabled in
                        if enabled {
                            isShowingLiveActivityExperimentalWarning = true
                        } else {
                            viewModel.setShowCourseLiveActivityReminder(false)
                        }
                    }
                ))
                Button {
                    guard viewModel.cache.showCourseLiveActivityReminder else { return }
                    isShowingLiveActivityLeadMinutesPicker = true
                } label: {
                    HStack {
                        Text("提前显示阈值")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(normalizedLeadMinutes) 分钟")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .opacity(viewModel.cache.showCourseLiveActivityReminder ? 1 : 0.45)
            } header: {
                Text("显示设置")
            }

            Section("iCloud 同步") {
                Toggle("iCloud 实时同步", isOn: Binding(
                    get: { viewModel.cache.iCloudSyncEnabled },
                    set: { enabled in
                        viewModel.setICloudSyncEnabled(enabled)
                    }
                ))
            }

            if appSettings.hasSeenSharedScheduleImportGuide {
                Section("帮助") {
                    Button("重新观看提示") {
                        presentImportGuideIfNeeded(openImportAfterGuide: false, forceShow: true)
                    }
                }
            }
        }
        .task {
            await viewModel.loadIfNeeded()
            if viewModel.cache.courseLiveActivityLeadMinutes != normalizedLeadMinutes {
                viewModel.setCourseLiveActivityLeadMinutes(normalizedLeadMinutes)
            }
        }
        .sheet(isPresented: $isShowingTimeTableEditor) {
            TimeTableEditorSheet(
                text: $timeTableText,
                onSubmit: {
                    do {
                        try viewModel.setTimeTable(from: timeTableText)
                        isShowingTimeTableEditor = false
                    } catch {
                        viewModel.notice = ScheduleNotice(title: "设置失败", message: error.localizedDescription)
                    }
                }
            )
        }
        .sheet(isPresented: $isShowingCustomSchedules) {
            CustomScheduleListSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $isShowingLiveActivityLeadMinutesPicker) {
            NavigationStack {
                CourseLiveActivityLeadMinutesPickerPage(
                    value: Binding(
                        get: { normalizedLeadMinutes },
                        set: viewModel.setCourseLiveActivityLeadMinutes
                    )
                )
            }
        }
        .sheet(isPresented: $isShowingFirstDayEditor) {
            NavigationStack {
                ScheduleFirstDayEditorPage(date: $firstDayDraft) {
                    viewModel.setFirstDay(firstDayDraft)
                    isShowingFirstDayEditor = false
                }
            }
        }
        .sheet(item: $exportedScheduleCode) { payload in
            ScheduleExportCodeSheet(code: payload.code)
        }
        .sheet(item: $importDraft) { draft in
            ScheduleImportCodeSheet(
                initialText: draft.text,
                onImport: { text in
                    try importScheduleCode(text)
                }
            )
        }
        .sheet(item: $renamingScheduleTarget) { target in
            ScheduleRenameSheet(
                title: target.title,
                initialName: target.currentName
            ) { newName in
                switch target.kind {
                case .primary:
                    try viewModel.renamePrimarySchedule(to: newName)
                case let .shared(id):
                    try viewModel.renameSharedSchedule(id: id, to: newName)
                }
            }
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
            ScheduleSMSVerificationSheet(
                challenge: challenge,
                isSubmitting: viewModel.isSubmittingSMSCode,
                errorMessage: viewModel.smsVerificationError,
                onCancel: viewModel.dismissSMSChallenge,
                onSubmit: { code in
                    await viewModel.submitSMSCode(code)
                }
            )
        }
        .alert("你尚未获取课表", isPresented: $isShowingEmptyScheduleExportConfirmation) {
            Button("取消", role: .cancel) {}
            Button("确定") {
                exportScheduleCode(allowEmptyCourseData: true)
            }
        } message: {
            Text("你尚未获取课表，仍要分享？")
        }
        .alert("实验性功能提醒", isPresented: $isShowingLiveActivityExperimentalWarning) {
            Button("取消", role: .cancel) {}
            Button("继续打开") {
                viewModel.setShowCourseLiveActivityReminder(true)
            }
        } message: {
            Text("开发者和 AI 尚未完全摸清楚灵动岛的运作机理和唤醒条件。虽然做了多重兜底，但仍不能保证每节课都能按时通知。继续打开视为已知悉此风险。")
        }
        .alert("导入分享课表提示", isPresented: $isShowingSharedScheduleImportGuide) {
            Button("知道了") {
                appSettings.markSharedScheduleImportGuideSeen()
                if shouldOpenImportSheetAfterGuide {
                    importDraft = ScheduleImportDraft()
                }
                shouldOpenImportSheetAfterGuide = false
            }
            Button("取消", role: .cancel) {
                shouldOpenImportSheetAfterGuide = false
            }
        } message: {
            Text("课表可以单击以改名，左滑以删除，在日程界面上下滑可循环切换，所有小组件以自己的课表作为数据源。")
        }
        .alert(item: $viewModel.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("知道了"))
            )
        }
    }

    /// 生成一份可复制的压缩课表编码。
    ///
    /// 当前编码格式为：
    /// `BIT101SCH2:<base64(lzfse(json(compactPayload)))>`
    ///
    /// V2 只导出课程排布骨架，导入端复用本机的学期、首周和时间表；V1 导入仍保留兼容旧分享码。
    private func exportScheduleCode(allowEmptyCourseData: Bool = false) {
        let payload = ScheduleExportCompactPayloadV2(cache: viewModel.cache)
        guard allowEmptyCourseData || !payload.isEmpty else {
            isShowingEmptyScheduleExportConfirmation = true
            return
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            let jsonData = try encoder.encode(payload)
            guard let compressedData = try (jsonData as NSData).compressed(using: .lzfse) as Data? else {
                throw NSError(domain: "BIT101.ScheduleExport", code: -1, userInfo: [NSLocalizedDescriptionKey: "课表压缩失败。"])
            }
            let code = "BIT101SCH2:\(compressedData.base64EncodedString())"
            exportedScheduleCode = ExportedScheduleCode(code: code)
        } catch {
            viewModel.notice = ScheduleNotice(title: "导出失败", message: error.localizedDescription)
        }
    }

    /// 首次导入前先展示一次使用提示；只有真正看过这条提示后，设置页才会出现“重新观看提示”入口。
    private func presentImportGuideIfNeeded(openImportAfterGuide: Bool, forceShow: Bool = false) {
        shouldOpenImportSheetAfterGuide = openImportAfterGuide

        if forceShow || !appSettings.hasSeenSharedScheduleImportGuide {
            isShowingSharedScheduleImportGuide = true
        } else if openImportAfterGuide {
            importDraft = ScheduleImportDraft()
        }
    }

    /// 解析并导入一份压缩编码的课表。
    ///
    /// 当前支持三套格式：
    /// - `BIT101SCH1:<base64(lzfse(json(payload))))>`：V1 完整 JSON 载荷
    /// - `BIT101SCH2:<base64(lzfse(json(compactPayload))))>`：V2 精简数组载荷
    /// - `BIT101SCH3:<base64(lzfse(json(compactPayload))))>`：V3 精简数组载荷，额外包含学分
    ///
    /// UI 保持不变，只在导入端根据版本前缀切换解析器。
    private func importScheduleCode(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "BIT101.ScheduleImport", code: -1, userInfo: [NSLocalizedDescriptionKey: "请输入或粘贴课表编码。"])
        }

        let supportedPrefixes = ["BIT101SCH1:", "BIT101SCH2:", "BIT101SCH3:"]
        if !supportedPrefixes.contains(where: { trimmed.hasPrefix($0) }),
           let colonIndex = trimmed.firstIndex(of: ":"),
           trimmed.hasPrefix("BIT101SCH") {
            let versionToken = trimmed[trimmed.index(trimmed.startIndex, offsetBy: "BIT101SCH".count) ..< colonIndex]
            if let version = Int(versionToken), version > 3 {
                throw NSError(domain: "BIT101.ScheduleImport", code: -1, userInfo: [NSLocalizedDescriptionKey: "对方版本更高，请更新版本后再导入。"])
            }
        }

        guard let prefix = supportedPrefixes.first(where: { trimmed.hasPrefix($0) }) else {
            throw NSError(domain: "BIT101.ScheduleImport", code: -1, userInfo: [NSLocalizedDescriptionKey: "课表编码格式不正确。"])
        }

        let body = String(trimmed.dropFirst(prefix.count))
        guard let compressedData = Data(base64Encoded: body) else {
            throw NSError(domain: "BIT101.ScheduleImport", code: -1, userInfo: [NSLocalizedDescriptionKey: "课表编码无法解码。"])
        }

        guard let jsonData = try (compressedData as NSData).decompressed(using: .lzfse) as Data? else {
            throw NSError(domain: "BIT101.ScheduleImport", code: -1, userInfo: [NSLocalizedDescriptionKey: "课表编码解压失败。"])
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload: ScheduleExportPayload
        switch prefix {
        case "BIT101SCH1:":
            payload = try decoder.decode(ScheduleExportPayload.self, from: jsonData)
        case "BIT101SCH2:":
            let compactPayload = try decoder.decode(ScheduleExportCompactPayloadV2.self, from: jsonData)
            payload = compactPayload.expandedPayload(using: viewModel.cache)
        case "BIT101SCH3:":
            let compactPayload = try decoder.decode(ScheduleExportCompactPayloadV3.self, from: jsonData)
            payload = compactPayload.expandedPayload(using: viewModel.cache)
        default:
            throw NSError(domain: "BIT101.ScheduleImport", code: -1, userInfo: [NSLocalizedDescriptionKey: "课表编码格式不正确。"])
        }
        try viewModel.importSharedSchedule(payload)
        viewModel.notice = ScheduleNotice(title: "导入成功", message: "分享的课表已导入。考试、DDL 与自定义日程不会随导入覆盖。")
    }
}

/// 课表学期选择页。
///
/// 这里只展示学校接口实际返回的学期，不在本地追加、推算或生成任何选项。
/// 真正切换只有在课程、考试和首周全部获取成功后才落盘。
private struct ScheduleTermPickerPage: View {
    @ObservedObject var viewModel: ScheduleViewModel

    private var displayedTerms: [String] {
        viewModel.availableTerms
    }

    var body: some View {
        List {
            Section("选择学期") {
                if !viewModel.hasLoadedAvailableTerms {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else {
                    ForEach(displayedTerms, id: \.self) { term in
                        Button {
                            Task { await viewModel.syncCourses(term: term) }
                        } label: {
                            HStack {
                                Text(term)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if viewModel.isSyncingCourses, viewModel.syncingTerm == term {
                                    ProgressView()
                                } else if viewModel.cache.currentTerm == term {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .disabled(viewModel.isSyncingCourses || viewModel.isLoadingTerms || viewModel.cache.currentTerm == term)
                    }
                }
            }

        }
        .navigationTitle("切换学期")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadAvailableTerms()
        }
        .refreshable {
            await viewModel.loadAvailableTerms()
        }
    }

}

/// 手动覆盖当前学期第一周日期的兜底页面。
private struct ScheduleFirstDayEditorPage: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var date: Date
    let onSave: () -> Void

    var body: some View {
        Form {
            Section {
                DatePicker(
                    "第一周起始日期",
                    selection: $date,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .onChange(of: date) { _, newValue in
                    let monday = ScheduleDateCodec.monday(containing: newValue)
                    if ScheduleDateCodec.formatDate(monday) != ScheduleDateCodec.formatDate(newValue) {
                        date = monday
                    }
                }
            } footer: {
                Text("起始日期固定为周一。选择其他日期时会自动调整到该日期所在周的周一。切换学期或重新同步时，App 会从学校校历接口重新获取。")
            }
        }
        .navigationTitle("学期起始日期")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            date = ScheduleDateCodec.monday(containing: date)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: onSave)
            }
        }
    }
}

/// 课程提醒提前显示阈值的滚轮选择页。
private struct CourseLiveActivityLeadMinutesPickerPage: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var value: Int

    /// 使用原生 wheel picker 提供 1...60 分钟的阈值选择。
    var body: some View {
        Picker("提前显示阈值", selection: $value) {
            ForEach(1 ... 60, id: \.self) { minute in
                Text("\(minute) 分钟")
                    .tag(minute)
            }
        }
        .pickerStyle(.wheel)
        .labelsHidden()
        .navigationTitle("提前显示阈值")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    dismiss()
                }
            }
        }
        .presentationDetents([.height(260)])
    }
}

/// 导出的课表压缩编码预览页。
///
/// 这里先让用户看见完整编码，再决定是否复制，方便后续用在聊天、iMessage 或手动导入场景。
private struct ScheduleExportCodeSheet: View {
    let code: String

    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ScrollView {
                    Text(code)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                }

                Button {
                    UIPasteboard.general.string = code
                    didCopy = true
                } label: {
                    Label("复制到剪贴板", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("分享课表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    ShareLink(item: code)
                }
            }
            .alert("已复制", isPresented: $didCopy) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text("课表已复制到剪贴板。")
            }
        }
    }
}

/// 导入课表压缩编码窗口。
///
/// 这里支持两种动作：
/// - 手动粘贴/编辑编码
/// - 一键从剪贴板读取
private struct ScheduleImportCodeSheet: View {
    let initialText: String
    let onImport: (String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var localAlert: AppAlert?

    init(initialText: String, onImport: @escaping (String) throws -> Void) {
        self.initialText = initialText
        self.onImport = onImport
        _text = State(initialValue: initialText)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextEditor(text: $text)
                    .font(.footnote.monospaced())
                    .frame(minHeight: 220)
                    .padding(10)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

                HStack(spacing: 12) {
                    Button {
                        if let clipboard = UIPasteboard.general.string, !clipboard.isEmpty {
                            text = clipboard
                        }
                    } label: {
                        Label("粘贴剪贴板", systemImage: "doc.on.clipboard")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        do {
                            try onImport(text)
                            dismiss()
                        } catch {
                            localAlert = AppAlert(title: "导入失败", message: error.localizedDescription)
                        }
                    } label: {
                        Label("导入", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .navigationTitle("导入课表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
            .alert(item: $localAlert) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("知道了")))
            }
        }
    }
}

/// 课表重命名窗口。
///
/// 主课表和分享课表都共用这一套简单编辑器。
private struct ScheduleRenameSheet: View {
    let title: String
    let initialName: String
    let onSubmit: (String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var localAlert: AppAlert?

    init(title: String, initialName: String, onSubmit: @escaping (String) throws -> Void) {
        self.title = title
        self.initialName = initialName
        self.onSubmit = onSubmit
        _text = State(initialValue: initialName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("课表名称", text: $text)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") {
                        do {
                            try onSubmit(text)
                            dismiss()
                        } catch {
                            localAlert = AppAlert(title: "保存失败", message: error.localizedDescription)
                        }
                    }
                }
            }
            .alert(item: $localAlert) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("知道了")))
            }
        }
    }
}

/// DDL 设置页。
///
/// 这页只负责 DDL 同步和显示窗口配置，不再混入新增/编辑入口。
private struct DDLSettingsPage: View {
    @StateObject private var viewModel = ScheduleViewModel()
    @State private var pickerRoute: DDLSettingsNumberPickerRoute?

    var body: some View {
        List {
            Section("数据设置") {
                Button {
                    Task { await viewModel.refreshLexueCalendarURL() }
                } label: {
                    DDLSettingsActionRow(
                        title: "重新获取订阅链接"
                    )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isSyncingDDL)

                Button {
                    Task { await viewModel.syncDDL() }
                } label: {
                    DDLSettingsActionRow(
                        title: "重新拉取乐学日程"
                    )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isSyncingDDL)
            }

            Section("显示设置") {
                Button {
                    pickerRoute = .beforeDay
                } label: {
                    DDLSettingsActionRow(
                        title: "变色天数",
                        value: "\(viewModel.beforeDay) 天"
                    )
                }
                .buttonStyle(.plain)

                Button {
                    pickerRoute = .afterDay
                } label: {
                    DDLSettingsActionRow(
                        title: "滞留天数",
                        value: "\(viewModel.afterDay) 天"
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.insetGrouped)
        .task { await viewModel.loadIfNeeded() }
        .sheet(item: $pickerRoute) { route in
            switch route {
            case .beforeDay:
                DDLSettingsNumberPickerSheet(
                    title: "变色天数",
                    initialValue: viewModel.beforeDay
                ) { value in
                    viewModel.setDDLBeforeDay(value)
                }
            case .afterDay:
                DDLSettingsNumberPickerSheet(
                    title: "滞留天数",
                    initialValue: viewModel.afterDay
                ) { value in
                    viewModel.setDDLAfterDay(value)
                }
            }
        }
        .alert(item: $viewModel.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("知道了"))
            )
        }
    }
}

/// DDL 设置页里可弹出编辑抽屉的数值项。
private enum DDLSettingsNumberPickerRoute: String, Identifiable {
    case beforeDay
    case afterDay

    var id: String { rawValue }
}

/// DDL 设置页按钮行。
private struct DDLSettingsActionRow: View {
    let title: String
    var value: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(Color.accentColor)

            Spacer(minLength: 0)

            if let value {
                Text(value)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// DDL 设置页数值选择抽屉。
private struct DDLSettingsNumberPickerSheet: View {
    let title: String
    let initialValue: Int
    let onSubmit: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var value: Int

    init(title: String, initialValue: Int, onSubmit: @escaping (Int) -> Void) {
        self.title = title
        self.initialValue = initialValue
        self.onSubmit = onSubmit
        _value = State(initialValue: initialValue)
    }

    var body: some View {
        NavigationStack {
            VStack {
                Picker(title, selection: $value) {
                    ForEach(0 ... 30, id: \.self) { day in
                        Text("\(day) 天")
                            .tag(day)
                    }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onSubmit(value)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.height(240)])
        .presentationDragIndicator(.visible)
    }
}

/// 画廊设置页。
///
/// 集中管理本地黑名单、隐藏帖子、社区规则状态以及相关联系信息。
