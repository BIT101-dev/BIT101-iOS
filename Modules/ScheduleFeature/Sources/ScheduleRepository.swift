import StorageCore
import ScheduleDomain
import Combine
import Foundation

/// 日程子功能共享的账号数据源。页面状态由各子功能拥有。
@MainActor
public final class ScheduleRepository: ObservableObject {
    @Published private var cache = ScheduleCache() {
        didSet { revision &+= 1 }
    }
    @Published private(set) var isWritable = false
    @Published private(set) var isLoading = true
    @Published var notice: ScheduleNotice?
    private(set) var accountGeneration = 0
    private var revision = 0
    private var loadGeneration = 0
    private var hasLoaded = false
    private var ownerSession: AppStorageSession
    var accountSession: AppStorageSession { ownerSession }
    private var observer: Task<Void, Never>?
    private let session: () -> AppStorageSession
    private let load: (AppStorageSession) async -> ScheduleCacheLoadResult
    private let save: (ScheduleCache, ScheduleCacheSaveSource, AppStorageSession) -> Void

    public init(
        session: @escaping () -> AppStorageSession,
        load: @escaping (AppStorageSession) async -> ScheduleCacheLoadResult,
        save: @escaping (ScheduleCache, ScheduleCacheSaveSource, AppStorageSession) -> Void,
        cacheDidChange: Notification.Name,
        notificationCenter: NotificationCenter = .default
    ) {
        self.session = session
        self.ownerSession = session()
        self.load = load
        self.save = save
        observer = Task { @MainActor [weak self] in
            for await _ in notificationCenter.notifications(named: cacheDidChange) {
                await self?.reload()
            }
        }
    }

    deinit { observer?.cancel() }

    func resetForCurrentAccount() {
        ownerSession = session()
        accountGeneration &+= 1
        loadGeneration &+= 1
        hasLoaded = false
        isWritable = false
        isLoading = true
        cache = ScheduleCache()
        notice = nil
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await reload()
    }

    func reload() async {
        let account = session()
        guard account == ownerSession else { return }
        let generation = accountGeneration
        let localRevision = revision
        loadGeneration &+= 1
        let request = loadGeneration
        let result = await load(account)
        guard generation == accountGeneration, account == session(),
              request == loadGeneration, localRevision == revision else { return }
        switch result {
        case .loaded(let value):
            cache = value
            isWritable = true
            notice = nil
        case .missing:
            cache = ScheduleCache()
            isWritable = true
            notice = nil
        case .unreadable:
            isWritable = false
            notice = .informational(
                title: "本地课表缓存读取失败",
                message: "原文件已保留，当前课表只读并暂停保存。请联系维护者恢复缓存后重试。"
            )
        }
        isLoading = false
    }

    func persist(source: ScheduleCacheSaveSource = .local) {
        guard isWritable, ownerSession == session() else { return }
        save(cache, source, ownerSession)
    }

    var persistenceSnapshot: ScheduleCache { cache }

    var courseChanges: AnyPublisher<Void, Never> {
        valueChanges(for: ScheduleCourseState.init)
            .merge(with: valueChanges(for: SchedulePresentationPreferences.init))
            .merge(with: valueChanges(for: { $0.iCloudSyncEnabled }))
            .merge(with: availabilityChanges)
            .eraseToAnyPublisher()
    }

    var ddlChanges: AnyPublisher<Void, Never> { changes(for: ScheduleDDLState.init) }
    var classroomChanges: AnyPublisher<Void, Never> { changes(for: ScheduleClassroomState.init) }
    var classroomSelection: AnyPublisher<String, Never> {
        $cache.map(\.selectedBuildingID).removeDuplicates().eraseToAnyPublisher()
    }

    /// 场景数据与读写状态分别参与订阅，相关字段变化时刷新消费页面。
    private func changes<State: Equatable>(for projection: @escaping (ScheduleCache) -> State) -> AnyPublisher<Void, Never> {
        valueChanges(for: projection).merge(with: availabilityChanges).eraseToAnyPublisher()
    }

    private var availabilityChanges: AnyPublisher<Void, Never> {
        $isWritable.removeDuplicates().dropFirst().map { _ in () }
            .merge(with: $isLoading.removeDuplicates().dropFirst().map { _ in () })
            .eraseToAnyPublisher()
    }

    private func valueChanges<State: Equatable>(for projection: @escaping (ScheduleCache) -> State) -> AnyPublisher<Void, Never> {
        $cache.map(projection).removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
    }
}

/// 子功能使用统一账号数据源，分别管理请求、选择与提示状态。
@MainActor
protocol ScheduleStateConsumer: AnyObject {
    var repository: ScheduleRepository { get }
    var virtualNetworkLikely: @MainActor () -> Bool { get }
}

extension ScheduleStateConsumer {
    var accountGeneration: Int { repository.accountGeneration }
    var isLoadingCache: Bool { repository.isLoading }
    var isCacheWritable: Bool { repository.isWritable }

    func persist(source: ScheduleCacheSaveSource = .local) {
        repository.persist(source: source)
    }
}

/// 课表内容与偏好的场景快照，教学楼目录作为编辑上下文提供。
nonisolated struct ScheduleCourseState: Equatable {
    var primaryScheduleTitle: String
    var currentTerm: String
    var firstDayString: String
    var manualFirstDayStringsByTerm: [String: String]
    var coursesUpdatedAt: Date
    var courses: [CourseRecord]
    var cachedCoursesByTerm: [String: [CourseRecord]]
    var schoolCoursesByTerm: [String: [CourseRecord]]
    var manualCourseRulesByTerm: [String: [ScheduleCourseRule]]
    var termSchedulesByTerm: [String: TermScheduleSnapshot]
    var exams: [ExamRecord]
    var customSchedules: [CustomScheduleRecord]
    var timeTable: [TimeSlot]
    var sharedSchedules: [SharedScheduleRecord]
    let firstDay: Date?
    let cachedClassroomBuildingsByCampusCode: [String: [BuildingRecord]]

    init(cache: ScheduleCache) {
        primaryScheduleTitle = cache.primaryScheduleTitle
        currentTerm = cache.currentTerm
        firstDayString = cache.firstDayString
        manualFirstDayStringsByTerm = cache.manualFirstDayStringsByTerm
        coursesUpdatedAt = cache.coursesUpdatedAt
        courses = cache.courses
        cachedCoursesByTerm = cache.cachedCoursesByTerm
        schoolCoursesByTerm = cache.schoolCoursesByTerm
        manualCourseRulesByTerm = cache.manualCourseRulesByTerm
        termSchedulesByTerm = cache.termSchedulesByTerm
        exams = cache.exams
        customSchedules = cache.customSchedules
        timeTable = cache.timeTable
        sharedSchedules = cache.sharedSchedules
        firstDay = cache.firstDay
        cachedClassroomBuildingsByCampusCode = cache.cachedClassroomBuildingsByCampusCode
    }
}

/// DDL 内容与显示偏好的场景快照。
struct ScheduleDDLState: Equatable {
    var lexueCalendarURL: String
    var ddlEvents: [DDLEventRecord]
    var lexueDDLCompletionByID: [String: Bool]
    var ddlUpdatedAt: Date?
    var ddlBeforeDay: Int
    var ddlAfterDay: Int

    init(cache: ScheduleCache) {
        lexueCalendarURL = cache.lexueCalendarURL
        ddlEvents = cache.ddlEvents
        lexueDDLCompletionByID = cache.lexueDDLCompletionByID
        ddlUpdatedAt = cache.ddlUpdatedAt
        ddlBeforeDay = cache.ddlBeforeDay
        ddlAfterDay = cache.ddlAfterDay
    }
}

/// 空教室选择与查询上下文的场景快照。
struct ScheduleClassroomState: Equatable {
    var selectedCampusName: String
    var selectedCampusCode: String
    var selectedBuildingID: String
    var cachedClassroomCampuses: [CampusRecord]
    var cachedClassroomBuildingsByCampusCode: [String: [BuildingRecord]]
    var selectedClassroomSectionIDs: [Int]
    var isClassroomSectionFilterCustomized: Bool
    let currentTerm: String
    let courses: [CourseRecord]
    let firstDay: Date?
    let timeTable: [TimeSlot]

    init(cache: ScheduleCache) {
        selectedCampusName = cache.selectedCampusName
        selectedCampusCode = cache.selectedCampusCode
        selectedBuildingID = cache.selectedBuildingID
        cachedClassroomCampuses = cache.cachedClassroomCampuses
        cachedClassroomBuildingsByCampusCode = cache.cachedClassroomBuildingsByCampusCode
        selectedClassroomSectionIDs = cache.selectedClassroomSectionIDs
        isClassroomSectionFilterCustomized = cache.isClassroomSectionFilterCustomized
        currentTerm = cache.currentTerm
        courses = cache.courses
        firstDay = cache.firstDay
        timeTable = cache.timeTable
    }
}

/// 课表展示与提醒偏好按独立投影维护。
nonisolated struct SchedulePresentationPreferences: Equatable {
    var showSaturday: Bool
    var showSunday: Bool
    var showExamInfo: Bool
    var scheduleDisplayMode: ScheduleDisplayMode
    var scheduleCardContentMode: ScheduleCardContentMode
    var showCourseLiveActivityReminder: Bool
    var courseLiveActivityLeadMinutes: Int

    init(cache: ScheduleCache) {
        showSaturday = cache.showSaturday
        showSunday = cache.showSunday
        showExamInfo = cache.showExamInfo
        scheduleDisplayMode = cache.scheduleDisplayMode
        scheduleCardContentMode = cache.scheduleCardContentMode
        showCourseLiveActivityReminder = cache.showCourseLiveActivityReminder
        courseLiveActivityLeadMinutes = cache.courseLiveActivityLeadMinutes
    }
}

/// 云同步开关可由用户操作更新，云端基线由持久化适配维护。
nonisolated struct ScheduleSyncState: Equatable {
    var iCloudSyncEnabled: Bool
    let cloudSyncBaselineAt: Date
    let cloudSyncBaselineRecordTag: String
    let hasUnpushedCloudChanges: Bool

    init(cache: ScheduleCache) {
        iCloudSyncEnabled = cache.iCloudSyncEnabled
        cloudSyncBaselineAt = cache.cloudSyncBaselineAt
        cloudSyncBaselineRecordTag = cache.cloudSyncBaselineRecordTag
        hasUnpushedCloudChanges = cache.hasUnpushedCloudChanges
    }
}

extension ScheduleRepository {
    var presentationPreferences: SchedulePresentationPreferences {
        get { SchedulePresentationPreferences(cache: cache) }
        set {
            var updated = cache
            updated.showSaturday = newValue.showSaturday
            updated.showSunday = newValue.showSunday
            updated.showExamInfo = newValue.showExamInfo
            updated.scheduleDisplayMode = newValue.scheduleDisplayMode
            updated.scheduleCardContentMode = newValue.scheduleCardContentMode
            updated.showCourseLiveActivityReminder = newValue.showCourseLiveActivityReminder
            updated.courseLiveActivityLeadMinutes = newValue.courseLiveActivityLeadMinutes
            cache = updated
        }
    }

    var syncState: ScheduleSyncState {
        get { ScheduleSyncState(cache: cache) }
        set { cache.iCloudSyncEnabled = newValue.iCloudSyncEnabled }
    }

    var courseState: ScheduleCourseState {
        get { ScheduleCourseState(cache: cache) }
        set {
            var updated = cache
            updated.primaryScheduleTitle = newValue.primaryScheduleTitle
            updated.currentTerm = newValue.currentTerm
            updated.firstDayString = newValue.firstDayString
            updated.manualFirstDayStringsByTerm = newValue.manualFirstDayStringsByTerm
            updated.coursesUpdatedAt = newValue.coursesUpdatedAt
            updated.courses = newValue.courses
            updated.cachedCoursesByTerm = newValue.cachedCoursesByTerm
            updated.schoolCoursesByTerm = newValue.schoolCoursesByTerm
            updated.manualCourseRulesByTerm = newValue.manualCourseRulesByTerm
            updated.termSchedulesByTerm = newValue.termSchedulesByTerm
            updated.exams = newValue.exams
            updated.customSchedules = newValue.customSchedules
            updated.timeTable = newValue.timeTable
            updated.sharedSchedules = newValue.sharedSchedules
            cache = updated
        }
    }

    var ddlState: ScheduleDDLState {
        get { ScheduleDDLState(cache: cache) }
        set {
            var updated = cache
            updated.lexueCalendarURL = newValue.lexueCalendarURL
            updated.ddlEvents = newValue.ddlEvents
            updated.lexueDDLCompletionByID = newValue.lexueDDLCompletionByID
            updated.ddlUpdatedAt = newValue.ddlUpdatedAt
            updated.ddlBeforeDay = newValue.ddlBeforeDay
            updated.ddlAfterDay = newValue.ddlAfterDay
            cache = updated
        }
    }

    var classroomState: ScheduleClassroomState {
        get { ScheduleClassroomState(cache: cache) }
        set {
            var updated = cache
            updated.selectedCampusName = newValue.selectedCampusName
            updated.selectedCampusCode = newValue.selectedCampusCode
            updated.selectedBuildingID = newValue.selectedBuildingID
            updated.cachedClassroomCampuses = newValue.cachedClassroomCampuses
            updated.cachedClassroomBuildingsByCampusCode = newValue.cachedClassroomBuildingsByCampusCode
            updated.selectedClassroomSectionIDs = newValue.selectedClassroomSectionIDs
            updated.isClassroomSectionFilterCustomized = newValue.isClassroomSectionFilterCustomized
            cache = updated
        }
    }

    func resolveCurrentTerm(_ term: String) {
        guard cache.currentTerm.isEmpty else { return }
        cache.currentTerm = term
    }

    func updateCourses(previousCourses: [CourseRecord], currentCourses: [CourseRecord]) {
        ScheduleCourseEditor.updateCacheForManualCourseChange(
            in: &cache,
            previousCourses: previousCourses,
            currentCourses: currentCourses
        )
    }
}
