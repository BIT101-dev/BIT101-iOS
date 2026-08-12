//
//  ScheduleViewModel.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Combine
import Foundation

private extension Int {
    func modulo(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        let remainder = self % count
        return remainder >= 0 ? remainder : remainder + count
    }
}


/// 日程页统一使用的提示模型。
///
/// 日程模块内部的同步、保存、空教室查询等动作都会通过这个统一提示模型把错误抛给视图层。
struct ScheduleNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// 空教室页业务级超时错误。
struct ClassroomRequestTimeoutError: LocalizedError {
    var errorDescription: String? {
        "请求超时，请稍后重试。"
    }
}

@MainActor
/// 日程模块状态机。
///
/// 负责：
/// 1. 本地缓存恢复
/// 2. 课表 / DDL / 空教室同步
/// 3. 自定义日程和自定义 DDL 的本地 CRUD
/// 4. 与设置中心共享缓存后的自动刷新
final class ScheduleViewModel: ObservableObject {
    /// 课表页当前正在显示的课表分身。
    ///
    /// 主课表仍然来自当前账号缓存；导入的课表则作为只读分身挂在后面，供上下滑循环切换。
    struct CourseScheduleVariant: Identifiable, Equatable {
        let id: String
        let title: String
        let isPrimary: Bool
        let currentTerm: String
        let firstDayString: String
        let timeTable: [TimeSlot]
        let courses: [CourseRecord]
        let exams: [ExamRecord]
        let customSchedules: [CustomScheduleRecord]

        var firstDay: Date? {
            ScheduleDateCodec.parseDate(firstDayString)
        }

        var hasCourseData: Bool {
            !courses.isEmpty || !exams.isEmpty
        }
    }

    /// 当前选中的一级分栏。
    @Published var selectedSection: ScheduleSection = .courses
    /// 当前账号的日程缓存快照。
    @Published private(set) var cache = ScheduleCache()
    /// 是否正在做首次本地缓存恢复。
    @Published private(set) var isLoadingCache = true
    /// 是否正在同步课表/考试。
    @Published private(set) var isSyncingCourses = false
    /// 是否正在同步乐学 DDL。
    @Published private(set) var isSyncingDDL = false
    /// 是否正在加载空教室元数据（校区/教学楼）。
    @Published private(set) var isLoadingClassroomMeta = false
    /// 是否正在加载空教室结果。
    @Published private(set) var isLoadingClassrooms = false
    /// 首次进入空教室页且尚无结果时，是否显示一个无文案的加载指示。
    @Published private(set) var shouldShowInitialClassroomSpinner = false
    @Published private(set) var campuses: [CampusRecord] = []
    @Published private(set) var buildings: [BuildingRecord] = []
    @Published private(set) var classroomAvailabilities: [ClassroomAvailability] = []
    @Published var selectedWeek = 1
    @Published var selectedCourseScheduleIndex = 0
    @Published var selectedBuildingID = ""
    @Published var notice: ScheduleNotice?
    @Published private(set) var smsChallenge: BITLoginAuthenticationChallenge?
    @Published private(set) var smsVerificationError: String?
    @Published private(set) var isSubmittingSMSCode = false
    /// 学校提供的可切换学期列表。
    @Published private(set) var availableTerms: [String] = []
    @Published private(set) var isLoadingTerms = false
    @Published private(set) var hasLoadedAvailableTerms = false
    @Published private(set) var syncingTerm: String?

    private let service: any ScheduleServicing
    private let classroomCoordinator = ScheduleClassroomCoordinator()
    private let courseSyncCoordinator = ScheduleCourseSyncCoordinator()
    private var hasLoaded = false
    /// 当前教学楼最近一次拉下来的原始空教室记录。
    private var classroomRecords: [ClassroomRecord] = []
    /// 监听设置和缓存变化，用于跨页面同步。
    private var cacheObserver: NSObjectProtocol?

    /// 初始化日程状态机，并监听缓存变化通知。
    init(service: any ScheduleServicing) {
        self.service = service
        cacheObserver = NotificationCenter.default.addObserver(
            forName: .scheduleCacheDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                // 设置中心修改课表显示项后，这里直接从磁盘重载，避免页面和设置页双向手搓同步。
                self.reloadFromDisk()
            }
        }
    }

    convenience init() {
        self.init(service: ScheduleService())
    }

    deinit {
        if let cacheObserver {
            NotificationCenter.default.removeObserver(cacheObserver)
        }
    }

    /// 切换账号后重置页面内存态，并从新账号的隔离缓存重新开始加载。
    func resetForCurrentAccount() {
        classroomCoordinator.reset()
        hasLoaded = false
        isLoadingCache = true
        isSyncingCourses = false
        isSyncingDDL = false
        isLoadingClassroomMeta = false
        isLoadingClassrooms = false
        shouldShowInitialClassroomSpinner = false
        campuses = []
        buildings = []
        classroomRecords = []
        classroomAvailabilities = []
        availableTerms = []
        hasLoadedAvailableTerms = false
        selectedBuildingID = ""
        smsChallenge = nil
        smsVerificationError = nil
        courseSyncCoordinator.reset()
        notice = nil
        reloadFromDisk()
    }

    /// 构造日程模块统一使用的本地校验错误。
    ///
    /// 这类错误都属于“用户输入不合法”或“本地配置格式不正确”，
    /// 不需要为每个分支再重复写一遍相同的 domain / code。
    private func scheduleValidationError(_ message: String) -> NSError {
        NSError(
            domain: "BIT101.Schedule",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    /// DDL 列表默认向前展示的天数。
    var beforeDay: Int { cache.ddlBeforeDay }
    /// DDL 列表默认向后保留的天数。
    var afterDay: Int { cache.ddlAfterDay }

    /// 首周日期的展示文本。
    var firstDayDescription: String {
        guard let firstDay = activeCourseSchedule.firstDay else {
            return "未同步"
        }
        return ScheduleDateCodec.formatDate(firstDay)
    }

    /// 当前显示课表的标题。
    var activeCourseScheduleTitle: String {
        activeCourseSchedule.title
    }

    /// 当前课表向后浏览的最大周数，至少覆盖课程最后一周和按首周日期推导出的当前周。
    var maxWeek: Int {
        max(activeCourseSchedule.courses.flatMap(\.weeks).max() ?? 1, resolvedCurrentWeek())
    }

    /// 是否已经同步到任何课程或考试数据。
    var hasCourseData: Bool {
        activeCourseSchedule.hasCourseData
    }

    /// 所有可切换的课表列表。
    ///
    /// 顺序固定为：我的课表在前，导入的分享课表依次排在后面。
    var courseSchedules: [CourseScheduleVariant] {
        let primary = CourseScheduleVariant(
            id: "__primary__",
            title: cache.primaryScheduleTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "课表" : cache.primaryScheduleTitle,
            isPrimary: true,
            currentTerm: cache.currentTerm,
            firstDayString: cache.firstDayString,
            timeTable: cache.timeTable,
            courses: cache.courses,
            exams: cache.exams,
            customSchedules: cache.customSchedules
        )

        let shared = cache.sharedSchedules.map { record in
            CourseScheduleVariant(
                id: record.id,
                title: record.title,
                isPrimary: false,
                currentTerm: record.currentTerm,
                firstDayString: record.firstDayString,
                timeTable: record.timeTable,
                courses: record.courses,
                exams: [],
                customSchedules: []
            )
        }

        return [primary] + shared
    }

    /// 当前正在展示的那一份课表。
    var activeCourseSchedule: CourseScheduleVariant {
        let variants = courseSchedules
        guard !variants.isEmpty else {
            return CourseScheduleVariant(
                id: "__primary__",
                title: "我的课表",
                isPrimary: true,
                currentTerm: "",
                firstDayString: "",
                timeTable: cache.timeTable,
                courses: [],
                exams: [],
                customSchedules: []
            )
        }

        let normalizedIndex = min(max(selectedCourseScheduleIndex, 0), variants.count - 1)
        return variants[normalizedIndex]
    }

    /// 是否已经拿到乐学订阅地址。
    var hasLexueCalendarURL: Bool {
        !cache.lexueCalendarURL.isEmpty
    }

    /// 经过时间窗口裁剪后的 DDL 列表。
    var visibleDDLEvents: [DDLEventRecord] {
        let threshold = Date().addingTimeInterval(TimeInterval(-afterDay * 24 * 3600))
        return cache.ddlEvents
            .filter { $0.dueAt >= threshold }
            .sorted { lhs, rhs in
                if lhs.done != rhs.done {
                    return !lhs.done
                }
                return lhs.dueAt < rhs.dueAt
            }
    }

    /// 首次进入日程页时从本地磁盘恢复缓存。
    ///
    /// 日程页优先展示本地缓存，而不是一上来就强制联网同步；这样冷启动更快，也更稳定。
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true

        // 页面先读本地缓存，确保一打开就有内容，避免每次冷启动都重新同步。
        reloadFromDisk()
        #if canImport(CloudKit)
        await ScheduleCloudSyncManager.shared.refreshFromCloudIfNeeded()
        #endif
        isLoadingCache = false
    }

    /// 同步课程表、考试安排和首周日期。
    ///
    /// 同步成功后会立刻更新本地缓存，从而驱动课表页、小组件和灵动岛一起刷新。
    func syncCourses(term: String? = nil) async {
        guard !isSyncingCourses, !isLoadingTerms, !isSubmittingSMSCode, smsChallenge == nil else { return }
        isSyncingCourses = true
        syncingTerm = term
        defer {
            isSyncingCourses = false
            syncingTerm = nil
        }

        do {
            let payload = try await service.syncCourses(term: term)
            applyCourseSyncPayload(payload)
            courseSyncCoordinator.reset()
        } catch ScheduleServiceError.secondFactorRequired(let challenge) {
            courseSyncCoordinator.waitForCourseAuthentication(term: term)
            smsChallenge = challenge
            smsVerificationError = nil
        } catch ScheduleServiceError.challengeInvalid(let message) {
            smsChallenge = nil
            smsVerificationError = nil
            courseSyncCoordinator.reset()
            notice = ScheduleNotice(title: "验证已失效", message: message)
        } catch {
            notice = ScheduleNotice(title: "课表同步失败", message: error.localizedDescription)
        }
    }

    /// 重新获取当前正在显示的目标学期，而不是重新询问学校的“当前学期”标记。
    ///
    /// 用户主动切到其它学期后，普通的“获取/重新同步”必须留在该学期；只有尚未保存
    /// 任何学期编码的首次同步才传 `nil`，让学校返回当前学期。
    func syncSelectedTerm() async {
        let term = cache.currentTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        await syncCourses(term: term.isEmpty ? nil : term)
    }

    /// 加载学校接口实际返回的学期列表，不在本地补充、推算或保留接口未返回的学期。
    func loadAvailableTerms() async {
        guard !isLoadingTerms, !isSyncingCourses, smsChallenge == nil else { return }
        isLoadingTerms = true
        defer { isLoadingTerms = false }

        do {
            availableTerms = try await service.fetchAvailableTerms()
            hasLoadedAvailableTerms = true
            courseSyncCoordinator.reset()
        } catch ScheduleServiceError.secondFactorRequired(let challenge) {
            courseSyncCoordinator.waitForAvailableTermsAuthentication()
            smsChallenge = challenge
            smsVerificationError = nil
        } catch {
            hasLoadedAvailableTerms = true
            notice = ScheduleNotice(title: "学期列表加载失败", message: error.localizedDescription)
        }
    }

    /// 提交短信一次性验证码，并继续被暂停的课表同步。
    func submitSMSCode(_ code: String) async {
        guard let challenge = smsChallenge, !isSubmittingSMSCode else { return }
        let normalizedCode = code.filter(\.isNumber)
        guard (4 ... 8).contains(normalizedCode.count) else {
            smsVerificationError = "请输入短信中的 4 至 8 位验证码。"
            return
        }

        isSubmittingSMSCode = true
        smsVerificationError = nil
        defer { isSubmittingSMSCode = false }

        do {
            if courseSyncCoordinator.continuation == .availableTerms {
                try await service.submitSMSCodeForTeachingCenterAuthentication(
                    normalizedCode,
                    for: challenge
                )
                smsChallenge = nil
                courseSyncCoordinator.reset()
                await loadAvailableTerms()
                return
            }

            let payload = try await service.submitSMSCode(
                normalizedCode,
                for: challenge,
                term: courseSyncCoordinator.courseSyncTerm
            )
            applyCourseSyncPayload(payload)
            smsChallenge = nil
            courseSyncCoordinator.reset()
        } catch ScheduleServiceError.challengeInvalid(let message) {
            smsChallenge = nil
            smsVerificationError = nil
            courseSyncCoordinator.reset()
            notice = ScheduleNotice(title: "验证已失效", message: message)
        } catch {
            smsVerificationError = error.localizedDescription
        }
    }

    func dismissSMSChallenge() {
        guard !isSubmittingSMSCode else { return }
        smsChallenge = nil
        smsVerificationError = nil
        courseSyncCoordinator.reset()
    }

    private func applyCourseSyncPayload(_ payload: CourseSyncPayload) {
        cache.currentTerm = payload.term
        cache.firstDayString = payload.firstDayString
        cache.coursesUpdatedAt = Date()
        cache.courses = payload.courses
        cache.cachedCoursesByTerm[payload.term] = payload.courses
        cache.exams = payload.exams
        selectedWeek = resolvedCurrentWeek()
        persist()
    }

    /// 同步乐学 DDL，并保留本地手动项目和完成状态。
    @discardableResult
    func syncDDL(showSuccessNotice: Bool = true, showErrorNotice: Bool = true) async -> Bool {
        guard !isSyncingDDL else { return false }
        isSyncingDDL = true
        defer { isSyncingDDL = false }

        do {
            // 手动创建的 DDL 与乐学同步内容并存；同步时要保留手动项目和 done 状态。
            let manualEvents = cache.ddlEvents.filter { $0.group != "lexue" }
            let payload = try await service.syncDDLEvents(
                existingEvents: cache.ddlEvents,
                storedURL: cache.lexueCalendarURL
            )
            cache.lexueCalendarURL = payload.url
            cache.ddlEvents = (manualEvents + payload.events).sorted { $0.dueAt < $1.dueAt }
            persist()
            if showSuccessNotice {
                notice = ScheduleNotice(
                    title: "DDL 同步成功",
                    message: payload.events.isEmpty ? "已更新成功，当前没有乐学日程。" : "已更新成功，共同步 \(payload.events.count) 条乐学日程。"
                )
            }
            return true
        } catch {
            if showErrorNotice {
                notice = ScheduleNotice(title: "DDL 同步失败", message: error.localizedDescription)
            }
            return false
        }
    }

    /// 强制重新抓取乐学日历订阅地址。
    ///
    /// 主要用在订阅链接失效或用户主动要求重置时。
    func refreshLexueCalendarURL(showSuccessNotice: Bool = true) async {
        isSyncingDDL = true
        defer { isSyncingDDL = false }

        do {
            cache.lexueCalendarURL = try await service.refreshLexueCalendarURL()
            persist()
            if showSuccessNotice {
                notice = ScheduleNotice(title: "订阅链接更新成功", message: "已重新获取乐学订阅链接。")
            }
        } catch {
            notice = ScheduleNotice(title: "订阅链接获取失败", message: error.localizedDescription)
        }
    }

    /// 切换某条 DDL 的完成状态。
    ///
    /// `done` 是纯本地状态，不会回写乐学网页端。
    func toggleDDLDone(_ event: DDLEventRecord) {
        guard let index = cache.ddlEvents.firstIndex(where: { $0.id == event.id }) else {
            return
        }

        cache.ddlEvents[index].done.toggle()
        persist()
    }

    /// 把已有 DDL 记录转成编辑草稿。
    func ddlDraft(for event: DDLEventRecord?) -> DDLDraft {
        guard let event else { return DDLDraft() }
        return DDLDraft(title: event.title, dueAt: event.dueAt, text: event.text)
    }

    /// 新增一条本地 DDL。
    ///
    /// 手动 DDL 与乐学同步项并存，但会用 `group` 字段区分来源。
    func addDDL(_ draft: DDLDraft) throws {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw scheduleValidationError("标题不能为空。")
        }

        cache.ddlEvents.append(
            DDLEventRecord(
                id: UUID().uuidString,
                group: "main",
                title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                text: draft.text,
                dueAt: draft.dueAt,
                done: false
            )
        )
        cache.ddlEvents.sort { $0.dueAt < $1.dueAt }
        persist()
    }

    /// 更新一条已有的本地 DDL。
    func updateDDL(id: String, draft: DDLDraft) throws {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw scheduleValidationError("标题不能为空。")
        }
        guard let index = cache.ddlEvents.firstIndex(where: { $0.id == id }) else { return }

        cache.ddlEvents[index].title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        cache.ddlEvents[index].text = draft.text
        cache.ddlEvents[index].dueAt = draft.dueAt
        persist()
    }

    /// 删除指定 DDL。
    func deleteDDL(id: String) {
        cache.ddlEvents.removeAll { $0.id == id }
        persist()
    }

    /// 修改 DDL 提前提醒窗口。
    func setDDLBeforeDay(_ value: Int) {
        cache.ddlBeforeDay = max(value, 0)
        persist()
    }

    /// 修改 DDL 过期后仍保留显示的窗口。
    func setDDLAfterDay(_ value: Int) {
        cache.ddlAfterDay = max(value, 0)
        persist()
    }

    /// 课表周次左移一周。
    func previousWeek() {
        selectedWeek = ScheduleWeekCodec.previousWeek(before: selectedWeek)
    }

    /// 课表周次右移一周。
    func nextWeek() {
        selectedWeek = ScheduleWeekCodec.nextWeek(after: selectedWeek)
    }

    /// 把周次快速重置到当前周。
    func resetToCurrentWeek() {
        selectedWeek = resolvedCurrentWeek()
    }

    /// 手动修正当前课表的第一周起始日期。
    ///
    /// 正常切换学期时会自动使用学校按学期返回的第一周日期；这里只作为学校数据尚未更新
    /// 或临时校历调整时的覆盖入口。
    func setFirstDay(_ date: Date) {
        cache.firstDayString = ScheduleDateCodec.formatDate(ScheduleDateCodec.monday(containing: date))
        selectedWeek = resolvedCurrentWeek()
        persist()
    }

    /// 在“我的课表”和导入课表之间循环切换。
    ///
    /// 这里故意做成 loop 语义：无论向上还是向下滑，到边界后都回卷。
    func cycleCourseSchedule(step: Int) {
        let variants = courseSchedules
        guard variants.count > 1 else { return }

        let count = variants.count
        let nextIndex = (selectedCourseScheduleIndex + step).modulo(count)
        selectedCourseScheduleIndex = nextIndex
    }

    /// 重命名当前账号自己的课表。
    func renamePrimarySchedule(to title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw scheduleValidationError("课表名称不能为空。")
        }
        guard trimmed.count <= scheduleNameCharacterLimit else {
            throw scheduleValidationError("课表名称最多 8 个字符。")
        }
        cache.primaryScheduleTitle = trimmed
        persist()
    }

    /// 重命名一份导入的分享课表。
    func renameSharedSchedule(id: String, to title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw scheduleValidationError("课表名称不能为空。")
        }
        guard trimmed.count <= scheduleNameCharacterLimit else {
            throw scheduleValidationError("课表名称最多 8 个字符。")
        }
        guard let index = cache.sharedSchedules.firstIndex(where: { $0.id == id }) else { return }
        cache.sharedSchedules[index].title = trimmed
        persist()
    }

    /// 删除一份导入的分享课表。
    func deleteSharedSchedule(id: String) {
        cache.sharedSchedules.removeAll { $0.id == id }
        selectedCourseScheduleIndex = min(selectedCourseScheduleIndex, max(courseSchedules.count - 1, 0))
        persist()
    }

    /// 设置是否显示周六课程。
    func setShowSaturday(_ value: Bool) {
        cache.showSaturday = value
        persist()
    }

    /// 设置是否显示周日课程。
    func setShowSunday(_ value: Bool) {
        cache.showSunday = value
        persist()
    }

    /// 设置课程块边框显示。
    func setShowBorder(_ value: Bool) {
        cache.showBorder = value
        persist()
    }

    /// 设置是否高亮今天对应的课程列。
    func setShowHighlightToday(_ value: Bool) {
        cache.showHighlightToday = value
        persist()
    }

    /// 设置是否显示课表网格分割线。
    func setShowDivider(_ value: Bool) {
        cache.showDivider = value
        persist()
    }

    /// 设置是否显示当前时间线。
    func setShowCurrentTime(_ value: Bool) {
        cache.showCurrentTime = value
        persist()
    }

    /// 设置是否在课表网格中显示考试块。
    func setShowExamInfo(_ value: Bool) {
        cache.showExamInfo = value
        persist()
    }

    func setICloudSyncEnabled(_ value: Bool) {
        guard cache.iCloudSyncEnabled != value else { return }
        cache.iCloudSyncEnabled = value

        if value {
            persist(source: .localWithoutCloudPush)
            #if canImport(CloudKit)
            let localCache = cache
            Task {
                await ScheduleCloudSyncManager.shared.reconcileAfterEnabling(localCache: localCache)
            }
            #endif
        } else {
            persist(source: .localWithoutCloudPush)
        }
    }

    /// 设置是否启用课程提醒 Live Activity。
    func setShowCourseLiveActivityReminder(_ value: Bool) {
        cache.showCourseLiveActivityReminder = value
        persist()

        if value {
            Task {
                _ = await ScheduleLiveActivityManager.shared.requestNotificationAuthorizationIfNeeded()
                await ScheduleLiveActivityManager.shared.refreshFromCurrentCache(trigger: "reminder_toggle_enabled")
            }
        }
    }

    /// 设置灵动岛/锁屏提醒的提前显示阈值。
    func setCourseLiveActivityLeadMinutes(_ value: Int) {
        cache.courseLiveActivityLeadMinutes = min(max(value, 1), 60)
        persist()
    }

    /// 从多行文本解析并替换整份时间表。
    ///
    /// 每行格式固定为 `开始时间,结束时间`；这里会同时校验顺序和重叠。
    func setTimeTable(from text: String) throws {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var timeTable: [TimeSlot] = []
        for (index, line) in lines.enumerated() {
            let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else {
                throw scheduleValidationError("时间表格式错误。")
            }

            let start = parts[0]
            let end = parts[1]
            let startMinutes = TimeSlot.parseMinutes(start)
            let endMinutes = TimeSlot.parseMinutes(end)
            guard endMinutes > startMinutes else {
                throw scheduleValidationError("时间表格式错误。")
            }
            if let last = timeTable.last, startMinutes <= last.endMinutes {
                throw scheduleValidationError("时间表格式错误。")
            }

            timeTable.append(TimeSlot(id: index + 1, start: start, end: end))
        }

        guard !timeTable.isEmpty else {
            throw scheduleValidationError("时间表格式错误。")
        }

        cache.timeTable = timeTable
        persist()
    }

    /// 生成新增课程用的默认草稿。
    ///
    /// 周次默认留空，避免把“当前周”误当成用户真正想填的周次范围。
    /// 节次则给一个最常见的双节课起点。
    func courseDraft(for week: Int) -> CourseDraft {
        CourseDraft(
            weekday: 1,
            startSection: 1,
            endSection: min(2, max(cache.timeTable.count, 1)),
            weeksText: ""
        )
    }

    /// 把已有课程转成编辑草稿。
    ///
    /// - Parameter editsOccurrenceOnly: 为 `true` 时，草稿周次固定成当前这一周，
    ///   用于“调这节课”把一门重复课拆成一次性调整后的单次课程。
    func courseDraft(for record: CourseRecord, week: Int, editsOccurrenceOnly: Bool) -> CourseDraft {
        CourseDraft(
            title: record.name,
            teacher: record.teacher,
            classroom: record.classroom,
            weekday: record.weekday,
            startSection: record.startSection,
            endSection: record.endSection,
            weeksText: editsOccurrenceOnly ? "\(week)" : ScheduleCourseEditor.formatWeeks(record.weeks)
        )
    }

    /// 新增一条本地课程。
    ///
    /// 这里不会回写学校接口，而是只修改本地缓存，用于补录临时课程或手动修正。
    func addCourse(_ draft: CourseDraft) throws {
        let resolved = try ScheduleCourseEditor.resolve(draft)

        cache.courses.append(
            CourseRecord(
                id: UUID().uuidString,
                term: cache.currentTerm,
                name: resolved.title,
                teacher: resolved.teacher,
                classroom: resolved.classroom,
                description: "",
                weeks: resolved.weeks,
                weekday: resolved.weekday,
                startSection: resolved.startSection,
                endSection: resolved.endSection,
                campus: "",
                number: "",
                credit: 0,
                hour: 0,
                type: "",
                category: "",
                department: ""
            )
        )
        persist()
    }

    /// 更新整门课程。
    func updateCourse(id: String, draft: CourseDraft) throws {
        guard let index = cache.courses.firstIndex(where: { $0.id == id }) else { return }
        let resolved = try ScheduleCourseEditor.resolve(draft)
        let original = cache.courses[index]

        cache.courses[index] = CourseRecord(
            id: original.id,
            term: original.term,
            name: resolved.title,
            teacher: resolved.teacher,
            classroom: resolved.classroom,
            description: original.description,
            weeks: resolved.weeks,
            weekday: resolved.weekday,
            startSection: resolved.startSection,
            endSection: resolved.endSection,
            campus: original.campus,
            number: original.number,
            credit: original.credit,
            hour: original.hour,
            type: original.type,
            category: original.category,
            department: original.department
        )
        persist()
    }

    /// 只调整当前周这一节课。
    ///
    /// 实现方式是把原课程里的当前周拆出去，生成一条只覆盖这一周的新课程记录；
    /// 其它周仍保留原来的排课信息。
    func updateCourseOccurrence(id: String, week: Int, draft: CourseDraft) throws {
        guard let index = cache.courses.firstIndex(where: { $0.id == id }) else { return }
        let original = cache.courses[index]
        let resolved = try ScheduleCourseEditor.resolve(draft, fixedWeeks: [week])
        let adjustedCourse = CourseRecord(
            id: original.weeks == [week] ? original.id : UUID().uuidString,
            term: original.term,
            name: resolved.title,
            teacher: resolved.teacher,
            classroom: resolved.classroom,
            description: original.description,
            weeks: [week],
            weekday: resolved.weekday,
            startSection: resolved.startSection,
            endSection: resolved.endSection,
            campus: original.campus,
            number: original.number,
            credit: original.credit,
            hour: original.hour,
            type: original.type,
            category: original.category,
            department: original.department
        )

        if original.weeks == [week] {
            cache.courses[index] = adjustedCourse
        } else {
            let remainingWeeks = original.weeks.filter { $0 != week }
            cache.courses[index] = CourseRecord(
                id: original.id,
                term: original.term,
                name: original.name,
                teacher: original.teacher,
                classroom: original.classroom,
                description: original.description,
                weeks: remainingWeeks,
                weekday: original.weekday,
                startSection: original.startSection,
                endSection: original.endSection,
                campus: original.campus,
                number: original.number,
                credit: original.credit,
                hour: original.hour,
                type: original.type,
                category: original.category,
                department: original.department
            )
            cache.courses.append(adjustedCourse)
        }

        persist()
    }

    /// 删除课程在当前周的这一节显示。
    ///
    /// 如果删完后课程已不再覆盖任何周次，则直接移除整门课。
    func deleteCourseOccurrence(id: String, week: Int) {
        guard let index = cache.courses.firstIndex(where: { $0.id == id }) else { return }

        let course = cache.courses[index]
        let remainingWeeks = course.weeks.filter { $0 != week }

        if remainingWeeks.isEmpty {
            cache.courses.remove(at: index)
        } else {
            cache.courses[index] = CourseRecord(
                id: course.id,
                term: course.term,
                name: course.name,
                teacher: course.teacher,
                classroom: course.classroom,
                description: course.description,
                weeks: remainingWeeks,
                weekday: course.weekday,
                startSection: course.startSection,
                endSection: course.endSection,
                campus: course.campus,
                number: course.number,
                credit: course.credit,
                hour: course.hour,
                type: course.type,
                category: course.category,
                department: course.department
            )
        }
        persist()
    }

    /// 删除整门课程。
    func deleteCourse(id: String) {
        cache.courses.removeAll { $0.id == id }
        persist()
    }

    /// 将指定日期设置为放假：只清空这一天的课程，不影响考试和自定义日程。
    func clearCourses(week: Int, weekday: Int) {
        cache.courses = coursesRemovingOccurrences(from: cache.courses, week: week, weekday: weekday)
        persist()
    }

    /// 将某一天的课程调至目标日期。
    ///
    /// 调课语义：
    /// - 原日期课程会被清空。
    /// - 目标日期已有课程会被覆盖。
    /// - 只移动课程，不移动考试和自定义日程。
    func transferCourses(fromWeek: Int, fromWeekday: Int, to targetDate: Date) throws {
        let target = try courseDayContext(for: targetDate)
        let sourceCourses = cache.courses.filter { course in
            course.weekday == fromWeekday && course.weeks.contains(fromWeek)
        }

        var nextCourses = coursesRemovingOccurrences(from: cache.courses, week: fromWeek, weekday: fromWeekday)
        nextCourses = coursesRemovingOccurrences(from: nextCourses, week: target.week, weekday: target.weekday)
        nextCourses.append(contentsOf: sourceCourses.map { course in
            CourseRecord(
                id: UUID().uuidString,
                term: course.term,
                name: course.name,
                teacher: course.teacher,
                classroom: course.classroom,
                description: course.description,
                weeks: [target.week],
                weekday: target.weekday,
                startSection: course.startSection,
                endSection: course.endSection,
                campus: course.campus,
                number: course.number,
                credit: course.credit,
                hour: course.hour,
                type: course.type,
                category: course.category,
                department: course.department
            )
        })

        cache.courses = nextCourses
        persist()
    }

    /// 导入一份分享的课表载荷。
    ///
    /// 导入后的课表会作为一份“只读分身”追加到当前账号本地缓存中，
    /// 不覆盖我自己的课表、DDL、自定义日程和显示设置。
    func importSharedSchedule(_ payload: ScheduleExportPayload) throws {
        guard !payload.timeTable.isEmpty else {
            throw scheduleValidationError("分享的课表缺少时间表。")
        }

        let titleBase = payload.currentTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = String((titleBase.isEmpty ? "分享课表" : "\(titleBase)课表").prefix(scheduleNameCharacterLimit))
        cache.sharedSchedules.append(
            SharedScheduleRecord(
                title: title,
                payload: payload
            )
        )
        persist()
        selectedCourseScheduleIndex = courseSchedules.count - 1
        selectedWeek = resolvedCurrentWeek()
    }

    /// 把已有自定义日程转成编辑草稿；如果为空则生成一份默认草稿。
    func customScheduleDraft(for record: CustomScheduleRecord?) -> CustomScheduleDraft {
        guard let record else {
            let now = Date()
            let end = Calendar.current.date(byAdding: .minute, value: 60, to: now) ?? now
            return CustomScheduleDraft(date: now, beginTime: now, endTime: end)
        }

        return CustomScheduleDraft(
            title: record.title,
            subtitle: record.subtitle,
            description: record.description,
            date: ScheduleDateCodec.parseDate(record.dateString) ?? Date(),
            beginTime: ScheduleDateCodec.parseTime(record.beginTime) ?? Date(),
            endTime: ScheduleDateCodec.parseTime(record.endTime) ?? Date()
        )
    }

    /// 新增一条自定义日程。
    func addCustomSchedule(_ draft: CustomScheduleDraft) throws {
        let beginMinutes = ScheduleDateCodec.minutesOfDay(from: draft.beginTime)
        let endMinutes = ScheduleDateCodec.minutesOfDay(from: draft.endTime)
        guard endMinutes > beginMinutes else {
            throw scheduleValidationError("结束时间必须晚于开始时间。")
        }

        cache.customSchedules.append(
            CustomScheduleRecord(
                id: UUID().uuidString,
                title: draft.title,
                subtitle: draft.subtitle,
                description: draft.description,
                dateString: ScheduleDateCodec.formatDate(draft.date),
                beginTime: ScheduleDateCodec.formatTime(draft.beginTime),
                endTime: ScheduleDateCodec.formatTime(draft.endTime)
            )
        )
        persist()
    }

    /// 更新指定自定义日程。
    func updateCustomSchedule(id: String, draft: CustomScheduleDraft) throws {
        let beginMinutes = ScheduleDateCodec.minutesOfDay(from: draft.beginTime)
        let endMinutes = ScheduleDateCodec.minutesOfDay(from: draft.endTime)
        guard endMinutes > beginMinutes else {
            throw scheduleValidationError("结束时间必须晚于开始时间。")
        }

        guard let index = cache.customSchedules.firstIndex(where: { $0.id == id }) else { return }
        cache.customSchedules[index].title = draft.title
        cache.customSchedules[index].subtitle = draft.subtitle
        cache.customSchedules[index].description = draft.description
        cache.customSchedules[index].dateString = ScheduleDateCodec.formatDate(draft.date)
        cache.customSchedules[index].beginTime = ScheduleDateCodec.formatTime(draft.beginTime)
        cache.customSchedules[index].endTime = ScheduleDateCodec.formatTime(draft.endTime)
        persist()
    }

    /// 删除指定自定义日程。
    func deleteCustomSchedule(id: String) {
        cache.customSchedules.removeAll { $0.id == id }
        persist()
    }

    /// 把一组课程中的某个具体周次 / 星期出现移除。
    private func coursesRemovingOccurrences(from courses: [CourseRecord], week: Int, weekday: Int) -> [CourseRecord] {
        courses.compactMap { course in
            guard course.weekday == weekday, course.weeks.contains(week) else {
                return course
            }

            let remainingWeeks = course.weeks.filter { $0 != week }
            guard !remainingWeeks.isEmpty else { return nil }

            return CourseRecord(
                id: course.id,
                term: course.term,
                name: course.name,
                teacher: course.teacher,
                classroom: course.classroom,
                description: course.description,
                weeks: remainingWeeks,
                weekday: course.weekday,
                startSection: course.startSection,
                endSection: course.endSection,
                campus: course.campus,
                number: course.number,
                credit: course.credit,
                hour: course.hour,
                type: course.type,
                category: course.category,
                department: course.department
            )
        }
    }

    /// 根据日期计算它落在当前课表首周后的第几周、周几。
    private func courseDayContext(for date: Date) throws -> (week: Int, weekday: Int) {
        guard let firstDay = cache.firstDay else {
            throw scheduleValidationError("当前课表缺少首周日期，无法调课。")
        }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: firstDay)
        let target = calendar.startOfDay(for: date)
        let dayOffset = calendar.dateComponents([.day], from: start, to: target).day ?? 0
        let weekOffset = ScheduleWeekCodec.weekOffset(
            forWeekNumber: ScheduleWeekCodec.weekNumber(forDayOffset: dayOffset)
        )
        let weekdayOffset = dayOffset - weekOffset * 7
        return (week: ScheduleWeekCodec.weekNumber(forDayOffset: dayOffset), weekday: weekdayOffset + 1)
    }

    /// 进入空教室页前的统一预热入口。
    ///
    /// 这里会做三件事：
    /// 1. 按当前时间块重设节次筛选。
    /// 2. 加载校区/教学楼元数据。
    /// 3. 必要时刷新当前楼栋的空教室结果。
    func prepareClassroomIfNeeded(showErrors: Bool = true) async {
        guard classroomCoordinator.claimAutomaticPreparation() else { return }

        applyCurrentClassroomSectionBlock()
        let hasCachedMeta = applyCachedClassroomMetaIfAvailable()
        if hasCachedMeta {
            refreshClassroomMetaInBackgroundIfNeeded()
        }

        let requestID = beginClassroomRequest(clearsLoadingState: false)
        defer {
            finishClassroomRequestIfCurrent(requestID)
        }

        do {
            if campuses.isEmpty || buildings.isEmpty {
                try await loadClassroomMeta(requestID: requestID)
            }

            guard isCurrentClassroomRequest(requestID) else { return }

            if selectedBuildingID.isEmpty {
                selectedBuildingID = cache.selectedBuildingID
            }

            if classroomRecords.isEmpty, !selectedBuildingID.isEmpty {
                try await refreshClassrooms(requestID: requestID)
            }
        } catch {
            if showErrors {
                handleClassroomRequestError(error, requestID: requestID, title: "空教室同步失败")
            } else {
                finishClassroomRequestIfCurrent(requestID)
            }
        }
    }

    /// 按自动更新策略静默刷新当前课表。
    ///
    /// 成功时直接沿用普通同步的缓存写回；失败时返回错误，由应用壳层统一弹窗，避免
    /// 自动任务产生只能在日程页才能看到的局部提示。短信验证不会在启动时主动弹出。
    func autoRefreshCourses() async -> ScheduleNotice? {
        guard !isSyncingCourses, !isLoadingTerms, !isSubmittingSMSCode, smsChallenge == nil else {
            return nil
        }

        isSyncingCourses = true
        let term = cache.currentTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        syncingTerm = term.isEmpty ? nil : term
        defer {
            isSyncingCourses = false
            syncingTerm = nil
        }

        do {
            let payload = try await service.syncCourses(term: term.isEmpty ? nil : term)
            applyCourseSyncPayload(payload)
            return nil
        } catch ScheduleServiceError.secondFactorRequired {
            return ScheduleNotice(
                title: "课表自动更新失败",
                message: "本次更新需要短信验证，请在课表设置中手动同步。"
            )
        } catch {
            return ScheduleNotice(title: "课表自动更新失败", message: error.localizedDescription)
        }
    }

    /// 切换空教室查询校区。
    func selectCampus(code: String) async {
        guard code != cache.selectedCampusCode else { return }

        let requestID = beginClassroomRequest()
        defer {
            finishClassroomRequestIfCurrent(requestID)
        }
        cache.selectedCampusCode = code
        cache.selectedCampusName = campuses.first(where: { $0.code == code })?.name ?? ""
        selectedBuildingID = ""
        cache.selectedBuildingID = ""
        buildings = cache.cachedClassroomBuildingsByCampusCode[code] ?? []
        if !buildings.isEmpty {
            resolveSelectedBuildingIfNeeded(allowsPreferredBuilding: true)
        }
        classroomRecords = []
        classroomAvailabilities = []
        persist()

        do {
            try await loadBuildings(requestID: requestID)
            guard isCurrentClassroomRequest(requestID) else { return }
            if !selectedBuildingID.isEmpty {
                try await refreshClassrooms(requestID: requestID)
            }
        } catch {
            handleClassroomRequestError(error, requestID: requestID, title: "空教室同步失败")
        }
    }

    /// 切换当前教学楼并刷新空教室结果。
    func selectBuilding(id: String) async {
        guard id != selectedBuildingID else { return }

        let requestID = beginClassroomRequest()
        defer {
            finishClassroomRequestIfCurrent(requestID)
        }
        selectedBuildingID = id
        cache.selectedBuildingID = id
        isLoadingClassrooms = true
        classroomRecords = []
        classroomAvailabilities = []
        persist()

        do {
            try await refreshClassrooms(requestID: requestID)
        } catch {
            handleClassroomRequestError(error, requestID: requestID, title: "空教室同步失败")
        }
    }

    /// 更新空教室节次筛选结果。
    func setSelectedClassroomSectionIDs(_ values: [Int]) {
        cache.selectedClassroomSectionIDs = ClassroomAvailabilityCalculator.normalizedSections(values, in: cache.timeTable)
        persist()
        refreshClassroomAvailabilities()
    }

    /// 刷新当前教学楼的空教室状态。
    ///
    /// 如果当前学期编码还未知，会先补查学期，再请求教室占用。
    func refreshClassrooms() async {
        let requestID = beginClassroomRequest()
        defer {
            finishClassroomRequestIfCurrent(requestID)
        }
        do {
            try await refreshClassrooms(requestID: requestID)
        } catch {
            handleClassroomRequestError(error, requestID: requestID, title: "空教室同步失败")
        }
    }

    /// 当前教学楼的空教室状态刷新实现。
    ///
    /// 所有公开入口都会先分配 `requestID`，旧请求返回时不允许再回写 loading、结果或错误弹窗。
    private func refreshClassrooms(requestID: Int) async throws {
        defer {
            finishClassroomRequestIfCurrent(requestID)
        }

        if cache.currentTerm.isEmpty {
            let term = try await withClassroomRequestTimeout { [self] in
                try await service.fetchCurrentTermOnly()
            }
            guard isCurrentClassroomRequest(requestID) else { throw CancellationError() }
            cache.currentTerm = term
            persist()
        }

        guard isCurrentClassroomRequest(requestID), !selectedBuildingID.isEmpty else { return }

        isLoadingClassrooms = true
        defer {
            if isCurrentClassroomRequest(requestID) {
                isLoadingClassrooms = false
            }
        }

        let records = try await withClassroomRequestTimeout { [self] in
            try await service.fetchClassrooms(buildingID: selectedBuildingID, term: cache.currentTerm)
        }
        guard isCurrentClassroomRequest(requestID) else { throw CancellationError() }

        classroomRecords = records
        refreshClassroomAvailabilities()
    }

    /// 供页面下拉刷新使用的统一入口。
    ///
    /// 会先补齐校区/教学楼元数据，再刷新当前楼栋的空教室数据。
    func refreshClassroomPage() async {
        let requestID = beginClassroomRequest()
        defer {
            finishClassroomRequestIfCurrent(requestID)
        }

        do {
            if campuses.isEmpty || buildings.isEmpty {
                try await loadClassroomMeta(requestID: requestID)
            }

            guard isCurrentClassroomRequest(requestID), !selectedBuildingID.isEmpty else { return }
            try await refreshClassrooms(requestID: requestID)
        } catch {
            handleClassroomRequestError(error, requestID: requestID, title: "空教室同步失败")
        }
    }

    /// DDL 到期时间文案。
    func ddlDueText(for event: DDLEventRecord) -> String {
        ScheduleDateCodec.formatRelativeDateTime(event.dueAt)
    }

    /// DDL 剩余/超时文案。
    func ddlRemainingText(for event: DDLEventRecord) -> String {
        let minutes = Int(event.dueAt.timeIntervalSinceNow / 60)
        let absolute = abs(minutes)
        let day = absolute / 1440
        let hour = (absolute % 1440) / 60
        let minute = absolute % 60

        let body: String
        if day > 0 {
            body = "\(day)天 \(hour)小时 \(minute)分钟"
        } else if hour > 0 {
            body = "\(hour)小时 \(minute)分钟"
        } else {
            body = "\(minute)分钟"
        }

        return minutes < 0 ? "已过 \(body)" : "剩余 \(body)"
    }

    /// DDL 颜色语义。
    ///
    /// 这里返回字符串而不是 `Color`，是为了让 View 层自己决定具体颜色映射。
    func ddlTint(for event: DDLEventRecord) -> String {
        if event.done {
            return "gray"
        }

        let interval = event.dueAt.timeIntervalSinceNow
        if interval <= 0 {
            return "red"
        }

        if interval <= Double(beforeDay * 24 * 3600) {
            return "orange"
        }

        return "green"
    }

    /// 加载空教室所需的校区和教学楼元数据。
    private func loadClassroomMeta(requestID: Int) async throws {
        isLoadingClassroomMeta = true
        defer {
            if isCurrentClassroomRequest(requestID) {
                isLoadingClassroomMeta = false
            }
        }

        try await loadBuildings(requestID: requestID)

        if campuses.isEmpty {
            refreshClassroomMetaInBackgroundIfNeeded()
        }
    }

    /// 根据当前校区加载教学楼，并优先精确匹配“最近下一节课”的楼宇。
    private func loadBuildings(requestID: Int) async throws {
        let fetchedBuildings = try await withClassroomRequestTimeout { [self] in
            try await service.fetchBuildings(campusCode: cache.selectedCampusCode.isEmpty ? nil : cache.selectedCampusCode)
        }
        guard isCurrentClassroomRequest(requestID) else { throw CancellationError() }

        applyFetchedBuildingsForCurrentSelection(fetchedBuildings, allowsPreferredCampus: true, allowsPreferredBuilding: true)
    }

    /// 优先用上次成功获取的校区 / 教学楼元数据恢复选择器，避免进入页面时阻塞等待元数据接口。
    @discardableResult
    private func applyCachedClassroomMetaIfAvailable() -> Bool {
        guard !cache.cachedClassroomCampuses.isEmpty else { return false }

        campuses = cache.cachedClassroomCampuses
        resolveSelectedCampusIfNeeded(allowsPreferredCampus: true)

        let cachedBuildings = cache.cachedClassroomBuildingsByCampusCode[cache.selectedCampusCode] ?? []
        guard !cachedBuildings.isEmpty else {
            buildings = []
            selectedBuildingID = ""
            cache.selectedBuildingID = ""
            persist()
            return true
        }

        buildings = cachedBuildings
        resolveSelectedBuildingIfNeeded(allowsPreferredBuilding: true)
        return true
    }

    /// 有缓存时后台静默刷新低频变化的元数据；成功后更新缓存，失败不打扰用户。
    private func refreshClassroomMetaInBackgroundIfNeeded() {
        guard let token = classroomCoordinator.beginMetadataRefresh() else { return }

        Task { [weak self] in
            await self?.refreshClassroomMetaSilently(token: token)
        }
    }

    /// 后台刷新校区 / 教学楼元数据。
    ///
    /// 这条链路不参与空教室结果请求代号，也不弹错误；目的只是让下一次打开页面更快、更准。
    private func refreshClassroomMetaSilently(token: Int) async {
        defer {
            classroomCoordinator.finishMetadataRefresh(token)
        }

        do {
            let fetchedCampuses = try await withClassroomRequestTimeout { [self] in
                try await service.fetchCampuses()
            }
            guard classroomCoordinator.isCurrentMetadataRefresh(token) else { return }
            applyFetchedCampuses(fetchedCampuses, allowsPreferredCampus: false)

            guard !cache.selectedCampusCode.isEmpty else { return }

            let fetchedBuildings = try await withClassroomRequestTimeout { [self] in
                try await service.fetchBuildings(campusCode: cache.selectedCampusCode)
            }
            guard classroomCoordinator.isCurrentMetadataRefresh(token) else { return }
            applyFetchedBuildings(fetchedBuildings, for: cache.selectedCampusCode, allowsPreferredBuilding: false)
        } catch {
            return
        }
    }

    /// 写入新的校区元数据，并保持当前选择尽量稳定。
    private func applyFetchedCampuses(_ fetchedCampuses: [CampusRecord], allowsPreferredCampus: Bool) {
        guard !fetchedCampuses.isEmpty else { return }

        campuses = fetchedCampuses
        cache.cachedClassroomCampuses = fetchedCampuses
        resolveSelectedCampusIfNeeded(allowsPreferredCampus: allowsPreferredCampus)
        persist()
    }

    /// 写入教学楼元数据，并在未缓存校区列表时从教学楼字段反推出校区，避免首屏额外等待校区接口。
    private func applyFetchedBuildingsForCurrentSelection(
        _ fetchedBuildings: [BuildingRecord],
        allowsPreferredCampus: Bool,
        allowsPreferredBuilding: Bool
    ) {
        guard !fetchedBuildings.isEmpty else {
            applyFetchedBuildings([], for: cache.selectedCampusCode, allowsPreferredBuilding: allowsPreferredBuilding)
            return
        }

        let grouped = Dictionary(grouping: fetchedBuildings, by: \.campusCode)
        for (campusCode, campusBuildings) in grouped where !campusCode.isEmpty {
            cache.cachedClassroomBuildingsByCampusCode[campusCode] = campusBuildings
        }

        if campuses.isEmpty {
            let generatedCampuses = grouped.compactMap { campusCode, campusBuildings -> CampusRecord? in
                guard !campusCode.isEmpty else { return nil }
                let campusName = campusBuildings.first?.campusName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return CampusRecord(id: campusCode, name: campusName.isEmpty ? campusCode : campusName, code: campusCode)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

            if !generatedCampuses.isEmpty {
                campuses = generatedCampuses
                cache.cachedClassroomCampuses = generatedCampuses
            }
        }

        resolveSelectedCampusIfNeeded(allowsPreferredCampus: allowsPreferredCampus)

        let selectedCampusBuildings: [BuildingRecord]
        if !cache.selectedCampusCode.isEmpty, let campusBuildings = grouped[cache.selectedCampusCode] {
            selectedCampusBuildings = campusBuildings
        } else {
            selectedCampusBuildings = fetchedBuildings
        }

        buildings = selectedCampusBuildings
        if !cache.selectedCampusCode.isEmpty {
            cache.cachedClassroomBuildingsByCampusCode[cache.selectedCampusCode] = selectedCampusBuildings
        }
        resolveSelectedBuildingIfNeeded(allowsPreferredBuilding: allowsPreferredBuilding)
        persist()
    }

    /// 写入某个校区下的教学楼元数据，并保持当前选择尽量稳定。
    private func applyFetchedBuildings(
        _ fetchedBuildings: [BuildingRecord],
        for campusCode: String,
        allowsPreferredBuilding: Bool
    ) {
        buildings = fetchedBuildings
        cache.cachedClassroomBuildingsByCampusCode[campusCode] = fetchedBuildings
        resolveSelectedBuildingIfNeeded(allowsPreferredBuilding: allowsPreferredBuilding)
        persist()
    }

    /// 在校区列表变化后修正选中校区。
    private func resolveSelectedCampusIfNeeded(allowsPreferredCampus: Bool) {
        let validCampusCodes = Set(campuses.map(\.code))

        if validCampusCodes.contains(cache.selectedCampusCode) {
            cache.selectedCampusName = campuses.first(where: { $0.code == cache.selectedCampusCode })?.name ?? cache.selectedCampusName
            return
        }

        if allowsPreferredCampus, let preferredCampus = preferredCampus(from: campuses) {
            cache.selectedCampusCode = preferredCampus.code
            cache.selectedCampusName = preferredCampus.name
            return
        }

        cache.selectedCampusCode = campuses.first?.code ?? ""
        cache.selectedCampusName = campuses.first?.name ?? ""
    }

    /// 在教学楼列表变化后修正选中教学楼。
    private func resolveSelectedBuildingIfNeeded(allowsPreferredBuilding: Bool) {
        let validBuildingIDs = Set(buildings.map(\.buildingCode))
        let cachedBuildingID = cache.selectedBuildingID

        if validBuildingIDs.contains(selectedBuildingID) {
            cache.selectedBuildingID = selectedBuildingID
            return
        }

        if validBuildingIDs.contains(cachedBuildingID) {
            selectedBuildingID = cachedBuildingID
            return
        }

        if allowsPreferredBuilding, let preferredBuildingID = preferredBuildingID(from: buildings), validBuildingIDs.contains(preferredBuildingID) {
            selectedBuildingID = preferredBuildingID
            cache.selectedBuildingID = selectedBuildingID
            return
        }

        selectedBuildingID = buildings.first?.buildingCode ?? ""
        cache.selectedBuildingID = selectedBuildingID
    }

    /// 按当前节次筛选把原始占用记录转换为展示模型。
    private func refreshClassroomAvailabilities() {
        classroomAvailabilities = ClassroomAvailabilityCalculator.availabilities(
            records: classroomRecords,
            timeTable: cache.timeTable,
            selectedSections: cache.selectedClassroomSectionIDs,
            nowMinutes: currentMinutes()
        )
    }

    /// 节次筛选摘要文本。
    var classroomSectionFilterSummary: String {
        let selected = ClassroomAvailabilityCalculator.normalizedSections(
            cache.selectedClassroomSectionIDs,
            in: cache.timeTable
        )
        return selected.isEmpty ? "当前空闲" : ClassroomAvailabilityCalculator.sectionsText(selected)
    }

    /// 当前是否处于“当前空闲”模式。
    var isCurrentFreeClassroomMode: Bool {
        ClassroomAvailabilityCalculator.normalizedSections(
            cache.selectedClassroomSectionIDs,
            in: cache.timeTable
        ).isEmpty
    }

    /// 计算某间教室与当前筛选节次的命中摘要。
    func classroomMatchedSectionsText(for availability: ClassroomAvailability) -> String {
        ClassroomAvailabilityCalculator.matchedSectionsText(
            freeSections: availability.freeSections,
            selectedSections: cache.selectedClassroomSectionIDs,
            timeTable: cache.timeTable
        )
    }

    /// 根据首周日期推导当前周次。
    private func resolvedCurrentWeek() -> Int {
        guard let firstDay = cache.firstDay else {
            return 1
        }

        let start = Calendar.current.startOfDay(for: firstDay)
        let today = Calendar.current.startOfDay(for: Date())
        let diff = Calendar.current.dateComponents([.day], from: start, to: today).day ?? 0
        return ScheduleWeekCodec.weekNumber(forDayOffset: diff)
    }

    /// 当前时间在一天中的分钟偏移。
    private func currentMinutes() -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    /// 统一兼容任务取消错误。
    private func isCancellation(_ error: Error) -> Bool {
        TaskCancellation.matches(error)
    }

    /// 开始一轮新的空教室请求，并让所有旧请求失去 UI 回写资格。
    private func beginClassroomRequest(clearsLoadingState: Bool = true) -> Int {
        let request = classroomCoordinator.beginRequest(hasVisibleResults: !classroomAvailabilities.isEmpty)
        shouldShowInitialClassroomSpinner = request.shouldShowInitialSpinner
        if clearsLoadingState {
            isLoadingClassroomMeta = false
            isLoadingClassrooms = false
        }
        return request.id
    }

    /// 判断指定空教室请求是否仍然是当前最新请求。
    private func isCurrentClassroomRequest(_ requestID: Int) -> Bool {
        classroomCoordinator.isCurrent(requestID)
    }

    /// 统一处理空教室链路错误。
    ///
    /// 只有当前最新请求可以关闭 loading 和弹窗；旧请求失败会被静默丢弃。
    private func handleClassroomRequestError(_ error: Error, requestID: Int, title: String) {
        guard isCurrentClassroomRequest(requestID) else { return }

        if isCancellation(error) {
            classroomCoordinator.finish(requestID)
            shouldShowInitialClassroomSpinner = false
            return
        }

        classroomCoordinator.finish(requestID)
        shouldShowInitialClassroomSpinner = false
        isLoadingClassroomMeta = false
        isLoadingClassrooms = false
        notice = ScheduleNotice(title: title, message: error.localizedDescription)
    }

    /// 标记当前空教室请求已正常结束。
    private func finishClassroomRequestIfCurrent(_ requestID: Int) {
        guard isCurrentClassroomRequest(requestID) else { return }
        classroomCoordinator.finish(requestID)
        shouldShowInitialClassroomSpinner = false
    }

    /// 给单个空教室网络请求加超时，避免学校接口长期挂起。
    private func withClassroomRequestTimeout<T: Sendable>(
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await classroomCoordinator.withTimeout(operation: operation)
    }

    /// 从磁盘重新加载缓存，并同步周次与当前教学楼。
    private func reloadFromDisk() {
        let previousScheduleIndex = selectedCourseScheduleIndex
        let previousWeek = selectedWeek
        cache = ScheduleCacheStore.load()
        selectedCourseScheduleIndex = min(max(previousScheduleIndex, 0), max(courseSchedules.count - 1, 0))
        // 本地编辑会通过 scheduleCacheDidChange 回到这里。只更新数据，
        // 不把用户正在查看的历史/未来周强制跳回当前周。
        selectedWeek = previousWeek
        selectedBuildingID = cache.selectedBuildingID
    }

    /// 写回缓存。
    private func persist(source: ScheduleCacheStore.SaveSource = .local) {
        ScheduleCacheStore.save(cache, source: source)
    }

    /// 从“最近下一节课”的教室名推导最匹配的教学楼。
    ///
    /// 规则是：永远先做精确匹配，精确失败后才退回前缀匹配，再不行才回退缓存。
    private func preferredBuildingID(from buildings: [BuildingRecord]) -> String? {
        guard let course = nextUpcomingCourse() else { return nil }
        let candidates = ClassroomAvailabilityCalculator.buildingCandidates(from: course.classroom)
        guard !candidates.isEmpty else { return nil }

        let normalizedBuildings = buildings.map { ($0, ClassroomAvailabilityCalculator.normalizedBuildingName($0.name)) }

        if let exact = normalizedBuildings.first(where: { pair in
            candidates.contains(pair.1)
        }) {
            return exact.0.buildingCode
        }

        return normalizedBuildings.first { pair in
            let buildingName = pair.1
            guard !buildingName.isEmpty else { return false }
            return candidates.contains { candidate in
                candidate.hasPrefix(buildingName) || buildingName.hasPrefix(candidate)
            }
        }?.0.buildingCode
    }

    /// 从“最近下一节课”的校区信息推导默认校区。
    private func preferredCampus(from campuses: [CampusRecord]) -> CampusRecord? {
        guard let course = nextUpcomingCourse() else { return nil }
        let normalizedCampus = ClassroomAvailabilityCalculator.normalizedBuildingName(course.campus)
        guard !normalizedCampus.isEmpty else { return nil }

        return campuses.first { campus in
            let campusName = ClassroomAvailabilityCalculator.normalizedBuildingName(campus.name)
            let campusCode = ClassroomAvailabilityCalculator.normalizedBuildingName(campus.code)
            return normalizedCampus.contains(campusName) || campusName.contains(normalizedCampus) || normalizedCampus == campusCode
        }
    }

    /// 找出当前时间之后最近开始的一节正式课程。
    private func nextUpcomingCourse() -> CourseRecord? {
        guard let firstDay = cache.firstDay else { return nil }
        let slotMap = Dictionary(uniqueKeysWithValues: cache.timeTable.map { ($0.id, $0) })
        let now = Date()

        return cache.courses
            .compactMap { course -> (CourseRecord, Date)? in
                let nextStart = course.weeks.compactMap { week -> Date? in
                    guard
                        let slot = slotMap[course.startSection],
                        let startDate = combineCourseDate(
                            firstDay: firstDay,
                            week: week,
                            weekday: course.weekday,
                            time: slot.start
                        )
                    else {
                        return nil
                    }
                    return startDate >= now ? startDate : nil
                }.min()

                guard let nextStart else { return nil }
                return (course, nextStart)
            }
            .min { lhs, rhs in lhs.1 < rhs.1 }?
            .0
    }

    /// 把课程的教学周/星期/节次时间拼成真实日期时间。
    private func combineCourseDate(firstDay: Date, week: Int, weekday: Int, time: String) -> Date? {
        let dayOffset = ScheduleWeekCodec.weekOffset(forWeekNumber: week) * 7 + (weekday - 1)
        guard let day = Calendar.current.date(byAdding: .day, value: dayOffset, to: firstDay) else {
            return nil
        }

        let parts = time.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return nil
        }

        var components = Calendar.current.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        components.minute = minute
        components.second = 0
        return Calendar.current.date(from: components)
    }

    /// 按当前时间自动切换到对应的节次块筛选。
    ///
    /// 不是首次才做，而是每次进入空教室页都会重新计算。
    private func applyCurrentClassroomSectionBlock() {
        let sectionIDs = ClassroomAvailabilityCalculator.sectionBlock(at: currentMinutes(), in: cache.timeTable)
        guard !sectionIDs.isEmpty else { return }

        let normalized = ClassroomAvailabilityCalculator.normalizedSections(sectionIDs, in: cache.timeTable)
        guard cache.selectedClassroomSectionIDs != normalized else { return }
        cache.selectedClassroomSectionIDs = normalized
        persist()
        if !classroomRecords.isEmpty {
            refreshClassroomAvailabilities()
        }
    }

}
