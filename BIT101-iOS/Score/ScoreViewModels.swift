import Combine
import Foundation
import UIKit

/// 管理完整成绩查询、缓存恢复、筛选同步、统计汇总和错误提示。
@MainActor
final class ScoreViewModel: ObservableObject {
    /// 全量成绩数据。
    @Published private(set) var rows: [ScoreRow] = []
    /// 页面加载状态。
    @Published private(set) var state: ScoreLoadState = .idle
    /// 当前可选学期列表。
    @Published private(set) var availableTerms: [String] = []
    /// 当前可选课程性质列表。
    @Published private(set) var availableCourseTypes: [String] = []
    /// 当前选中的学期集合。
    @Published private(set) var selectedTerms: Set<String> = []
    /// 当前选中的课程性质集合。
    @Published private(set) var selectedCourseTypes: Set<String> = []
    /// 当前成绩列表排序索引。
    @Published private(set) var sortIndex: ScoreSortIndex = .courseName
    /// 当前成绩列表排序方向。
    @Published private(set) var sortOrder: ScoreSortOrder = .ascending
    /// 是否正在同步基础成绩列表。
    @Published private(set) var isSyncing = false
    /// 两阶段查询进度使用现有同步提示区域展示，查询过程保持页面内反馈。
    @Published private(set) var syncStatusText = "同步中"
    /// 最近一次成功写入成绩缓存的时间；刷新失败时保留该时间。
    @Published private(set) var lastUpdatedAt: Date?
    /// 已缓存课表可确认的未出分课程；对应学期课表缺失时返回 nil。
    @Published private(set) var pendingCourses: [CourseRecord]?
    /// 当前等待用户输入短信验证码的短期认证挑战。
    @Published private(set) var smsChallenge: BITLoginAuthenticationChallenge?
    /// 短信验证码提交过程的行内错误提示。
    @Published private(set) var smsVerificationError: String?
    @Published private(set) var isSubmittingSMSCode = false
    @Published var alert: AppAlert?

    private let service: any ScoreListServicing
    private var isRefreshing = false
    private var didRestoreCachedRows = false
    private var didInitializeTermSelection = false
    private var didInitializeCourseTypeSelection = false
    /// 经短信验证的刷新保留用户主动要求的详细成绩刷新策略。
    private var pendingRefreshForcesDetailed = false
    /// 初始化时读取一次已持久化的筛选快照。
    private var preferenceSnapshot = ScoreFilterPreferenceStore.load()
    private var preferenceObserver: NSObjectProtocol?
    private var scoreCacheObserver: NSObjectProtocol?

    init(
        service: any ScoreListServicing
    ) {
        self.service = service
        if
            let rawSortIndex = preferenceSnapshot?.sortIndex,
            let persistedSortIndex = ScoreSortIndex(rawValue: rawSortIndex)
        {
            sortIndex = persistedSortIndex
        }
        if
            let rawSortOrder = preferenceSnapshot?.sortOrder,
            let persistedSortOrder = ScoreSortOrder(rawValue: rawSortOrder)
        {
            sortOrder = persistedSortOrder
        }
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: .scoreFilterPreferencesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.applyPersistedFilterPreferences()
            }
        }
        scoreCacheObserver = NotificationCenter.default.addObserver(
            forName: .scoreCacheDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.applySyncedScoreCacheIfAvailable()
            }
        }
    }

    deinit {
        if let preferenceObserver {
            NotificationCenter.default.removeObserver(preferenceObserver)
        }
        if let scoreCacheObserver {
            NotificationCenter.default.removeObserver(scoreCacheObserver)
        }
    }

    convenience init() {
        self.init(service: ScoreService())
    }

    /// 切换账号后重置内存状态；下一次启动按新学号恢复磁盘缓存。
    func resetForCurrentAccount() {
        rows = []
        state = .idle
        availableTerms = []
        availableCourseTypes = []
        selectedTerms = []
        selectedCourseTypes = []
        pendingCourses = nil
        smsChallenge = nil
        smsVerificationError = nil
        isSubmittingSMSCode = false
        isRefreshing = false
        isSyncing = false
        syncStatusText = "同步中"
        lastUpdatedAt = nil
        didRestoreCachedRows = false
        didInitializeTermSelection = false
        didInitializeCourseTypeSelection = false
        pendingRefreshForcesDetailed = false
        preferenceSnapshot = ScoreFilterPreferenceStore.load()
        alert = nil
    }

    /// 进入成绩页时恢复本地缓存；学校和 WebVPN 请求由用户操作触发。
    ///
    /// “查询成绩”和下拉刷新触发真实成绩查询，短信验证码在当前操作链路中展示。
    func restoreCachedDataIfNeeded() {
        guard state == .idle else { return }
        restoreCachedRowsIfAvailable()
        if rows.isEmpty {
            state = .loaded
        }
    }

    /// 刷新成绩列表。
    ///
    /// 页面已有内容时在原列表上刷新数据。
    func refresh(
        showErrors: Bool = true,
        forceDetailedRefresh: Bool = true
    ) async {
        guard !isRefreshing, !isSubmittingSMSCode, smsChallenge == nil else { return }

        let hadContent = !rows.isEmpty || state == .loaded
        smsChallenge = nil
        smsVerificationError = nil
        isRefreshing = true
        pendingRefreshForcesDetailed = forceDetailedRefresh
        isSyncing = true
        syncStatusText = "同步简略成绩中"
        if !hadContent {
            state = .loading
        }

        defer {
            isRefreshing = false
            isSyncing = false
        }

        do {
            let challenge = try await service.startScoreChallenge()
            try await synchronizeScores(
                authenticatedBy: challenge,
                forceDetailedRefresh: forceDetailedRefresh
            )
        } catch ScoreServiceError.secondFactorRequired(let challenge) {
            smsChallenge = challenge
            state = hadContent ? .loaded : .loading
        } catch ScoreServiceError.challengeInvalid(let message) {
            smsChallenge = nil
            smsVerificationError = nil
            pendingRefreshForcesDetailed = false
            if hadContent {
                state = .loaded
                if showErrors {
                    alert = AppAlert(title: "验证已失效", message: message)
                }
            } else {
                state = .failed(message)
                if showErrors {
                    alert = AppAlert(title: "验证已失效", message: message)
                }
            }
        } catch {
            if isCancellation(error) {
                state = hadContent ? .loaded : .idle
                return
            }

            if hadContent {
                state = .loaded
                if showErrors {
                    alert = AppAlert(title: "成绩刷新失败", message: error.localizedDescription)
                }
                return
            }

            rows = []
            availableTerms = []
            availableCourseTypes = []
            selectedTerms = []
            selectedCourseTypes = []
            state = .failed(error.localizedDescription)
            if showErrors {
                alert = AppAlert(title: "成绩查询失败", message: error.localizedDescription)
            }
        }
    }

    /// 提交原生验证码输入框中的一次性代码，并在认证成功后完成成绩刷新。
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
            let authenticatedChallenge = try await service.submitScoreSMSCode(
                normalizedCode,
                for: challenge
            )
            smsChallenge = nil
            isSyncing = true
            syncStatusText = "同步简略成绩中"
            defer { isSyncing = false }
            let forceDetailedRefresh = pendingRefreshForcesDetailed
            pendingRefreshForcesDetailed = false
            try await synchronizeScores(
                authenticatedBy: authenticatedChallenge,
                forceDetailedRefresh: forceDetailedRefresh
            )
        } catch ScoreServiceError.secondFactorRequired(let challenge) {
            smsChallenge = challenge
            smsVerificationError = "请输入最新收到的短信验证码。"
        } catch ScoreServiceError.challengeInvalid(let message) {
            smsChallenge = nil
            smsVerificationError = nil
            pendingRefreshForcesDetailed = false
            if rows.isEmpty {
                state = .failed(message)
            }
            alert = AppAlert(title: "验证已失效", message: message)
        } catch {
            if isCancellation(error) {
                state = rows.isEmpty ? .idle : .loaded
                return
            }
            smsVerificationError = error.localizedDescription
        }
    }

    /// 使用同一个认证会话先获取简略列表；详细缓存满足复用条件时沿用缓存，其余情况获取详细字段。
    ///
    /// 简略结果到达后立即更新页面；缓存满足复用条件时沿用缓存，详细信息需要更新时再发起请求。
    /// 详细请求的状态文案至少展示半秒。
    private func synchronizeScores(
        authenticatedBy challenge: BITLoginAuthenticationChallenge,
        forceDetailedRefresh: Bool
    ) async throws {
        let cachedRows = ScoreCacheStore.loadRows()
        let briefRows = try await service.fetchScores(detail: false, authenticatedBy: challenge)
        applyRows(briefRows)
        syncStatusText = "简略成绩同步完成"

        let detailDecision: ScoreDetailRefreshDecision = forceDetailedRefresh
            ? .fetch
            : ScoreDetailRefreshPolicy.decision(
                briefRows: briefRows,
                cachedRows: cachedRows,
                detailedUpdatedAt: ScoreCacheStore.loadDetailedUpdatedAt(),
                now: Date()
            )
        if detailDecision != .fetch, let cachedRows {
            applyRows(cachedRows)
            ScoreCacheStore.markChecked()
            lastUpdatedAt = ScoreCacheStore.loadUpdatedAt()
            syncStatusText = "成绩已是最新"
            return
        }

        async let detailedRowsRequest = service.fetchScores(
            detail: true,
            authenticatedBy: challenge
        )
        try await Task.sleep(for: .milliseconds(500))

        syncStatusText = "同步详细信息中"
        do {
            let detailedRows = try await detailedRowsRequest
            applyRows(detailedRows)
            ScoreCacheStore.saveDetailed(rows: detailedRows)
            lastUpdatedAt = ScoreCacheStore.loadUpdatedAt()
        } catch {
            if let cachedRows,
               ScoreDetailRefreshPolicy.briefRowsMatchCache(briefRows, cachedRows: cachedRows)
            {
                // 简略成绩保持一致时，详细刷新失败会继续使用缓存中的完整字段。
                applyRows(cachedRows)
            } else {
                ScoreCacheStore.save(rows: briefRows)
            }
            lastUpdatedAt = ScoreCacheStore.loadUpdatedAt()
            throw error
        }
    }

    /// 用户关闭验证码面板后释放内存中的短期令牌，服务端清理过期挑战。
    func dismissSMSChallenge() {
        guard !isSubmittingSMSCode else { return }
        smsChallenge = nil
        smsVerificationError = nil
        pendingRefreshForcesDetailed = false
        if rows.isEmpty {
            state = .failed("需要完成短信验证才能查询成绩。")
        }
    }

    /// 当前筛选条件下实际可见的成绩。
    ///
    /// 成绩列表和统计摘要均基于这份过滤结果，全量 `rows` 作为原始数据源。
    var filteredRows: [ScoreRow] {
        rows.filter { row in
            let matchesTerm = selectedTerms.contains(row.term)
            let matchesType = selectedCourseTypes.contains(row.courseType)
            return matchesTerm && matchesType
        }
    }

    /// 当前筛选与排序条件下实际展示的成绩。
    var visibleRows: [ScoreRow] {
        let rowsForDisplay = filteredRows

        return rowsForDisplay.enumerated()
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
    }

    /// 当前筛选结果对应的统计摘要。
    var summary: ScoreSummary {
        ScoreSummary.make(from: filteredRows)
    }

    /// 根据本机已缓存的同学期课表，估算仍未出分的去重课程数。
    ///
    /// 对应学期缓存缺失时返回 `nil`，页面据此区分未知状态与 0。
    private func calculatePendingCourses() -> [CourseRecord]? {
        let scoreTerms = Set(rows.map(\.term).filter { !$0.isEmpty })
            .intersection(selectedTerms)
        guard !scoreTerms.isEmpty else { return nil }

        let scheduleCache = ScheduleCacheStore.load()
        let coveredTerms = scoreTerms.filter { scheduleCache.cachedCoursesByTerm[$0] != nil }
        guard !coveredTerms.isEmpty else { return nil }

        let scoredNumbers = Set(rows.compactMap { row -> String? in
            let number = normalizedCourseIdentity(row.courseNumber)
            return number.isEmpty ? nil : "\(row.term)|\(number)"
        })
        let scoredNames = Set(rows.compactMap { row -> String? in
            let name = normalizedCourseIdentity(row.courseName)
            return name.isEmpty ? nil : "\(row.term)|\(name)"
        })
        var pendingByIdentity: [String: CourseRecord] = [:]

        for term in coveredTerms {
            for course in scheduleCache.cachedCoursesByTerm[term] ?? [] {
                let number = normalizedCourseIdentity(course.number)
                let name = normalizedCourseIdentity(course.name)
                let hasScore = (!number.isEmpty && scoredNumbers.contains("\(term)|\(number)"))
                    || (!name.isEmpty && scoredNames.contains("\(term)|\(name)"))
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

    /// 当前筛选范围内尚未出分的课程数。
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
    private func restoreCachedRowsIfAvailable() {
        guard !didRestoreCachedRows else { return }
        didRestoreCachedRows = true
        guard let rows = ScoreCacheStore.loadRows(), !rows.isEmpty else { return }
        lastUpdatedAt = ScoreCacheStore.loadUpdatedAt()
        applyRows(rows)
    }

    /// iCloud 成绩缓存到达时立即刷新当前页面，页面继续使用本地缓存数据。
    private func applySyncedScoreCacheIfAvailable() {
        guard let cachedRows = ScoreCacheStore.loadRows(), !cachedRows.isEmpty else { return }
        didRestoreCachedRows = true
        lastUpdatedAt = ScoreCacheStore.loadUpdatedAt()
        applyRows(cachedRows)
    }

    /// 非同步状态下常驻显示的最近更新时间。
    var lastUpdatedText: String {
        guard let lastUpdatedAt else { return "更新时间：暂无记录" }
        return "更新时间：\(lastUpdatedAt.formatted(.dateTime.month().day().hour().minute()))"
    }

    /// 应用一份成绩列表，并同步筛选项。
    private func applyRows(_ newRows: [ScoreRow]) {
        rows = newRows
        availableTerms = uniqueNonEmptyValues(from: newRows.map(\.term))
        availableCourseTypes = uniqueNonEmptyValues(from: newRows.map(\.courseType))
        synchronizeFilters()
        pendingCourses = calculatePendingCourses()
        state = .loaded
    }

    /// 刷新可选项后，同步修正当前筛选集合。
    ///
    /// 首次进入时恢复本地偏好；后续刷新时把当前筛选限制在现有选项范围内。
    private func synchronizeFilters() {
        let termSet = Set(availableTerms)
        let typeSet = Set(availableCourseTypes)

        if !didInitializeTermSelection {
            if let persistedTerms = preferenceSnapshot?.selectedTerms {
                selectedTerms = Set(persistedTerms).intersection(termSet)
            } else {
                selectedTerms = termSet
            }
            didInitializeTermSelection = true
        } else {
            selectedTerms = selectedTerms.intersection(termSet)
        }

        if !didInitializeCourseTypeSelection {
            if let persistedCourseTypes = preferenceSnapshot?.selectedCourseTypes {
                selectedCourseTypes = Set(persistedCourseTypes).intersection(typeSet)
            } else {
                selectedCourseTypes = typeSet
            }
            didInitializeCourseTypeSelection = true
        } else {
            selectedCourseTypes = selectedCourseTypes.intersection(typeSet)
        }

        persistFilterPreferences()
    }

    /// iCloud 拉取完成后立即更新已存在的成绩页面。
    private func applyPersistedFilterPreferences() {
        preferenceSnapshot = ScoreFilterPreferenceStore.load()
        guard let preferenceSnapshot else { return }

        if let raw = preferenceSnapshot.sortIndex, let value = ScoreSortIndex(rawValue: raw) {
            sortIndex = value
        }
        if let raw = preferenceSnapshot.sortOrder, let value = ScoreSortOrder(rawValue: raw) {
            sortOrder = value
        }
        if didInitializeTermSelection {
            selectedTerms = Set(preferenceSnapshot.selectedTerms).intersection(Set(availableTerms))
            pendingCourses = calculatePendingCourses()
        }
        if didInitializeCourseTypeSelection {
            selectedCourseTypes = Set(preferenceSnapshot.selectedCourseTypes).intersection(Set(availableCourseTypes))
        }
    }

    /// 提取去重后的非空字符串列表，并保留原始出现顺序。
    private func uniqueNonEmptyValues(from source: [String]) -> [String] {
        var seen = Set<String>()
        var values: [String] = []
        for item in source {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
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

    /// 保存当前筛选结果到本地偏好。
    private func persistFilterPreferences() {
        guard didInitializeTermSelection, didInitializeCourseTypeSelection else { return }
        ScoreFilterPreferenceStore.save(
            selectedTerms: selectedTerms,
            selectedCourseTypes: selectedCourseTypes,
            sortIndex: sortIndex,
            sortOrder: sortOrder
        )
    }

    /// 同时兼容 Swift Concurrency 和 URLSession 的取消错误。
    private func isCancellation(_ error: Error) -> Bool {
        TaskCancellation.matches(error)
    }
}

/// 可信成绩单申请使用独立于普通成绩查询的状态机。
///
/// 学校返回的图片地址属于短期地址，成绩单图片保存范围为当前申请页面的内存状态。
/// 成绩缓存和图片缓存保存各自数据。
@MainActor
final class TrustedTranscriptViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var images: [UIImage] = []
    @Published private(set) var smsChallenge: BITLoginAuthenticationChallenge?
    @Published private(set) var smsVerificationError: String?
    @Published private(set) var isSubmittingSMSCode = false

    private let service: any TrustedTranscriptServicing

    init(service: any TrustedTranscriptServicing) {
        self.service = service
    }

    convenience init() {
        self.init(service: ScoreService())
    }

    /// 发起一次新的学校可信成绩单申请。
    func apply() async {
        guard state != .loading, !isSubmittingSMSCode, smsChallenge == nil else { return }
        images = []
        smsVerificationError = nil
        state = .loading

        do {
            let pages = try await service.fetchTrustedTranscriptPages()
            try loadImages(from: pages)
        } catch ScoreServiceError.secondFactorRequired(let challenge) {
            smsChallenge = challenge
            state = .idle
        } catch ScoreServiceError.challengeInvalid(let message) {
            smsChallenge = nil
            state = .failed(message)
        } catch {
            if TaskCancellation.matches(error) {
                state = .idle
                return
            }
            state = .failed(error.localizedDescription)
        }
    }

    /// 提交 `jwb_cjd` 独立 challenge 的验证码，并继续下载成绩单图片。
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
            let pages = try await service.submitTranscriptSMSCode(normalizedCode, for: challenge)
            smsChallenge = nil
            state = .loading
            try loadImages(from: pages)
        } catch ScoreServiceError.challengeInvalid(let message) {
            smsChallenge = nil
            state = .failed(message)
        } catch ScoreServiceError.secondFactorRequired(let challenge) {
            smsChallenge = challenge
            state = .idle
            smsVerificationError = "请输入最新收到的短信验证码。"
        } catch {
            // 普通错误（尤其是错误验证码）继续显示在输入面板，用户可以修改验证码后重试。
            if TaskCancellation.matches(error) {
                state = .idle
                return
            }
            smsVerificationError = error.localizedDescription
        }
    }

    /// 关闭短信验证面板并将申请状态更新为失败。
    func dismissSMSChallenge() {
        guard !isSubmittingSMSCode else { return }
        smsChallenge = nil
        smsVerificationError = nil
        state = .failed("已取消短信验证，未申请可信成绩单。")
    }

    private func loadImages(from pages: [Data]) throws {
        let downloadedImages = pages.compactMap(UIImage.init(data:))
        guard downloadedImages.count == pages.count, !downloadedImages.isEmpty else {
            throw ScoreServiceError.queryFailed("学校返回的成绩单图片无法识别，请重新申请。")
        }
        images = downloadedImages
        state = .loaded
    }
}
