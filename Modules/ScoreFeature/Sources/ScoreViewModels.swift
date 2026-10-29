import ScoreDomain
import ScorePorts
import StorageCore
import TransportCore
import ClientCore
import DesignSystemKit
import Combine
import Foundation

private nonisolated enum ScorePersistenceError: LocalizedError {
    case saveFailed
    var errorDescription: String? { "成绩已取得，本地保存失败。请重试同步。" }
}

/// 管理完整成绩查询、缓存恢复、筛选同步、统计汇总和错误提示。
@MainActor
public final class ScoreViewModel: ObservableObject {
    /// 全量成绩数据。
    @Published private(set) var rows: [ScoreRow] = [] { didSet { invalidateProjection() } }
    /// 页面加载状态。
    @Published private(set) var state: ScoreLoadState = .idle
    /// 当前可选学期列表。
    @Published private(set) var availableTerms: [String] = []
    /// 按实际成绩动态生成的课程性质列表。
    @Published private(set) var availableCourseTypes: [String] = []
    /// 当前选中的学期集合。
    @Published private(set) var selectedTerms: Set<String> = [] { didSet { invalidateProjection() } }
    /// 当前选中的课程性质集合。
    @Published private(set) var selectedCourseTypes: Set<String> = [] { didSet { invalidateProjection() } }
    @Published private(set) var allowsDiagnostics = true
    @Published private(set) var failureCause: (any Error)?
    /// 当前成绩列表排序索引。
    @Published private(set) var sortIndex: ScoreSortIndex = .courseName { didSet { visibleProjection = nil } }
    /// 当前成绩列表排序方向。
    @Published private(set) var sortOrder: ScoreSortOrder = .ascending { didSet { visibleProjection = nil } }
    /// 是否正在同步基础成绩列表。
    enum RefreshPhase {
        case idle, authenticating, awaitingVerification, summary, details
        var isSyncing: Bool { self == .authenticating || self == .summary || self == .details }
    }
    @Published private(set) var refreshPhase = RefreshPhase.idle
    var isSyncing: Bool { refreshPhase.isSyncing }
    /// 两阶段查询进度使用现有同步提示区域展示，查询过程保持页面内反馈。
    @Published private(set) var syncStatusText = "同步中"
    /// 最近一次成功写入成绩缓存的时间；刷新失败时保留该时间。
    @Published private(set) var lastUpdatedAt: Date?
    /// 已缓存课表可确认的未出分课程；对应学期课表缺失时返回 nil。
    @Published private(set) var pendingCourses: [ScoreCourseSummary]?
    /// 当前等待用户输入图形或短信验证码的短期认证挑战。
    @Published private(set) var verificationChallenge: BITLoginAuthenticationChallenge? {
        didSet {
            if verificationChallenge != nil { refreshPhase = .awaitingVerification }
            else if refreshPhase == .awaitingVerification { refreshPhase = .idle }
        }
    }
    /// 验证码提交过程的行内错误提示。
    @Published private(set) var verificationError: String?
    @Published private(set) var isSubmittingVerificationCode = false
    @Published var alert: AppAlert?
    @Published private(set) var needsStorageRecovery = false
    @Published private(set) var isRecoveringStorage = false
    @Published var isStorageRecoveryPresented = false
    private var recoverySession: AppStorageSession?

    private let service: any ScoreListServicing
    private let currentScoreCacheSession: @MainActor () -> AppStorageSession
    private let loadScheduleCourses: @MainActor (AppStorageSession) async -> [String: [ScoreCourseSummary]]
    private var isRefreshing: Bool { refreshPhase.isSyncing }
    private var hasContent: Bool { !rows.isEmpty || state == .loaded }
    /// 账号切换后递增，使此前启动的请求失去页面与缓存写入资格。
    private(set) var accountGeneration = 0
    private var presentationGeneration = 0
    private var scheduleReadGeneration = 0
    private var activeRequestID: UUID?
    private var cancelActiveRequest: (() -> Void)?
    private var didRestoreCachedRows = false
    private var didInitializeTermSelection = false
    private var didInitializeCourseTypeSelection = false
    private var isSynchronizingScoreFields = false
    /// 初始化时读取一次已持久化的筛选快照。
    private let cacheStore: any ScoreCaching
    private let preferenceStore: any ScoreFilterPreferencesStoring
    private var preferenceSnapshot: ScoreFilterPreferenceSnapshot?
    private var preferenceObserver: AnyCancellable?
    private var scoreCacheObserver: AnyCancellable?
    private var scheduleCacheObserver: AnyCancellable?
    private var cachedCoursesByTerm: [String: [ScoreCourseSummary]] = [:]

    public init(
        service: any ScoreListServicing,
        cacheStore: any ScoreCaching,
        preferenceStore: any ScoreFilterPreferencesStoring,
        currentScoreCacheSession: @escaping @MainActor () -> AppStorageSession,
        scheduleCoursesChanges: AnyPublisher<AppStorageSession, Never>,
        loadScheduleCourses: @escaping @MainActor (AppStorageSession) async -> [String: [ScoreCourseSummary]]
    ) {
        self.service = service
        self.cacheStore = cacheStore
        self.preferenceStore = preferenceStore
        self.preferenceSnapshot = preferenceStore.load()
        self.currentScoreCacheSession = currentScoreCacheSession
        self.loadScheduleCourses = loadScheduleCourses
        restoreSortPreferences()
        preferenceObserver = preferenceStore.changes.sink { [weak self] session in
            guard let self, session == self.currentScoreCacheSession() else { return }
            self.applyPersistedFilterPreferences()
        }
        scoreCacheObserver = cacheStore.changes.sink { [weak self] session in
            guard let self, session == self.currentScoreCacheSession() else { return }
            let generation = self.accountGeneration
            Task { @MainActor [weak self] in
                guard let self, self.accountGeneration == generation, session == self.currentScoreCacheSession() else { return }
                await self.applySyncedScoreCacheIfAvailable()
            }
        }
        scheduleCacheObserver = scheduleCoursesChanges.sink { [weak self] session in
            guard let self, session == self.currentScoreCacheSession() else { return }
            let generation = self.accountGeneration
            self.scheduleReadGeneration &+= 1
            let readGeneration = self.scheduleReadGeneration
            Task { @MainActor [weak self] in
                guard let self, self.accountGeneration == generation, session == self.currentScoreCacheSession(),
                      self.scheduleReadGeneration == readGeneration else { return }
                await self.loadCachedScheduleCourses(for: session, generation: generation, readGeneration: readGeneration)
            }
        }
        updateFilterStorageRecovery()
    }

    /// 切换账号后重置内存状态；下一次启动按新学号恢复磁盘缓存。
    public func resetForCurrentAccount() {
        isSynchronizingScoreFields = false
        recoverySession = nil
        isStorageRecoveryPresented = false
        isRecoveringStorage = false
        needsStorageRecovery = false
        accountGeneration &+= 1
        presentationGeneration &+= 1
        scheduleReadGeneration &+= 1
        cancelActiveRequest?()
        cancelActiveRequest = nil
        activeRequestID = nil
        rows = []
        state = .idle
        availableTerms = []
        availableCourseTypes = []
        selectedTerms = []
        selectedCourseTypes = []
        failureCause = nil
        allowsDiagnostics = true
        pendingCourses = nil
        verificationChallenge = nil
        verificationError = nil
        isSubmittingVerificationCode = false
        refreshPhase = .idle
        syncStatusText = "同步中"
        lastUpdatedAt = nil
        didRestoreCachedRows = false
        didInitializeTermSelection = false
        didInitializeCourseTypeSelection = false
        cachedCoursesByTerm = [:]
        preferenceSnapshot = preferenceStore.load()
        restoreSortPreferences()
        alert = nil
        updateFilterStorageRecovery()
    }

    /// 进入成绩页时恢复本地缓存；学校请求由用户操作触发。
    ///
    /// “查询成绩”和刷新按钮触发真实成绩查询，验证码在当前操作链路中展示。
    func restoreCachedDataIfNeeded() async {
        guard state == .idle || !didRestoreCachedRows,
              !isRefreshing, !isSubmittingVerificationCode, verificationChallenge == nil else { return }
        let presentation = presentationGeneration
        let session = currentScoreCacheSession()
        let generation = accountGeneration
        await refreshCachedScheduleCourses(for: session, generation: generation)
        guard isCurrent(session, generation: generation), presentation == presentationGeneration else { return }
        await restoreCachedRowsIfAvailable(for: session, generation: generation)
        guard isCurrent(session, generation: generation) else { return }
        if state == .idle { applyRows(rows) }
    }

    private func refreshCachedScheduleCourses(
        for session: AppStorageSession,
        generation: Int
    ) async {
        guard isCurrent(session, generation: generation) else { return }
        scheduleReadGeneration &+= 1
        await loadCachedScheduleCourses(for: session, generation: generation, readGeneration: scheduleReadGeneration)
    }

    private func loadCachedScheduleCourses(for session: AppStorageSession, generation: Int, readGeneration: Int) async {
        let courses = await loadScheduleCourses(session)
        guard isCurrent(session, generation: generation), readGeneration == scheduleReadGeneration else { return }
        cachedCoursesByTerm = courses
        if state != .idle {
            let previousTerms = Set(availableTerms), previousTypes = Set(availableCourseTypes)
            updateFilterOptions()
            synchronizeFilters(previousTerms: previousTerms, previousTypes: previousTypes)
            pendingCourses = calculatePendingCourses()
        }
    }

    /// 刷新成绩列表。
    ///
    /// 页面已有内容时在原列表上刷新数据。
    func refresh(showErrors: Bool = true) async {
        guard !isRefreshing, !isSubmittingVerificationCode, verificationChallenge == nil, !isRecoveringStorage else { return }
        alert = nil
        presentationGeneration &+= 1

        let session = currentScoreCacheSession()
        let generation = accountGeneration
        let hadContent = hasContent
        verificationChallenge = nil
        verificationError = nil
        refreshPhase = .authenticating
        failureCause = nil
        allowsDiagnostics = true
        syncStatusText = "同步简略成绩中"
        if !hadContent {
            state = .loading
        }

        defer {
            if isCurrent(session, generation: generation) {
                refreshPhase = verificationChallenge == nil ? .idle : .awaitingVerification
            }
        }

        do {
            let challengeTask = Task { @MainActor [service = self.service] in
                try await service.startScoreChallenge()
            }
            let challenge = try await awaitTrackedRequest(challengeTask)
            guard isCurrent(session, generation: generation) else { return }
            try await synchronizeScores(
                authenticatedBy: challenge,
                session: session,
                generation: generation
            )
        } catch ScoreServiceError.secondFactorRequired(let challenge) {
            guard isCurrent(session, generation: generation) else { return }
            verificationChallenge = challenge
            state = hasContent ? .loaded : .loading
        } catch ScoreServiceError.challengeInvalid(let message) {
            guard isCurrent(session, generation: generation) else { return }
            failureCause = ScoreServiceError.challengeInvalid(message)
            verificationChallenge = nil
            verificationError = nil
            if hasContent {
                state = .loaded
                if showErrors {
                    alert = AppAlert.userInput(title: "验证已失效", message: message, underlyingError: failureCause)
                }
            } else {
                allowsDiagnostics = false
                state = .failed(message)
                if showErrors {
                    alert = AppAlert.userInput(title: "验证已失效", message: message, underlyingError: failureCause)
                }
            }
        } catch {
            guard isCurrent(session, generation: generation) else { return }
            if TaskCancellation.matches(error) {
                state = hasContent ? .loaded : .idle
                return
            }

            if error is ScorePersistenceError {
                failureCause = error
                state = rows.isEmpty ? .failed(error.localizedDescription) : .loaded
                if showErrors { alert = AppAlert(title: "成绩保存失败", error: error) }
                return
            }

            if hasContent {
                state = .loaded
                if showErrors {
                    alert = AppAlert(title: "成绩刷新失败", error: error)
                }
                return
            }

            rows = []
            availableTerms = []
            availableCourseTypes = []
            selectedTerms = []
            selectedCourseTypes = []
            failureCause = error
            state = .failed(error.localizedDescription)
            if showErrors {
                alert = AppAlert(title: "成绩查询失败", error: error)
            }
        }
    }

    /// 提交原生验证码输入框中的一次性代码，并在认证成功后完成成绩刷新。
    func submitVerificationCode(_ code: String) async {
        guard let challenge = verificationChallenge, !isSubmittingVerificationCode else { return }
        let session = currentScoreCacheSession()
        let generation = accountGeneration

        let normalizedCode = AppVerificationCode.normalize(code, isCaptcha: challenge.isCaptcha)
        guard AppVerificationCode.isValid(normalizedCode, isCaptcha: challenge.isCaptcha) else {
            verificationError = AppVerificationCode.validationMessage(isCaptcha: challenge.isCaptcha)
            return
        }

        isSubmittingVerificationCode = true
        verificationError = nil
        defer {
            if isCurrent(session, generation: generation) {
                isSubmittingVerificationCode = false
            }
        }

        do {
            let submitTask = Task { @MainActor [service = self.service] in
                try await service.submitScoreVerificationCode(normalizedCode, for: challenge)
            }
            let authenticatedChallenge = try await awaitTrackedRequest(submitTask)
            guard isCurrent(session, generation: generation) else { return }
            verificationChallenge = nil
            refreshPhase = .summary
            syncStatusText = "同步简略成绩中"
            defer {
                if isCurrent(session, generation: generation) {
                    refreshPhase = verificationChallenge == nil ? .idle : .awaitingVerification
                }
            }
            try await synchronizeScores(
                authenticatedBy: authenticatedChallenge,
                session: session,
                generation: generation
            )
        } catch ScoreServiceError.secondFactorRequired(let challenge) {
            guard isCurrent(session, generation: generation) else { return }
            verificationChallenge = challenge
            verificationError = nil
        } catch ScoreServiceError.challengeInvalid(let message) {
            guard isCurrent(session, generation: generation) else { return }
            failureCause = ScoreServiceError.challengeInvalid(message)
            verificationChallenge = nil
            verificationError = nil
            allowsDiagnostics = false
            if rows.isEmpty {
                state = .failed(message)
            }
            alert = AppAlert.userInput(title: "验证已失效", message: message, underlyingError: failureCause)
        } catch {
            guard isCurrent(session, generation: generation) else { return }
            if TaskCancellation.matches(error) {
                state = rows.isEmpty ? .idle : .loaded
                return
            }
            if verificationChallenge != nil, SchoolServiceFailure.from(error) == nil {
                verificationError = error.localizedDescription
            } else {
                verificationChallenge = nil
                failureCause = error
                state = rows.isEmpty ? .failed(error.localizedDescription) : .loaded
                alert = AppAlert(title: error is ScorePersistenceError ? "成绩保存失败" : "成绩查询失败", error: error)
            }
        }
    }

    /// 使用同一个认证会话依次获取简略列表和完整详细字段。
    ///
    /// 简略结果到达后立即更新页面，详细请求完成后保存完整缓存。
    /// 状态文案随实际请求阶段更新。
    private func synchronizeScores(
        authenticatedBy challenge: BITLoginAuthenticationChallenge,
        session: AppStorageSession,
        generation: Int
    ) async throws {
        isSynchronizingScoreFields = true
        defer {
            if isCurrent(session, generation: generation) {
                isSynchronizingScoreFields = false
                if !Task.isCancelled { persistFilterPreferences() }
            }
        }
        refreshPhase = .summary
        let cachedSnapshot: ScoreCacheSnapshot?
        do {
            cachedSnapshot = try await cacheStore.loadSnapshot(for: session)
        } catch {
            if TaskCancellation.matches(error) { throw error }
            cachedSnapshot = nil
            needsStorageRecovery = true
        }
        guard isCurrent(session, generation: generation) else { return }
        let cachedRows = cachedSnapshot?.rows
        let previousRows = rows.isEmpty ? cachedRows ?? [] : rows
        let briefTask = Task { @MainActor [service = self.service] in
            try await service.fetchScores(detail: false, authenticatedBy: challenge)
        }
        let briefRows = try await awaitTrackedRequest(briefTask)
        guard isCurrent(session, generation: generation) else { return }
        let availableRows = ScoreRowComparison.retainingDetailedFields(briefRows, from: previousRows)
        applyRows(availableRows)

        refreshPhase = .details
        syncStatusText = "同步详细信息中"
        let detailedRowsTask = Task { @MainActor [service = self.service] in
            try await service.fetchScores(
                detail: true,
                authenticatedBy: challenge
            )
        }
        do {
            let detailedRows = try await awaitTrackedRequest(detailedRowsTask)
            guard isCurrent(session, generation: generation) else { return }
            let scoresAreIdentical = cachedRows.map { ScoreRowComparison.rowsMatch(detailedRows, $0) } ?? false
            applyRows(detailedRows)
            let updatedAt = try await saveCurrentRows(detailedRows, detail: true, session: session, generation: generation)
            guard isCurrent(session, generation: generation) else { return }
            guard let updatedAt else { needsStorageRecovery = true; throw ScorePersistenceError.saveFailed }
            lastUpdatedAt = updatedAt
            if scoresAreIdentical {
                presentUnchangedNotice()
            }
        } catch {
            guard isCurrent(session, generation: generation) else { return }
            if TaskCancellation.matches(error) {
                if !previousRows.isEmpty { applyRows(previousRows) }
                throw error
            }
            if error is ScorePersistenceError { throw error }
            if let partial = error as? PartialScoreResult {
                let available = ScoreRowComparison.retainingDetailedFields(partial.rows, from: previousRows)
                applyRows(available)
                let updatedAt = try await saveCurrentRows(available, detail: false, session: session, generation: generation)
                guard isCurrent(session, generation: generation) else { return }
                guard let updatedAt else { needsStorageRecovery = true; throw ScorePersistenceError.saveFailed }
                lastUpdatedAt = updatedAt
                throw partial
            }
            if let cachedRows,
               ScoreRowComparison.briefRowsMatchCache(briefRows, cachedRows: cachedRows)
            {
                // 简略成绩保持一致时，详细刷新失败会继续使用缓存中的完整字段。
                applyRows(cachedRows)
                lastUpdatedAt = cachedSnapshot?.updatedAt
            } else {
                let updatedAt = try await saveCurrentRows(availableRows, detail: false, session: session, generation: generation)
                guard isCurrent(session, generation: generation) else { return }
                guard let updatedAt else { needsStorageRecovery = true; throw ScorePersistenceError.saveFailed }
                lastUpdatedAt = updatedAt
            }
            throw error
        }
    }

    private func presentUnchangedNotice() {
        alert = AppAlert.informational(
            title: "成绩已是最新",
            message: "本次获取结果与本地成绩完全一致。"
        )
    }

    /// 用户关闭验证码面板后释放内存中的短期令牌，服务端清理过期挑战。
    func dismissVerificationChallenge() {
        guard !isSubmittingVerificationCode else { return }
        verificationChallenge = nil
        verificationError = nil
        allowsDiagnostics = false
        if rows.isEmpty {
            state = .failed("需要完成学校验证才能查询成绩。")
        }
    }

    /// 当前筛选条件下实际可见的成绩。
    ///
    /// 成绩列表和统计摘要均基于这份过滤结果，全量 `rows` 作为原始数据源。
    var filteredRows: [ScoreRow] {
        if let filteredProjection { return filteredProjection }
        let values = rows.filter { row in
            let matchesTerm = selectedTerms.contains(normalizedFilterValue(row.term))
            let matchesType = matchesSelectedCourseType(row.courseType)
            return matchesTerm && matchesType
        }
        filteredProjection = values
        return values
    }

    /// 当前筛选与排序条件下实际展示的成绩。
    var visibleRows: [ScoreRow] {
        if let visibleProjection { return visibleProjection }
        let rowsForDisplay = filteredRows

        let values = rowsForDisplay.enumerated()
            .sorted { lhs, rhs in
                let lhsMissingValue = sortIndex.isMissingValue(in: lhs.element)
                let rhsMissingValue = sortIndex.isMissingValue(in: rhs.element)

                if lhsMissingValue != rhsMissingValue {
                    return !lhsMissingValue
                }

                let comparison = sortIndex.compare(lhs.element, rhs.element)
                if comparison == .orderedSame {
                    return lhs.offset < rhs.offset
                }

                switch sortOrder {
                case .ascending:
                    return comparison == .orderedAscending
                case .descending:
                    return comparison == .orderedDescending
                }
            }
            .map(\.element)
        visibleProjection = values
        return values
    }

    /// 当前筛选结果对应的统计摘要。
    var summary: ScoreSummary {
        if let summaryProjection { return summaryProjection }
        let value = ScoreSummary.make(from: filteredRows)
        summaryProjection = value
        return value
    }

    private var filteredProjection: [ScoreRow]?
    private var visibleProjection: [ScoreRow]?
    private var summaryProjection: ScoreSummary?
    private func invalidateProjection() {
        filteredProjection = nil
        visibleProjection = nil
        summaryProjection = nil
    }

    /// 根据本机已缓存的同学期课表，估算仍未出分的去重课程数。
    ///
    /// 对应学期缓存缺失时返回 `nil`，页面据此区分未知状态与 0。
    private func calculatePendingCourses() -> [ScoreCourseSummary]? {
        let scoreTerms = selectedTerms
        guard !scoreTerms.isEmpty else { return nil }

        let cachedCoursesByTerm = self.cachedCoursesByTerm.reduce(
            into: [String: [ScoreCourseSummary]]()
        ) { result, entry in
            let normalizedTerm = normalizedFilterValue(entry.key)
            guard !normalizedTerm.isEmpty else { return }
            result[normalizedTerm, default: []].append(contentsOf: entry.value)
        }
        let coveredTerms = scoreTerms.filter { cachedCoursesByTerm[$0] != nil }
        guard coveredTerms.count == scoreTerms.count else { return nil }
        guard availableCourseTypes.isEmpty || !selectedCourseTypes.isEmpty else { return [] }

        let scoredNumbers = Set(rows.compactMap { row -> String? in
            let number = normalizedCourseIdentity(row.courseNumber)
            let term = normalizedFilterValue(row.term)
            return number.isEmpty || term.isEmpty ? nil : "\(term)|\(number)"
        })
        let scoredNames = Set(rows.compactMap { row -> String? in
            let name = normalizedCourseIdentity(row.courseName)
            let term = normalizedFilterValue(row.term)
            return name.isEmpty || term.isEmpty ? nil : "\(term)|\(name)"
        })
        let scoredNamesWithoutNumbers = Set(rows.compactMap { row -> String? in
            let name = normalizedCourseIdentity(row.courseName)
            let term = normalizedFilterValue(row.term)
            return normalizedCourseIdentity(row.courseNumber).isEmpty && !name.isEmpty && !term.isEmpty ? "\(term)|\(name)" : nil
        })
        var pendingByIdentity: [String: ScoreCourseSummary] = [:]

        for term in coveredTerms {
            for course in cachedCoursesByTerm[term] ?? [] {
                guard matchesSelectedCourseType(course.type) else { continue }
                let number = normalizedCourseIdentity(course.number)
                let name = normalizedCourseIdentity(course.name)
                let hasScore = (!number.isEmpty && scoredNumbers.contains("\(term)|\(number)"))
                    || (!name.isEmpty && (number.isEmpty ? scoredNames : scoredNamesWithoutNumbers).contains("\(term)|\(name)"))
                guard !hasScore else { continue }

                guard !name.isEmpty || !number.isEmpty else { continue }
                let identity = !number.isEmpty ? "\(term)|n|\(number)" : "\(term)|t|\(name)"
                pendingByIdentity[identity] = pendingByIdentity[identity] ?? course
            }
        }
        return pendingByIdentity.values.sorted { lhs, rhs in
            let termOrder = lhs.term.localizedStandardCompare(rhs.term)
            if termOrder != .orderedSame {
                return termOrder == .orderedDescending
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// 所选学期尚未出分的课程数。
    var pendingCourseCount: Int? {
        pendingCourses?.count
    }

    /// 当前排序偏好的人类可读摘要。
    var sortDescription: String {
        "\(sortIndex.title) · \(sortOrder.title)"
    }

    /// 更新学期筛选结果，并保留现有选项中的有效值。
    func setSelectedTerms(_ values: Set<String>) {
        selectedTerms = values.intersection(Set(availableTerms))
        pendingCourses = calculatePendingCourses()
        persistFilterPreferences()
    }

    /// 更新课程性质筛选结果，并保留现有选项中的有效值。
    func setSelectedCourseTypes(_ values: Set<String>) {
        selectedCourseTypes = values.intersection(Set(availableCourseTypes))
        pendingCourses = calculatePendingCourses()
        persistFilterPreferences()
    }

    /// 在“全选学期”和“全不选学期”之间切换。
    func toggleAllTerms() {
        let allTerms = Set(availableTerms)
        selectedTerms = selectedTerms == allTerms ? [] : allTerms
        pendingCourses = calculatePendingCourses()
        persistFilterPreferences()
    }

    /// 在“全选课程性质”和“全不选课程性质”之间切换。
    func toggleAllCourseTypes() {
        let allCourseTypes = Set(availableCourseTypes)
        selectedCourseTypes = selectedCourseTypes == allCourseTypes ? [] : allCourseTypes
        pendingCourses = calculatePendingCourses()
        persistFilterPreferences()
    }

    /// 设置成绩列表排序索引。
    func setSortIndex(_ value: ScoreSortIndex) {
        sortIndex = value
        persistFilterPreferences()
    }

    /// 设置成绩列表排序方向。
    func setSortOrder(_ value: ScoreSortOrder) {
        sortOrder = value
        persistFilterPreferences()
    }

    /// 在升序和降序之间切换。
    func toggleSortOrder() {
        sortOrder = sortOrder.toggled
        persistFilterPreferences()
    }

    /// 恢复本机缓存的成绩列表。
    private func restoreCachedRowsIfAvailable(
        for session: AppStorageSession,
        generation: Int
    ) async {
        guard !didRestoreCachedRows else { return }
        presentationGeneration &+= 1
        let presentation = presentationGeneration
        let snapshot: ScoreCacheSnapshot?
        do { snapshot = try await cacheStore.loadSnapshot(for: session) }
        catch {
            guard isCurrent(session, generation: generation), presentation == presentationGeneration,
                  !isRefreshing, !isSubmittingVerificationCode, verificationChallenge == nil else { return }
            presentCacheReadFailure(error)
            return
        }
        guard isCurrent(session, generation: generation), presentation == presentationGeneration,
              !isRefreshing, !isSubmittingVerificationCode, verificationChallenge == nil else { return }
        didRestoreCachedRows = true
        guard let snapshot, let rows = snapshot.rows else { state = .idle; return }
        lastUpdatedAt = snapshot.updatedAt
        applyRows(rows)
    }

    /// iCloud 成绩缓存到达时立即刷新当前页面，页面继续使用本地缓存数据。
    func applySyncedScoreCacheIfAvailable() async {
        guard !isRefreshing, !isSubmittingVerificationCode, verificationChallenge == nil, !isRecoveringStorage else { return }
        presentationGeneration &+= 1
        let presentation = presentationGeneration
        let session = currentScoreCacheSession()
        let generation = accountGeneration
        let snapshot: ScoreCacheSnapshot?
        do { snapshot = try await cacheStore.loadSnapshot(for: session) }
        catch {
            guard isCurrent(session, generation: generation), presentation == presentationGeneration,
                  !isRefreshing, !isSubmittingVerificationCode, verificationChallenge == nil else { return }
            didRestoreCachedRows = false
            presentCacheReadFailure(error)
            return
        }
        guard let snapshot, isCurrent(session, generation: generation), presentation == presentationGeneration,
              !isRefreshing, !isSubmittingVerificationCode, verificationChallenge == nil, let cachedRows = snapshot.rows else { return }
        didRestoreCachedRows = true
        lastUpdatedAt = snapshot.updatedAt
        applyRows(cachedRows)
    }

    private func presentCacheReadFailure(_ error: Error) {
        guard !TaskCancellation.matches(error) else { return }
        needsStorageRecovery = true
        if hasContent {
            state = .loaded
            alert = AppAlert(title: "成绩缓存读取受阻", error: error)
        } else {
            failureCause = error
            state = .failed(error.localizedDescription)
        }
    }

    /// 非同步状态下常驻显示的最近更新时间。
    var lastUpdatedText: String {
        guard let lastUpdatedAt else { return "更新时间：暂无记录" }
        return "更新时间：\(lastUpdatedAt.formatted(.dateTime.month().day().hour().minute()))"
    }

    /// 应用一份成绩列表，并同步筛选项。
    private func applyRows(_ newRows: [ScoreRow]) {
        presentationGeneration &+= 1
        rows = newRows
        let previousTerms = Set(availableTerms), previousTypes = Set(availableCourseTypes)
        updateFilterOptions()
        synchronizeFilters(previousTerms: previousTerms, previousTypes: previousTypes)
        pendingCourses = calculatePendingCourses()
        state = .loaded
    }

    private func updateFilterOptions() {
        availableTerms = uniqueFilterValues(from: rows.map(\.term) + Array(cachedCoursesByTerm.keys).sorted())
        availableCourseTypes = uniqueFilterValues(from: rows.map(\.courseType)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    /// 刷新可选项后，同步修正当前筛选集合。
    ///
    /// 首次进入时恢复本地偏好；后续刷新时把当前筛选限制在现有选项范围内。
    private func synchronizeFilters(previousTerms: Set<String>, previousTypes: Set<String>) {
        let originalTerms = selectedTerms
        let previousCourseTypes = selectedCourseTypes
        let termSet = Set(availableTerms)
        let typeSet = Set(availableCourseTypes)

        if !didInitializeTermSelection, !termSet.isEmpty {
            if let persistedTerms = preferenceSnapshot?.selectedTerms {
                selectedTerms = restoredFilterSelection(persistedTerms, options: termSet)
            } else {
                selectedTerms = termSet
            }
            didInitializeTermSelection = true
        } else if didInitializeTermSelection, !termSet.isEmpty {
            selectedTerms = !previousTerms.isEmpty && selectedTerms == previousTerms ? termSet : selectedTerms.intersection(termSet)
        }

        if !didInitializeCourseTypeSelection, !typeSet.isEmpty {
            if let persistedCourseTypes = preferenceSnapshot?.selectedCourseTypes {
                selectedCourseTypes = restoredFilterSelection(persistedCourseTypes, options: typeSet)
            } else {
                selectedCourseTypes = typeSet
            }
            didInitializeCourseTypeSelection = true
        } else if didInitializeCourseTypeSelection, !typeSet.isEmpty {
            selectedCourseTypes = !previousTypes.isEmpty && selectedCourseTypes == previousTypes ? typeSet : selectedCourseTypes.intersection(typeSet)
        }

        if originalTerms != selectedTerms || previousCourseTypes != selectedCourseTypes {
            persistFilterPreferences()
        }
    }

    /// iCloud 拉取完成后立即更新已存在的成绩页面。
    private func applyPersistedFilterPreferences() {
        preferenceSnapshot = preferenceStore.load()
        updateFilterStorageRecovery()
        guard let preferenceSnapshot else { return }

        restoreSortPreferences()
        if didInitializeTermSelection {
            selectedTerms = restoredFilterSelection(preferenceSnapshot.selectedTerms, options: Set(availableTerms))
        }
        if didInitializeCourseTypeSelection {
            selectedCourseTypes = restoredFilterSelection(preferenceSnapshot.selectedCourseTypes, options: Set(availableCourseTypes))
        }
        pendingCourses = calculatePendingCourses()
    }

    private func matchesSelectedCourseType(_ value: String) -> Bool {
        availableCourseTypes.isEmpty || selectedCourseTypes.count == availableCourseTypes.count
            || selectedCourseTypes.contains(normalizedFilterValue(value))
    }

    private func restoredFilterSelection(_ values: [String], options: Set<String>) -> Set<String> {
        let selection = Set(values).intersection(options)
        return selection.isEmpty && !values.isEmpty ? options : selection
    }

    private func restoreSortPreferences() {
        sortIndex = preferenceSnapshot?.sortIndex.flatMap(ScoreSortIndex.init(rawValue:)) ?? .courseName
        sortOrder = preferenceSnapshot?.sortOrder.flatMap(ScoreSortOrder.init(rawValue:)) ?? .ascending
    }

    /// 提取筛选项并保留原始出现顺序，缺失字段归入“未分类”。
    private func uniqueFilterValues(from source: [String]) -> [String] {
        var seen = Set<String>()
        var values: [String] = []
        for item in source {
            let trimmed = normalizedFilterValue(item)
            guard !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            values.append(trimmed)
        }
        return values
    }

    /// 课程号和名称比较时忽略空白及大小写差异。
    private func normalizedCourseIdentity(_ value: String) -> String {
        value.components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .lowercased()
    }

    private func normalizedFilterValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未分类" : trimmed
    }

    /// 保存当前筛选结果到本地偏好。
    private func persistFilterPreferences() {
        guard !isSynchronizingScoreFields else { return }
        if preferenceStore.hasUnreadableSnapshot { needsStorageRecovery = true; return }
        guard preferenceSnapshot != nil
                || (didInitializeTermSelection && (didInitializeCourseTypeSelection || !rows.isEmpty)) else { return }
        let saved = preferenceStore.save(
            selectedTerms: didInitializeTermSelection ? selectedTerms : Set(preferenceSnapshot?.selectedTerms ?? []),
            selectedCourseTypes: didInitializeCourseTypeSelection ? selectedCourseTypes : Set(preferenceSnapshot?.selectedCourseTypes ?? []),
            sortIndex: sortIndex,
            sortOrder: sortOrder
        )
        if !saved {
            needsStorageRecovery = true
            alert = AppAlert(title: "筛选偏好保存受阻", message: "当前筛选与排序在本次使用中生效。原始偏好数据已保留，可通过“恢复成绩存储”重建本账号的成绩与筛选。")
        }
    }

    private func updateFilterStorageRecovery() {
        if preferenceStore.hasUnreadableSnapshot {
            needsStorageRecovery = true
        }
    }

    func requestStorageRecovery() {
        guard !isSyncing, !isSubmittingVerificationCode, verificationChallenge == nil, !isRecoveringStorage else { return }
        recoverySession = currentScoreCacheSession()
        alert = nil
        isStorageRecoveryPresented = true
    }

    func cancelStorageRecovery() {
        recoverySession = nil
        isStorageRecoveryPresented = false
    }

    func recoverStorage() async {
        guard let session = recoverySession, session == currentScoreCacheSession(),
              !isSyncing, !isSubmittingVerificationCode, verificationChallenge == nil, !isRecoveringStorage else { return }
        recoverySession = nil
        isStorageRecoveryPresented = false
        let generation = accountGeneration
        presentationGeneration &+= 1
        let presentation = presentationGeneration
        let availableRows = rows
        isRecoveringStorage = true
        defer { if isCurrent(session, generation: generation) { isRecoveringStorage = false } }
        let saved = await cacheStore.recover(rows: availableRows, for: session)
        guard isCurrent(session, generation: generation), presentation == presentationGeneration else { return }
        guard let saved else {
            alert = AppAlert(title: "成绩存储恢复受阻", message: "原始缓存已保留，请稍后重试。")
            return
        }
        preferenceStore.reset()
        preferenceSnapshot = nil
        didInitializeTermSelection = false
        didInitializeCourseTypeSelection = false
        restoreSortPreferences()
        needsStorageRecovery = false
        lastUpdatedAt = saved
        didRestoreCachedRows = true
        applyRows(availableRows)
    }

    private func isCurrent(_ session: AppStorageSession, generation: Int) -> Bool {
        accountGeneration == generation && currentScoreCacheSession() == session
    }

    private func saveCurrentRows(_ rows: [ScoreRow], detail: Bool, session: AppStorageSession, generation: Int) async throws -> Date? {
        let task = Task { @MainActor in
            guard self.isCurrent(session, generation: generation) else { throw CancellationError() }
            if detail { return await self.cacheStore.saveDetailed(rows: rows, for: session) }
            return await self.cacheStore.save(rows: rows, for: session)
        }
        return try await awaitTrackedRequest(task)
    }

    private func awaitTrackedRequest<Value: Sendable>(
        _ task: Task<Value, Error>
    ) async throws -> Value {
        let requestID = UUID()
        activeRequestID = requestID
        cancelActiveRequest = { task.cancel() }
        defer {
            task.cancel()
            if activeRequestID == requestID {
                activeRequestID = nil
                cancelActiveRequest = nil
            }
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let value = try await task.value
            try Task.checkCancellation()
            return value
        } onCancel: {
            task.cancel()
        }
    }
}
