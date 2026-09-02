//
//  ScheduleViewModel.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Combine
import Foundation

nonisolated enum CourseSyncReplacementPolicy {
    static func shouldReplace(existing: [CourseRecord], with incoming: [CourseRecord]) -> Bool {
        guard !incoming.isEmpty, incoming.count >= existing.count else { return false }
        let existingIDs = Set(existing.map(identity))
        return incoming.map(identity).contains { !existingIDs.contains($0) }
    }

    private static func identity(_ course: CourseRecord) -> String {
        [course.number, course.name, course.teacher, course.classroom,
         course.weekday.description, course.startSection.description,
         course.endSection.description, course.weeks.map(String.init).joined(separator: ",")]
            .joined(separator: "|")
    }
}

/// 周视图的自动定位范围。
///
/// 手动翻页不使用这个范围；它只保护冷启动、学期切换和同步等
/// “按今天计算周次”的入口，避免首周日期异常时跳到过远的周次。
nonisolated enum ScheduleAutomaticWeekPolicy {
    static let minimumWeek = -12
    static let maximumWeek = 20

    static func clamped(_ week: Int) -> Int {
        min(max(week, minimumWeek), maximumWeek)
    }
}

extension Int {
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
    @Published var cache = ScheduleCache()
    /// 是否正在做首次本地缓存恢复。
    @Published var isLoadingCache = true
    /// 是否正在同步课表/考试。
    @Published var isSyncingCourses = false
    /// 是否正在同步乐学 DDL。
    @Published var isSyncingDDL = false
    /// 是否正在加载空教室元数据（校区/教学楼）。
    @Published var isLoadingClassroomMeta = false
    /// 是否正在加载空教室结果。
    @Published var isLoadingClassrooms = false
    /// 首次进入空教室页且尚无结果时，是否显示一个无文案的加载指示。
    @Published var shouldShowInitialClassroomSpinner = false
    @Published var campuses: [CampusRecord] = []
    @Published var buildings: [BuildingRecord] = []
    @Published var classroomAvailabilities: [ClassroomAvailability] = []
    @Published var selectedWeek = 1
    @Published var selectedCourseScheduleIndex = 0
    @Published var selectedBuildingID = ""
    @Published var notice: ScheduleNotice?
    @Published var smsChallenge: BITLoginAuthenticationChallenge?
    @Published var smsVerificationError: String?
    @Published var isSubmittingSMSCode = false
    /// 学校提供的可切换学期列表。
    @Published var availableTerms: [String] = []
    @Published var isLoadingTerms = false
    @Published var hasLoadedAvailableTerms = false
    @Published var syncingTerm: String?

    let service: any ScheduleServicing
    let classroomCoordinator = ScheduleClassroomCoordinator()
    let courseSyncCoordinator = ScheduleCourseSyncCoordinator()
    private var hasLoaded = false
    /// 当前教学楼最近一次拉下来的原始空教室记录。
    var classroomRecords: [ClassroomRecord] = []
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
    func scheduleValidationError(_ message: String) -> NSError {
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
        // `loadIfNeeded` 在进程生命周期内只成功执行一次，因此这里按今天定位；
        // 自动定位结果会保护在第 -12 至 +20 周，手动翻页仍不受此限制：
        // 杀后台后的冷启动会回到今日；仅切换页面或前后台切换不会打断用户正在浏览的周次。
        reloadFromDisk()
        selectedWeek = resolvedAutomaticWeek()
        if activatePreferredCachedTermIfAvailable(on: Date()) {
            persist()
        }
        #if canImport(CloudKit)
        await ScheduleCloudSyncManager.shared.refreshFromCloudIfNeeded()
        #endif
        isLoadingCache = false
    }

    /// 根据首周日期推导当前周次。
    func resolvedAutomaticWeek() -> Int {
        guard let firstDay = cache.firstDay else { return 1 }

        let start = Calendar.current.startOfDay(for: firstDay)
        let today = Calendar.current.startOfDay(for: Date())
        let diff = Calendar.current.dateComponents([.day], from: start, to: today).day ?? 0
        return ScheduleAutomaticWeekPolicy.clamped(
            ScheduleWeekCodec.weekNumber(forDayOffset: diff)
        )
    }

    /// 从磁盘重新加载缓存，保留用户当前正在浏览的周次和课表分身。
    func reloadFromDisk() {
        let previousScheduleIndex = selectedCourseScheduleIndex
        let previousWeek = selectedWeek
        cache = ScheduleCacheStore.load()
        selectedCourseScheduleIndex = min(max(previousScheduleIndex, 0), max(courseSchedules.count - 1, 0))
        selectedWeek = previousWeek
        selectedBuildingID = cache.selectedBuildingID
    }

    /// 写回缓存。
    func persist(source: ScheduleCacheStore.SaveSource = .local) {
        ScheduleCacheStore.save(cache, source: source)
    }

    /// 统一兼容任务取消错误。
    func isCancellation(_ error: Error) -> Bool {
        TaskCancellation.matches(error)
    }
}
