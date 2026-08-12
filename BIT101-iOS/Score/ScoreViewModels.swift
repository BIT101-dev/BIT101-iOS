import Combine
import Foundation
import UIKit

/// 查询完整成绩，并负责缓存恢复、筛选同步、统计汇总以及错误提示。
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
    /// 是否正在后台同步基础成绩列表。
    @Published private(set) var isSyncing = false
    /// 复用现有同步提示区域展示两阶段查询进度，不额外弹窗打扰用户。
    @Published private(set) var syncStatusText = "同步中"
    /// 最近一次成功写入成绩缓存的时间；失败刷新不会改动它。
    @Published private(set) var lastUpdatedAt: Date?
    /// 已缓存课表可确认的未出分课程；缺少同学期课表时为 nil。
    @Published private(set) var pendingCourses: [CourseRecord]?
    /// 当前等待用户输入短信验证码的短期认证挑战。
    @Published private(set) var smsChallenge: BITLoginAuthenticationChallenge?
    /// 短信验证码提交过程的行内错误提示。
    @Published private(set) var smsVerificationError: String?
    @Published private(set) var isSubmittingSMSCode = false
    @Published var alert: AppAlert?

    private let service: any ScoreListServicing
    private let scheduleService: (any ScheduleServicing)?
    private var isRefreshing = false
    private var didRestoreCachedRows = false
    private var didInitializeTermSelection = false
    private var didInitializeCourseTypeSelection = false
    /// 补齐成绩所涉及学期课表的静默任务；重复刷新不会再启动第二份。
    private var scheduleCacheTask: Task<Void, Never>?
    /// 启动时读取一次已持久化的筛选快照。
    private let preferenceSnapshot = ScoreFilterPreferenceStore.load()

    init(
        service: any ScoreListServicing,
        scheduleService: (any ScheduleServicing)? = nil
    ) {
        self.service = service
        self.scheduleService = scheduleService
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
    }

    convenience init() {
        self.init(service: ScoreService(), scheduleService: ScheduleService())
    }

    /// 切换账号后丢弃内存态；磁盘缓存仍按新学号在下一次启动时恢复。
    func resetForCurrentAccount() {
        scheduleCacheTask?.cancel()
        scheduleCacheTask = nil
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
        alert = nil
    }

    /// 首次进入成绩页时触发一次查询。
    ///
    /// 如果本机已有成绩缓存，先立即恢复缓存，再后台刷新完整成绩列表。
    func bootstrapIfNeeded() async {
        guard state == .idle else { return }
        restoreCachedRowsIfAvailable()
        await refresh(showErrors: false)
    }

    /// 刷新成绩列表。
    ///
    /// 若页面已经有内容，则走非破坏性刷新，避免下拉刷新时先把列表清空。
    func refresh(showErrors: Bool = true) async {
        guard !isRefreshing, !isSubmittingSMSCode, smsChallenge == nil else { return }

        let hadContent = !rows.isEmpty || state == .loaded
        smsChallenge = nil
        smsVerificationError = nil
        isRefreshing = true
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
            try await synchronizeScores(authenticatedBy: challenge)
        } catch ScoreServiceError.secondFactorRequired(let challenge) {
            smsChallenge = challenge
            state = hadContent ? .loaded : .loading
        } catch ScoreServiceError.challengeInvalid(let message) {
            smsChallenge = nil
            smsVerificationError = nil
            if hadContent || !rows.isEmpty {
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

            if hadContent || !rows.isEmpty {
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
            try await synchronizeScores(authenticatedBy: authenticatedChallenge)
        } catch ScoreServiceError.challengeInvalid(let message) {
            smsChallenge = nil
            smsVerificationError = nil
            if rows.isEmpty {
                state = .failed(message)
            }
            alert = AppAlert(title: "验证已失效", message: message)
        } catch {
            smsVerificationError = error.localizedDescription
        }
    }

    /// 用同一个认证会话先取简略列表，再补充排名、均分等详细字段。
    ///
    /// 简略结果到达后立即驱动页面并启动详细查询；“简略成绩同步完成”文案至少展示半秒，
    /// 但这段展示时间不会阻塞网络请求。
    private func synchronizeScores(
        authenticatedBy challenge: BITLoginAuthenticationChallenge
    ) async throws {
        let briefRows = try await service.fetchScores(detail: false, authenticatedBy: challenge)
        applyRows(briefRows)
        startMissingScheduleCacheRefresh(for: briefRows)
        syncStatusText = "简略成绩同步完成"
        async let detailedRowsRequest = service.fetchScores(
            detail: true,
            authenticatedBy: challenge
        )
        try await Task.sleep(for: .milliseconds(500))

        syncStatusText = "同步详细信息中"
        do {
            let detailedRows = try await detailedRowsRequest
            applyRows(detailedRows)
            ScoreCacheStore.save(rows: detailedRows)
            lastUpdatedAt = ScoreCacheStore.loadUpdatedAt()
        } catch {
            // 简略成绩已经可用时不回滚为空；把简略结果缓存下来，下一次仍可秒开。
            ScoreCacheStore.save(rows: briefRows)
            lastUpdatedAt = ScoreCacheStore.loadUpdatedAt()
            throw error
        }
    }

    /// 对成绩中出现、但本机尚未缓存课表的学期做一次静默补齐。
    ///
    /// 该任务与详细成绩查询并行；失败或需要短信验证时不弹窗，也不会影响成绩列表。
    private func startMissingScheduleCacheRefresh(for scoreRows: [ScoreRow]) {
        guard let scheduleService else { return }
        guard scheduleCacheTask == nil else { return }
        let terms = Set(scoreRows.map(\.term).filter { !$0.isEmpty })
        let existingTerms = Set(ScheduleCacheStore.load().cachedCoursesByTerm.keys)
        let missingTerms = terms.subtracting(existingTerms).sorted {
            $0.localizedStandardCompare($1) == .orderedDescending
        }
        guard !missingTerms.isEmpty else { return }

        scheduleCacheTask = Task { [weak self] in
            guard let self else { return }
            defer { scheduleCacheTask = nil }
            var fetchedCoursesByTerm: [String: [CourseRecord]] = [:]

            for term in missingTerms {
                guard !Task.isCancelled else { return }
                do {
                    let payload = try await scheduleService.syncCourses(term: term)
                    fetchedCoursesByTerm[payload.term] = payload.courses
                } catch ScheduleServiceError.secondFactorRequired(_) {
                    // 认证服务可能发送短信；停止后续学期，避免一次静默任务重复触发验证码。
                    break
                } catch {
                    // 后台补齐只用于辅助提示；任何认证或网络错误都留待用户在课表页主动处理。
                    continue
                }
            }

            if !fetchedCoursesByTerm.isEmpty {
                // 网络等待期间用户可能修改课表；保存前重读最新快照，只合并学期缓存。
                var latestCache = ScheduleCacheStore.load()
                latestCache.cachedCoursesByTerm.merge(fetchedCoursesByTerm) { _, fetched in fetched }
                ScheduleCacheStore.save(latestCache, source: .localWithoutCloudPush)
                pendingCourses = calculatePendingCourses()
            }
        }
    }

    /// 用户关闭验证码面板后丢弃内存中的短期令牌；服务端会自行清理过期挑战。
    func dismissSMSChallenge() {
        guard !isSubmittingSMSCode else { return }
        smsChallenge = nil
        smsVerificationError = nil
        if rows.isEmpty {
            state = .failed("需要完成短信验证才能查询成绩。")
        }
    }

    /// 当前筛选条件下实际可见的成绩。
    ///
    /// 成绩列表和统计摘要都基于这份过滤结果，而不是直接基于全量 `rows`。
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
    /// 没有对应学期缓存时返回 `nil`，避免把“不知道”误显示成 0。
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

                let identity = !number.isEmpty ? "\(term)|n|\(number)" : "\(term)|t|\(name)"
                if !name.isEmpty || !number.isEmpty {
                    pendingByIdentity[identity] = pendingByIdentity[identity] ?? course
                }
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
        return "\(sortIndex.title) · \(sortOrder.title)"
    }

    /// 替换学期筛选结果，并自动剔除已不存在的选项。
    func setSelectedTerms(_ values: Set<String>) {
        selectedTerms = values.intersection(Set(availableTerms))
        pendingCourses = calculatePendingCourses()
        persistFilterPreferences()
    }

    /// 替换课程性质筛选结果，并自动剔除已不存在的选项。
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
    /// 首次进入时优先恢复本地偏好；后续刷新时则只做求交集，剔除已经不存在的旧选项。
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

    /// 把当前筛选结果写回本地偏好。
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

/// 可信成绩单申请使用与普通成绩查询相互独立的状态机。
///
/// 学校返回的图片地址是短期地址，图片也只保留在内存中；退出页面后不会写入成绩缓存或图片缓存。
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
            if error is CancellationError { return }
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
        } catch {
            // 普通错误（尤其是错误验证码）留在输入面板内展示，允许用户直接改正后重试。
            smsVerificationError = error.localizedDescription
        }
    }

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

/// “成绩”底部页内部的一级内容分区。
///
/// 课程模块并入后，底部栏只保留“成绩”一个入口，
/// 再通过这里的顶部栏在“成绩 / 课程”之间切换。
