import ClientCore
//
//  ScheduleViewModel.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Combine
import Foundation

/// 周视图的自动定位范围。
///
/// 自动定位结果落在这个范围内，手动翻页沿用完整周次范围。
/// 冷启动、学期切换和同步等按今天计算周次的入口使用这个范围，
/// 首周日期异常时，自动定位仍落在限定周次内。
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

@MainActor
/// 课表状态机与日程子功能组装入口。
///
/// 负责：
/// 课表同步、编辑与选择状态归此对象；DDL 和空教室各自拥有状态与服务接口。
/// 三个子功能通过 ScheduleRepository 共享当前账号的持久化数据。
final class ScheduleViewModel: ObservableObject, ScheduleStateConsumer {
    /// 课表页当前正在显示的课表分身。
    ///
    /// 主课表来自当前账号缓存；导入的课表作为只读分身追加到列表，供上下滑循环切换。
    struct CourseScheduleVariant: Identifiable, Equatable {
        let id: String
        let title: String
        let isPrimary: Bool
        let importedAt: Date?
        let sharedAt: Date?
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
    /// 是否正在同步课表/考试。
    @Published var isSyncingCourses = false
    @Published var selectedWeek = 1
    @Published var selectedCourseScheduleIndex = 0
    @Published var notice: ScheduleNotice?
    @Published var smsChallenge: BITLoginAuthenticationChallenge?
    @Published var smsVerificationError: String?
    @Published var isSubmittingSMSCode = false
    /// 学校提供的可切换学期列表。
    @Published var availableTerms: [String] = []
    @Published var isLoadingTerms = false
    @Published var hasLoadedAvailableTerms = false
    @Published var syncingTerm: String?

    let repository: ScheduleRepository
    let service: any ScheduleCourseServicing
    let ddl: ScheduleDDLViewModel
    let classroom: ScheduleClassroomViewModel
    let courseSyncCoordinator = ScheduleCourseSyncCoordinator()
    private var subscriptions = Set<AnyCancellable>()
    private var hasLoaded = false

    init(service: any ScheduleServicing, repository: ScheduleRepository = ScheduleRepository()) {
        self.repository = repository
        self.service = service
        ddl = ScheduleDDLViewModel(service: service, repository: repository)
        classroom = ScheduleClassroomViewModel(service: service, repository: repository)
        repository.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        repository.$notice.compactMap { $0 }.sink { [weak self] in self?.notice = $0 }.store(in: &subscriptions)
        ddl.$notice.compactMap { $0 }.sink { [weak self] in self?.notice = $0 }.store(in: &subscriptions)
        classroom.$notice.compactMap { $0 }.sink { [weak self] in self?.notice = $0 }.store(in: &subscriptions)
        classroom.onAuthenticationRequired = { [weak self] challenge in
            guard let self else { return }
            self.courseSyncCoordinator.waitForClassroomAuthentication()
            self.smsChallenge = challenge
            self.smsVerificationError = nil
        }
    }

    convenience init() { self.init(service: ScheduleService()) }

    func resetForCurrentAccount() {
        repository.resetForCurrentAccount()
        classroom.reset()
        ddl.reset()
        hasLoaded = false
        isSyncingCourses = false
        isLoadingTerms = false
        syncingTerm = nil
        isSubmittingSMSCode = false
        availableTerms = []
        hasLoadedAvailableTerms = false
        smsChallenge = nil
        smsVerificationError = nil
        courseSyncCoordinator.reset()
        notice = nil
        Task { @MainActor [weak self] in await self?.reloadFromDisk() }
    }

    /// 构造日程模块统一使用的本地校验错误。
    ///
    /// 这类错误表示用户输入校验状态或本地配置格式校验状态为失败。
    /// 各分支共用同一组 domain / code。
    func scheduleValidationError(_ message: String) -> NSError {
        NSError(
            domain: "BIT101.Schedule",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
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
            title: cache.primaryScheduleTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "课表"
                : cache.primaryScheduleTitle,
            isPrimary: true,
            importedAt: nil,
            sharedAt: nil,
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
                importedAt: record.importedAt,
                sharedAt: record.sharedAt,
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
        let normalizedIndex = min(max(selectedCourseScheduleIndex, 0), variants.count - 1)
        return variants[normalizedIndex]
    }

    /// 首次进入日程页时从本地磁盘恢复缓存。
    ///
    /// 日程页先展示本地缓存，联网同步由用户主动触发；冷启动直接进入缓存内容。
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true

        // 页面先读本地缓存，打开时直接展示用户上次选择的学期；联网同步由用户主动触发。
        // 周次按当前课表首周计算，学期选择保持本地缓存值。
        await reloadFromDisk()
        selectedWeek = resolvedAutomaticWeek()
    }

    /// 根据首周日期推导当前周次。
    func resolvedAutomaticWeek() -> Int {
        resolvedAutomaticWeek(for: cache.firstDay)
    }

    /// 根据指定首周日期推导当前周次。
    func resolvedAutomaticWeek(for firstDay: Date?) -> Int {
        guard let firstDay else { return 1 }

        let start = ScheduleDateCodec.calendar.startOfDay(for: firstDay)
        let today = ScheduleDateCodec.calendar.startOfDay(for: Date())
        let diff = ScheduleDateCodec.calendar.dateComponents([.day], from: start, to: today).day ?? 0
        return ScheduleAutomaticWeekPolicy.clamped(
            ScheduleWeekCodec.weekNumber(forDayOffset: diff)
        )
    }

    /// 从磁盘重新加载缓存，保留用户当前正在浏览的周次和课表分身。
    func reloadFromDisk() async {
        await repository.reload()
        selectedCourseScheduleIndex = min(max(selectedCourseScheduleIndex, 0), max(courseSchedules.count - 1, 0))
        classroom.restoreSelection()
    }

    /// 统一兼容任务取消错误。
    func isCancellation(_ error: Error) -> Bool {
        TaskCancellation.matches(error)
    }
}
