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
    /// 启动时读取一次已持久化的筛选快照。
    private let preferenceSnapshot = ScoreFilterPreferenceStore.load()

    init(service: any ScoreListServicing) {
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
    }

    convenience init() {
        self.init(service: ScoreService())
    }

    /// 首次进入成绩页时触发一次查询。
    ///
    /// 如果本机已有成绩缓存，先立即恢复缓存，再后台刷新完整成绩列表。
    func bootstrapIfNeeded() async {
        guard state == .idle else { return }
        restoreCachedRowsIfAvailable()
        await refresh()
    }

    /// 刷新成绩列表。
    ///
    /// 若页面已经有内容，则走非破坏性刷新，避免下拉刷新时先把列表清空。
    func refresh() async {
        guard !isRefreshing, !isSubmittingSMSCode, smsChallenge == nil else { return }

        let hadContent = !rows.isEmpty || state == .loaded
        smsChallenge = nil
        smsVerificationError = nil
        isRefreshing = true
        isSyncing = true
        if !hadContent {
            state = .loading
        }

        defer {
            isRefreshing = false
            isSyncing = false
        }

        do {
            // 均分、排名和详情字段只在 detail=true 时返回；基础模式只能满足简略列表。
            let fetchedRows = try await service.fetchScores(detail: true)
            applyRows(fetchedRows)
            ScoreCacheStore.save(rows: fetchedRows)
        } catch ScoreServiceError.secondFactorRequired(let challenge) {
            smsChallenge = challenge
            state = hadContent ? .loaded : .loading
        } catch ScoreServiceError.challengeInvalid(let message) {
            smsChallenge = nil
            smsVerificationError = nil
            if hadContent {
                state = .loaded
                alert = AppAlert(title: "验证已失效", message: message)
            } else {
                state = .failed(message)
                alert = AppAlert(title: "验证已失效", message: message)
            }
        } catch {
            if isCancellation(error) {
                state = hadContent ? .loaded : .idle
                return
            }

            if hadContent {
                state = .loaded
                alert = AppAlert(title: "成绩刷新失败", message: error.localizedDescription)
                return
            }

            rows = []
            availableTerms = []
            availableCourseTypes = []
            selectedTerms = []
            selectedCourseTypes = []
            state = .failed(error.localizedDescription)
            alert = AppAlert(title: "成绩查询失败", message: error.localizedDescription)
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
            let fetchedRows = try await service.submitSMSCode(
                normalizedCode,
                for: challenge,
                detail: true
            )
            applyRows(fetchedRows)
            ScoreCacheStore.save(rows: fetchedRows)
            smsChallenge = nil
            state = .loaded
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

    /// 当前排序偏好的人类可读摘要。
    var sortDescription: String {
        return "\(sortIndex.title) · \(sortOrder.title)"
    }

    /// 替换学期筛选结果，并自动剔除已不存在的选项。
    func setSelectedTerms(_ values: Set<String>) {
        selectedTerms = values.intersection(Set(availableTerms))
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
        applyRows(rows)
    }

    /// 应用一份成绩列表，并同步筛选项。
    private func applyRows(_ newRows: [ScoreRow]) {
        rows = newRows
        availableTerms = uniqueNonEmptyValues(from: newRows.map(\.term))
        availableCourseTypes = uniqueNonEmptyValues(from: newRows.map(\.courseType))
        synchronizeFilters()
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
    @Published private(set) var image: UIImage?
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
        image = nil
        smsVerificationError = nil
        state = .loading

        do {
            let url = try await service.fetchTrustedTranscript()
            try await loadImage(from: url)
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
            let url = try await service.submitTranscriptSMSCode(normalizedCode, for: challenge)
            smsChallenge = nil
            state = .loading
            try await loadImage(from: url)
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

    private func loadImage(from url: URL) async throws {
        let data = try await service.downloadTrustedTranscript(from: url)
        guard let downloadedImage = UIImage(data: data) else {
            throw ScoreServiceError.queryFailed("学校返回的成绩单图片无法识别，请重新申请。")
        }
        image = downloadedImage
        state = .loaded
    }
}

/// “成绩”底部页内部的一级内容分区。
///
/// 课程模块并入后，底部栏只保留“成绩”一个入口，
/// 再通过这里的顶部栏在“成绩 / 课程”之间切换。
