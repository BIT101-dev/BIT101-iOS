import TransportCore
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
    @Published private(set) var requiresRecoveryConfirmation = false
    @Published private(set) var hasReadFailure = false
    @Published private(set) var isConfirmingRecovery = false
    @Published var notice: ScheduleNotice?
    @Published private(set) var hasPersistenceConflict = false
    @Published private(set) var isResolvingPersistenceConflict = false
    private var loadedCache: ScheduleCache?
    private var loadedRevision = 0
    private(set) var accountGeneration = 0
    private var revision = 0
    private var loadGeneration = 0
    private var hasLoaded = false
    private var ownerSession: AppStorageSession
    var accountSession: AppStorageSession { ownerSession }
    private var observer: AnyCancellable?
    private var persistenceTask: Task<Bool, Never>?
    private var persistenceGeneration = 0
    private var reloadAfterPersistence = false
    private let session: () -> AppStorageSession
    private let load: (AppStorageSession) async -> ScheduleCacheLoadResult
    private let save: (ScheduleCache, ScheduleCacheSaveSource, AppStorageSession) async throws -> Void

    public init(
        session: @escaping () -> AppStorageSession,
        load: @escaping (AppStorageSession) async -> ScheduleCacheLoadResult,
        save: @escaping (ScheduleCache, ScheduleCacheSaveSource, AppStorageSession) async throws -> Void,
        changes: AnyPublisher<AppStorageSession, Never> = Empty().eraseToAnyPublisher()
    ) {
        self.session = session
        self.ownerSession = session()
        self.load = load
        self.save = save
        observer = changes.sink { [weak self] account in
            guard let self, account == self.ownerSession else { return }
            let generation = self.accountGeneration
            Task { @MainActor [weak self] in
                guard let self, self.accountGeneration == generation, self.ownerSession == account else { return }
                await self.reload()
            }
        }
    }

    func resetForCurrentAccount() {
        persistenceTask?.cancel()
        persistenceTask = nil
        persistenceGeneration &+= 1
        reloadAfterPersistence = false
        hasPersistenceConflict = false
        isResolvingPersistenceConflict = false
        loadedCache = nil
        ownerSession = session()
        accountGeneration &+= 1
        loadGeneration &+= 1
        hasLoaded = false
        requiresRecoveryConfirmation = false
        hasReadFailure = false
        isConfirmingRecovery = false
        isWritable = false
        isLoading = true
        cache = ScheduleCache()
        notice = nil
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await reload()
    }

    @discardableResult
    func reload() async -> Bool {
        guard persistenceTask == nil else {
            reloadAfterPersistence = true
            return false
        }
        let account = session()
        guard !Task.isCancelled, account == ownerSession else { return false }
        let generation = accountGeneration
        let localRevision = revision
        loadGeneration &+= 1
        let request = loadGeneration
        if !hasLoaded { isLoading = true }
        defer {
            if generation == accountGeneration, account == ownerSession, request == loadGeneration {
                isLoading = false
            }
        }
        let result = await load(account)
        guard !Task.isCancelled, generation == accountGeneration, account == session(),
              request == loadGeneration, localRevision == revision else { return false }
        switch result {
        case .loaded(let value), .recovered(let value):
            _ = await reconcile(with: value)
            guard !Task.isCancelled, generation == accountGeneration, account == session(), request == loadGeneration else { return false }
            requiresRecoveryConfirmation = result.isRecovered
            hasReadFailure = false
            isWritable = !result.isRecovered
        case .missing:
            _ = await reconcile(with: ScheduleCache())
            guard !Task.isCancelled, generation == accountGeneration, account == session(), request == loadGeneration else { return false }
            isWritable = true
            requiresRecoveryConfirmation = false
            hasReadFailure = false
        case .unreadable:
            isWritable = false
            hasReadFailure = true
        }
        hasLoaded = true
        return true
    }

    func persist(source: ScheduleCacheSaveSource = .local) {
        _ = enqueuePersistence(source: source)
    }

    var acceptsEdits: Bool { isWritable && !hasPersistenceConflict && ownerSession == session() }

    func requireWritable() throws {
        guard acceptsEdits else {
            throw NSError(domain: "ScheduleRepository", code: 1, userInfo: [NSLocalizedDescriptionKey:
                hasPersistenceConflict ? "请先选择需要保留的日程版本，再继续编辑。" :
                    (requiresRecoveryConfirmation ? "请先核对并确认日程恢复结果。" :
                        (isLoading ? "正在读取日程，请稍后重试。" : "请重试读取日程后继续编辑。"))])
        }
    }

    func confirmRecovery() async {
        guard requiresRecoveryConfirmation, !isConfirmingRecovery, persistenceTask == nil else { return }
        let generation = accountGeneration
        isConfirmingRecovery = true
        loadGeneration &+= 1
        defer { if generation == accountGeneration { isConfirmingRecovery = false } }
        _ = await persistAndWait(source: .recovery)
    }

    @discardableResult
    func persistAndWait(source: ScheduleCacheSaveSource = .local) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard let task = enqueuePersistence(source: source) else { return false }
        let saved = await task.value
        return saved && !Task.isCancelled
    }

    private func enqueuePersistence(source: ScheduleCacheSaveSource) -> Task<Bool, Never>? {
        let confirmsRecovery = source == .recovery && requiresRecoveryConfirmation && !hasReadFailure
            && !hasPersistenceConflict && ownerSession == session()
        guard acceptsEdits || confirmsRecovery else { return nil }
        let account = ownerSession
        let generation = accountGeneration
        let snapshot = cache
        let localRevision = revision
        let previous = persistenceTask
        persistenceGeneration &+= 1
        let operation = persistenceGeneration
        let task = Task { @MainActor [weak self, save] in
            _ = await previous?.value
            guard let self, !Task.isCancelled,
                  self.accountGeneration == generation, account == self.session() else { return false }
            defer {
                if self.persistenceGeneration == operation { self.persistenceTask = nil }
            }
            do {
                try await save(snapshot, source, account)
                guard self.accountGeneration == generation, account == self.session() else { return false }
                self.loadedCache = snapshot
                self.loadedRevision = localRevision
                self.notice = nil
                if confirmsRecovery {
                    self.requiresRecoveryConfirmation = false
                    self.isWritable = true
                }
                if self.persistenceGeneration == operation, self.reloadAfterPersistence {
                    self.reloadAfterPersistence = false
                    self.persistenceTask = nil
                    await self.reload()
                }
                guard self.accountGeneration == generation, account == self.session() else { return false }
                return true
            } catch {
                if TaskCancellation.matches(error) { return false }
                guard self.accountGeneration == generation, account == self.session(),
                      !Task.isCancelled else { return false }
                if self.persistenceGeneration == operation,
                   source == .local || source == .localWithoutCloudPush,
                   case .loaded(let remote) = await self.load(account) {
                    guard self.accountGeneration == generation, account == self.session(),
                          self.persistenceGeneration == operation, !Task.isCancelled else { return false }
                    self.reloadAfterPersistence = false
                    if remote.cloudSyncBaselineAt != snapshot.cloudSyncBaselineAt
                        || remote.cloudSyncBaselineRecordTag != snapshot.cloudSyncBaselineRecordTag
                        || remote.syncData.cloudSyncBaselineUserState != snapshot.syncData.cloudSyncBaselineUserState {
                        guard await self.reconcile(with: remote) else { return false }
                        let rebased = self.cache
                        let rebasedRevision = self.revision
                        do {
                            try await save(rebased, source, account)
                            guard self.accountGeneration == generation, account == self.session() else { return false }
                            self.loadedCache = rebased
                            self.loadedRevision = rebasedRevision
                            self.notice = nil
                            if self.persistenceGeneration == operation, self.reloadAfterPersistence {
                                self.reloadAfterPersistence = false
                                self.persistenceTask = nil
                                await self.reload()
                            }
                            return true
                        } catch {
                            if TaskCancellation.matches(error) { return false }
                            guard self.accountGeneration == generation, account == self.session() else { return false }
                            self.notice = ScheduleNotice(title: "日程保存失败", message: error.localizedDescription)
                            return false
                        }
                    }
                }
                self.notice = ScheduleNotice(title: "日程保存失败", message: error.localizedDescription)
                return false
            }
        }
        persistenceTask = task
        return task
    }

    /// 合并时沿用本机学校数据，同步版本提供用户状态及持久化基线。
    private func reconcile(with remote: ScheduleCache, resolution: ScheduleCacheConflictResolution? = nil) async -> Bool {
        let account = ownerSession
        let generation = accountGeneration
        let request = loadGeneration
        do {
            while let loadedCache, revision != loadedRevision || hasPersistenceConflict {
                let localRevision = revision
                let merged = try await Self.merge(local: cache, loaded: loadedCache, remote: remote, resolution: resolution)
                guard !Task.isCancelled, account == session(), generation == accountGeneration, request == loadGeneration else { return false }
                guard localRevision == revision else { continue }
                guard let merged else { hasPersistenceConflict = true; return false }
                loadedRevision = revision
                cache = merged
                self.loadedCache = remote
                hasPersistenceConflict = false
                notice = nil
                return true
            }
            cache = remote
            loadedRevision = revision
            loadedCache = remote
            hasPersistenceConflict = false
            notice = nil
            return true
        } catch {
            guard !TaskCancellation.matches(error), account == session(), generation == accountGeneration else { return false }
            notice = ScheduleNotice(title: "日程合并失败", message: error.localizedDescription)
            return false
        }
    }

    @concurrent
    private static func merge(local: ScheduleCache, loaded: ScheduleCache, remote: ScheduleCache,
        resolution: ScheduleCacheConflictResolution?) async throws -> ScheduleCache? {
        try Task.checkCancellation()
        let baseline = try ScheduleCloudStateMerge.baseline(for: loaded)
        guard let state = try ScheduleCloudStateMerge.merge(local: .init(cache: local),
            remote: .init(cache: remote), baseline: baseline, resolution: resolution) else { return nil }
        var merged = local
        state.apply(to: &merged)
        merged.cloudSyncBaselineAt = remote.cloudSyncBaselineAt
        merged.cloudSyncBaselineRecordTag = remote.cloudSyncBaselineRecordTag
        merged.syncData.cloudSyncBaselineUserState = remote.syncData.cloudSyncBaselineUserState
        let userStateChanged = try !ScheduleCloudSyncState.matches(merged, remote)
        merged.hasUnpushedCloudChanges = remote.hasUnpushedCloudChanges || (merged.iCloudSyncEnabled && userStateChanged)
        merged.updatedAt = max(merged.updatedAt, remote.updatedAt)
        try Task.checkCancellation()
        return merged
    }

    func resolvePersistenceConflict(_ resolution: ScheduleCacheConflictResolution) async {
        guard hasPersistenceConflict, !isResolvingPersistenceConflict, persistenceTask == nil else { return }
        let account = ownerSession
        let generation = accountGeneration
        isResolvingPersistenceConflict = true
        defer { if generation == accountGeneration { isResolvingPersistenceConflict = false } }
        let result = await load(account)
        guard generation == accountGeneration, account == session(), hasPersistenceConflict else { return }
        guard let remote = result.cacheIfReadable else {
            notice = .informational(title: "日程版本读取失败", message: "本机编辑已保留，请恢复缓存后重新选择版本。")
            return
        }
        guard await reconcile(with: remote, resolution: resolution) else { return }
        _ = await persistAndWait()
    }

    var persistenceSnapshot: ScheduleCache { cache }

    var courseChanges: AnyPublisher<Void, Never> {
        valueChanges(for: ScheduleCourseState.init)
            .merge(with: valueChanges(for: { $0.presentation }))
            .merge(with: valueChanges(for: { $0.iCloudSyncEnabled }))
            .merge(with: availabilityChanges)
            .eraseToAnyPublisher()
    }

    var ddlChanges: AnyPublisher<Void, Never> { changes(for: { $0.ddlData }) }
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
            .merge(with: $hasPersistenceConflict.removeDuplicates().dropFirst().map { _ in () })
            .merge(with: $requiresRecoveryConfirmation.removeDuplicates().dropFirst().map { _ in () })
            .merge(with: $hasReadFailure.removeDuplicates().dropFirst().map { _ in () })
            .merge(with: $isConfirmingRecovery.removeDuplicates().dropFirst().map { _ in () })
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
    var isCacheWritable: Bool { repository.acceptsEdits }

    func persist(source: ScheduleCacheSaveSource = .local) {
        repository.persist(source: source)
    }

    func persistAndWait(source: ScheduleCacheSaveSource = .local) async -> Bool {
        await repository.persistAndWait(source: source)
    }
}

/// 课程状态整体传递，教学楼目录作为只读编辑上下文提供。
@dynamicMemberLookup
nonisolated struct ScheduleCourseState: Equatable {
    var data: ScheduleCourseData
    let cachedClassroomBuildingsByCampusCode: [String: [BuildingRecord]]

    init(cache: ScheduleCache) {
        data = cache.courseData
        cachedClassroomBuildingsByCampusCode = cache.classroomData.cachedClassroomBuildingsByCampusCode
    }

    subscript<Value>(dynamicMember keyPath: KeyPath<ScheduleCourseData, Value>) -> Value {
        data[keyPath: keyPath]
    }
    subscript<Value>(dynamicMember keyPath: WritableKeyPath<ScheduleCourseData, Value>) -> Value {
        get { data[keyPath: keyPath] }
        set { data[keyPath: keyPath] = newValue }
    }
}

typealias ScheduleDDLState = ScheduleDDLData

/// 空教室状态整体传递，课程快照作为只读查询上下文提供。
@dynamicMemberLookup
nonisolated struct ScheduleClassroomState: Equatable {
    var data: ScheduleClassroomData
    let currentTerm: String
    let courses: [CourseRecord]
    let firstDay: Date?
    let timeTable: [TimeSlot]

    init(cache: ScheduleCache) {
        data = cache.classroomData
        currentTerm = cache.currentTerm
        courses = cache.courses
        firstDay = cache.firstDay
        timeTable = cache.timeTable
    }

    subscript<Value>(dynamicMember keyPath: KeyPath<ScheduleClassroomData, Value>) -> Value {
        data[keyPath: keyPath]
    }
    subscript<Value>(dynamicMember keyPath: WritableKeyPath<ScheduleClassroomData, Value>) -> Value {
        get { data[keyPath: keyPath] }
        set { data[keyPath: keyPath] = newValue }
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
        get { cache.presentation }
        set { if acceptsEdits { cache.presentation = newValue } }
    }

    var syncState: ScheduleSyncState {
        get { ScheduleSyncState(cache: cache) }
        set { if acceptsEdits { cache.syncData.iCloudSyncEnabled = newValue.iCloudSyncEnabled } }
    }

    var courseState: ScheduleCourseState {
        get { ScheduleCourseState(cache: cache) }
        set { if acceptsEdits { cache.courseData = newValue.data } }
    }

    var ddlState: ScheduleDDLState {
        get { cache.ddlData }
        set { if acceptsEdits { cache.ddlData = newValue } }
    }

    var classroomState: ScheduleClassroomState {
        get { ScheduleClassroomState(cache: cache) }
        set { if acceptsEdits { cache.classroomData = newValue.data } }
    }

    func resolveCurrentTerm(_ term: String) {
        guard acceptsEdits, cache.currentTerm.isEmpty else { return }
        cache.currentTerm = term
    }

    func updateCourses(previousCourses: [CourseRecord], currentCourses: [CourseRecord]) {
        guard acceptsEdits else { return }
        ScheduleCourseEditor.updateCacheForManualCourseChange(
            in: &cache,
            previousCourses: previousCourses,
            currentCourses: currentCourses
        )
    }
}
