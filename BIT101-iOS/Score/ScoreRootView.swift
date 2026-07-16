import Combine
import SwiftUI

/// 统一生成“左右轻扫切换分区”的横向手势。
///
/// 与话题页保持同一套判断条件：
/// - 横向位移大于纵向位移
/// - 横向位移达到最小触发阈值
/// - 左滑记作 `+1`，右滑记作 `-1`
private func makeHorizontalSwitchGesture(onStep: @escaping (Int) -> Void) -> some Gesture {
    DragGesture(minimumDistance: 24, coordinateSpace: .local)
        .onEnded { value in
            let horizontal = value.translation.width
            let vertical = value.translation.height

            guard abs(horizontal) > abs(vertical), abs(horizontal) >= 56 else { return }
            onStep(horizontal < 0 ? 1 : -1)
        }
}

/// 成绩页本地筛选偏好快照。
///
/// 按账号保存上一次的学期、课程性质筛选与排序偏好，避免每次重进页面都重新配置。
private struct ScoreFilterPreferenceSnapshot: Codable {
    var selectedTerms: [String] = []
    var selectedCourseTypes: [String] = []
    var sortIndex: String?
    var sortOrder: String?
}

/// 成绩筛选偏好的本地仓库。
private enum ScoreFilterPreferenceStore {
    private static let keyPrefix = "score.filter.preferences"

    static func load() -> ScoreFilterPreferenceSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(ScoreFilterPreferenceSnapshot.self, from: data)
    }

    static func save(
        selectedTerms: Set<String>,
        selectedCourseTypes: Set<String>,
        sortIndex: ScoreSortIndex,
        sortOrder: ScoreSortOrder
    ) {
        let snapshot = ScoreFilterPreferenceSnapshot(
            selectedTerms: Array(selectedTerms),
            selectedCourseTypes: Array(selectedCourseTypes),
            sortIndex: sortIndex.rawValue,
            sortOrder: sortOrder.rawValue
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private static var storageKey: String {
        let studentID = LoginStorage.shared.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = studentID.isEmpty ? "guest" : studentID
        return "\(keyPrefix).\(suffix)"
    }
}

/// 成绩列表支持的排序索引。
private enum ScoreSortIndex: String, CaseIterable, Identifiable {
    case courseName
    case score
    case averageScore
    case credit
    case term
    case courseType

    var id: String { rawValue }

    var title: String {
        switch self {
        case .courseName:
            return "名称"
        case .score:
            return "成绩"
        case .averageScore:
            return "均分"
        case .credit:
            return "学分"
        case .term:
            return "学期"
        case .courseType:
            return "种类"
        }
    }

    /// 当前索引对应字段是否为空。空字段统一排到最后，避免缺失值在降序时顶到列表最前。
    func isMissingValue(in row: ScoreRow) -> Bool {
        switch self {
        case .courseName:
            return normalizedText(row.courseName).isEmpty
        case .score:
            return scoreComparableValue(from: row.score) == nil
        case .averageScore:
            return numericComparableValue(from: row.averageScore) == nil
        case .credit:
            return numericComparableValue(from: row.creditText) == nil
        case .term:
            return normalizedText(row.term).isEmpty
        case .courseType:
            return normalizedText(row.courseType).isEmpty
        }
    }

    /// 比较两条成绩在当前排序索引上的值。
    func compare(_ lhs: ScoreRow, _ rhs: ScoreRow) -> ComparisonResult {
        switch self {
        case .courseName:
            return normalizedText(lhs.courseName).localizedStandardCompare(normalizedText(rhs.courseName))
        case .score:
            return compareNumbers(scoreComparableValue(from: lhs.score), scoreComparableValue(from: rhs.score))
        case .averageScore:
            return compareNumbers(numericComparableValue(from: lhs.averageScore), numericComparableValue(from: rhs.averageScore))
        case .credit:
            return compareNumbers(numericComparableValue(from: lhs.creditText), numericComparableValue(from: rhs.creditText))
        case .term:
            return normalizedText(lhs.term).localizedStandardCompare(normalizedText(rhs.term))
        case .courseType:
            return normalizedText(lhs.courseType).localizedStandardCompare(normalizedText(rhs.courseType))
        }
    }

    private func normalizedText(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func numericComparableValue(from raw: String) -> Double? {
        let trimmed = normalizedText(raw)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }

    private func scoreComparableValue(from raw: String) -> Double? {
        let trimmed = normalizedText(raw)
        guard !trimmed.isEmpty else { return nil }

        switch trimmed {
        case "优秀":
            return 95
        case "良好":
            return 85
        case "中等":
            return 75
        case "及格":
            return 65
        case "不及格":
            return 0
        default:
            return Double(trimmed)
        }
    }

    private func compareNumbers(_ lhs: Double?, _ rhs: Double?) -> ComparisonResult {
        guard let lhs, let rhs else { return .orderedSame }
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}

/// 成绩列表排序方向。
private enum ScoreSortOrder: String, CaseIterable, Identifiable {
    case ascending
    case descending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ascending:
            return "升序"
        case .descending:
            return "降序"
        }
    }

    var systemImage: String {
        switch self {
        case .ascending:
            return "arrow.up"
        case .descending:
            return "arrow.down"
        }
    }

    var toggled: ScoreSortOrder {
        switch self {
        case .ascending:
            return .descending
        case .descending:
            return .ascending
        }
    }
}

/// 原生成绩页状态机。
///
/// 固定以复杂模式查询成绩，并负责筛选同步、统计汇总以及错误提示。
@MainActor
private final class ScoreViewModel: ObservableObject {
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
    /// 是否正在后台同步完整成绩。
    @Published private(set) var isSyncing = false
    /// 当前等待用户输入短信验证码的短期认证挑战。
    @Published private(set) var smsChallenge: BITLoginAuthenticationChallenge?
    /// 短信验证码提交过程的行内错误提示。
    @Published private(set) var smsVerificationError: String?
    @Published private(set) var isSubmittingSMSCode = false
    @Published var alert: LoginAlert?

    private let service: ScoreService
    private var isRefreshing = false
    private var didRestoreCachedRows = false
    private var didInitializeTermSelection = false
    private var didInitializeCourseTypeSelection = false
    /// 启动时读取一次已持久化的筛选快照。
    private let preferenceSnapshot = ScoreFilterPreferenceStore.load()

    init(service: ScoreService) {
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
    /// 如果本机已有完整成绩缓存，先立即恢复缓存，再后台刷新同样的 `detail=true` 完整数据。
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
            // 列表刷新只取基础成绩，避免服务端逐门抓取排名详情导致长时间阻塞或超时。
            let fetchedRows = try await service.fetchScores(detail: false)
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
                alert = LoginAlert(title: "验证已失效", message: message)
            } else {
                state = .failed(message)
                alert = LoginAlert(title: "验证已失效", message: message)
            }
        } catch {
            if isCancellation(error) {
                state = hadContent ? .loaded : .idle
                return
            }

            if hadContent {
                state = .loaded
                alert = LoginAlert(title: "成绩刷新失败", message: error.localizedDescription)
                return
            }

            rows = []
            availableTerms = []
            availableCourseTypes = []
            selectedTerms = []
            selectedCourseTypes = []
            state = .failed(error.localizedDescription)
            alert = LoginAlert(title: "成绩查询失败", message: error.localizedDescription)
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
                detail: false
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
            alert = LoginAlert(title: "验证已失效", message: message)
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

    /// 恢复本机缓存的完整成绩结果。
    private func restoreCachedRowsIfAvailable() {
        guard !didRestoreCachedRows else { return }
        didRestoreCachedRows = true
        guard let rows = ScoreCacheStore.loadRows(), !rows.isEmpty else { return }
        applyRows(rows)
    }

    /// 应用一份完整成绩结果，并同步筛选项。
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
        if error is CancellationError {
            return true
        }

        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}

/// “成绩”底部页内部的一级内容分区。
///
/// 课程模块并入后，底部栏只保留“成绩”一个入口，
/// 再通过这里的顶部栏在“成绩 / 课程”之间切换。
private enum ScoreSurface: String, CaseIterable, Identifiable {
    case score
    case course

    var id: String { rawValue }

    var title: String {
        switch self {
        case .score:
            return "成绩"
        case .course:
            return "课程"
        }
    }
}

/// 原生成绩查询主页。
///
/// 负责承载“成绩 / 课程”的顶部切换。
struct ScoreRootView: View {
    @StateObject private var scoreViewModel = ScoreViewModel()
    @StateObject private var courseViewModel = CourseListViewModel()
    @State private var selectedSurface: ScoreSurface = .score

    var body: some View {
        ZStack {
            switch selectedSurface {
            case .score:
                ScoreListPage(viewModel: scoreViewModel)
                    .simultaneousGesture(surfaceSwitchGesture)
                    .transition(.opacity)
            case .course:
                CoursePageContent(viewModel: courseViewModel)
                    .simultaneousGesture(surfaceSwitchGesture)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selectedSurface)
        .safeAreaInset(edge: .top) {
            Picker("成绩内容", selection: surfaceSelection) {
                ForEach(ScoreSurface.allCases) { surface in
                    Text(surface.title).tag(surface)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .background(Color(.systemGroupedBackground))
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    /// 顶部 segmented 的受控绑定。
    ///
    /// 统一把点击切换和滑动切换都收束到同一条动画路径里。
    private var surfaceSelection: Binding<ScoreSurface> {
        Binding(
            get: { selectedSurface },
            set: { newSurface in
                switchSurface(to: newSurface)
            }
        )
    }

    /// 当前页的左右轻扫切换手势。
    private var surfaceSwitchGesture: some Gesture {
        makeHorizontalSwitchGesture(onStep: switchSurface)
    }

    /// 把当前分区切到相邻页。
    private func switchSurface(step: Int) {
        let allSurfaces = ScoreSurface.allCases
        guard let currentIndex = allSurfaces.firstIndex(of: selectedSurface) else { return }

        let nextIndex = currentIndex + step
        guard allSurfaces.indices.contains(nextIndex) else { return }

        switchSurface(to: allSurfaces[nextIndex])
    }

    /// 切换到指定分区，并统一施加渐变动画。
    private func switchSurface(to surface: ScoreSurface) {
        guard surface != selectedSurface else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            selectedSurface = surface
        }
    }
}

/// 成绩列表子页。
///
/// 保留原有“筛选 -> 统计 -> 列表”结构，只是被合并页托管。
private struct ScoreListPage: View {
    @ObservedObject var viewModel: ScoreViewModel

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle, .loading:
                ProgressView("正在查询成绩")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground))
            case let .failed(message):
                ContentUnavailableView {
                    Label("加载失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("重新查询") {
                        Task { await viewModel.refresh() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
            case .loaded:
                List {
                    if viewModel.isSyncing {
                        Section {
                            Text("同步中")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        NavigationLink {
                            ScoreFilterPage(
                                title: "学期筛选",
                                options: viewModel.availableTerms,
                                selectedValues: Binding(
                                    get: { viewModel.selectedTerms },
                                    set: { viewModel.setSelectedTerms($0) }
                                ),
                                onToggleAll: viewModel.toggleAllTerms
                            )
                        } label: {
                            LabeledContent("学期", value: selectionDescription(selected: viewModel.selectedTerms, all: viewModel.availableTerms))
                        }

                        NavigationLink {
                            ScoreFilterPage(
                                title: "种类筛选",
                                options: viewModel.availableCourseTypes,
                                selectedValues: Binding(
                                    get: { viewModel.selectedCourseTypes },
                                    set: { viewModel.setSelectedCourseTypes($0) }
                                ),
                                onToggleAll: viewModel.toggleAllCourseTypes
                            )
                        } label: {
                            LabeledContent("种类", value: selectionDescription(selected: viewModel.selectedCourseTypes, all: viewModel.availableCourseTypes))
                        }

                        NavigationLink {
                            ScoreSortPage(
                                sortIndex: Binding(
                                    get: { viewModel.sortIndex },
                                    set: { viewModel.setSortIndex($0) }
                                ),
                                sortOrder: Binding(
                                    get: { viewModel.sortOrder },
                                    set: { viewModel.setSortOrder($0) }
                                ),
                                onToggleOrder: viewModel.toggleSortOrder
                            )
                        } label: {
                            LabeledContent("排序", value: viewModel.sortDescription)
                        }
                    }

                    Section("统计") {
                        ScoreSummaryRow(title: "课程数", value: "\(viewModel.summary.selectedCourseCount)")
                        ScoreSummaryRow(title: "总学分", value: format(decimal: viewModel.summary.totalCredit))
                        ScoreSummaryRow(title: "加权平均分", value: format(optionalDecimal: viewModel.summary.weightedAverageScore))
                        ScoreSummaryRow(title: "加权 GPA", value: format(optionalDecimal: viewModel.summary.weightedAverageGPA))
                    }

                    Section("成绩列表") {
                        if viewModel.visibleRows.isEmpty {
                            ContentUnavailableView(
                                "暂无成绩",
                                systemImage: "chart.bar.doc.horizontal",
                                description: Text("请调整学期或种类筛选条件。")
                            )
                            .frame(maxWidth: .infinity)
                        } else {
                            ForEach(viewModel.visibleRows) { row in
                                NavigationLink {
                                    ScoreDetailView(row: row)
                                } label: {
                                    ScoreRowCard(row: row)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .background(Color(.systemGroupedBackground))
                .refreshable {
                    await viewModel.refresh()
                }
            }
        }
        .task {
            await viewModel.bootstrapIfNeeded()
        }
        .alert(item: $viewModel.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("知道了")))
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
            ScoreSMSVerificationSheet(
                challenge: challenge,
                isSubmitting: viewModel.isSubmittingSMSCode,
                errorMessage: viewModel.smsVerificationError,
                onCancel: viewModel.dismissSMSChallenge,
                onSubmit: { code in
                    await viewModel.submitSMSCode(code)
                }
            )
        }
    }

    /// 统一格式化可选小数，没有值时显示占位符。
    private func format(optionalDecimal value: Double?) -> String {
        guard let value else { return "-" }
        return format(decimal: value)
    }

    /// 统一格式化成绩统计里的数值。
    private func format(decimal value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }

    /// 根据当前筛选状态生成一行摘要文本。
    private func selectionDescription(selected: Set<String>, all: [String]) -> String {
        guard !all.isEmpty else { return "-" }
        if selected.count == all.count {
            return "全部"
        }
        if selected.isEmpty {
            return "未选择"
        }
        let ordered = all.filter { selected.contains($0) }
        if ordered.count <= 2 {
            return ordered.joined(separator: "、")
        }
        return "\(ordered.prefix(2).joined(separator: "、")) 等 \(ordered.count) 项"
    }
}

/// 成绩页的原生短信验证码面板。
///
/// `.textContentType(.oneTimeCode)` 会让 iOS 从“来自信息”的验证码建议中自动填入，
/// 同时保留数字键盘供用户手动输入。
private struct ScoreSMSVerificationSheet: View {
    let challenge: BITLoginAuthenticationChallenge
    let isSubmitting: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onSubmit: (String) async -> Void

    @State private var code = ""
    @FocusState private var isCodeFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("短信验证码", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .multilineTextAlignment(.center)
                        .font(.title2.monospacedDigit())
                        .focused($isCodeFieldFocused)
                        .disabled(isSubmitting)
                        .onChange(of: code) { _, newValue in
                            let digits = String(newValue.filter(\.isNumber).prefix(8))
                            if digits != newValue {
                                code = digits
                            }
                        }
                } header: {
                    Text("输入验证码")
                } footer: {
                    Text(verificationHint)
                }

                if let errorMessage, !errorMessage.isEmpty {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await onSubmit(code) }
                    } label: {
                        HStack {
                            Spacer()
                            if isSubmitting {
                                ProgressView()
                                    .padding(.trailing, 6)
                                Text("正在验证")
                            } else {
                                Text("验证并查询成绩")
                            }
                            Spacer()
                        }
                    }
                    .disabled(isSubmitting || !(4 ... 8).contains(code.count))
                }
            }
            .navigationTitle("短信验证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                        .disabled(isSubmitting)
                }
            }
            .interactiveDismissDisabled(isSubmitting)
            .onAppear {
                isCodeFieldFocused = true
            }
        }
        .presentationDetents([.medium])
    }

    private var verificationHint: String {
        if let maskedPhone = challenge.maskedPhone, !maskedPhone.isEmpty {
            return "验证码已发送至绑定手机 \(maskedPhone)，可点击键盘上方建议自动填充。"
        }
        return "验证码已发送至绑定手机，可点击键盘上方建议自动填充。"
    }
}

/// 统计区单行展示。
///
/// 只是一个轻量包装，让统计 section 的几行 `LabeledContent` 看起来更统一。
private struct ScoreSummaryRow: View {
    let title: String
    let value: String

    /// 统计项的单行展示。
    var body: some View {
        LabeledContent(title, value: value)
    }
}

/// 成绩卡片。
///
/// 列表页使用更紧凑的两行布局，详情页再看完整字段。
private struct ScoreRowCard: View {
    let row: ScoreRow

    /// 列表态成绩卡片的紧凑布局。
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScoreFixedColumnRow(
                items: [
                    ScoreFixedColumnItem(
                        text: row.courseName.isEmpty ? "未命名课程" : row.courseName,
                        ratio: 0.55,
                        font: .headline,
                        color: .primary,
                    ),
                    ScoreFixedColumnItem(
                        text: formattedCredit,
                        ratio: 0.15,
                        font: .caption,
                        color: .secondary,
                    ),
                    ScoreFixedColumnItem(
                        text: row.term.isEmpty ? "-" : row.term,
                        ratio: 0.3,
                        font: .caption,
                        color: .secondary,
                        alignment: .trailing
                    ),
                ],
                height: 22
            )

            ScoreFixedColumnRow(
                items: [
                    ScoreFixedColumnItem(
                        text: "成绩 \(row.score.isEmpty ? "-" : row.score)",
                        ratio: 0.25,
                        font: .subheadline.weight(.semibold),
                        color: .primary
                    ),
                    ScoreFixedColumnItem(
                        text: "均分 \(formattedAverageScore)",
                        ratio: 0.45,
                        font: .subheadline.weight(.semibold),
                        color: .primary,
                    ),
                    ScoreFixedColumnItem(
                        text: row.courseType.isEmpty ? "-" : row.courseType,
                        ratio: 0.3,
                        font: .caption,
                        color: .secondary,
                        alignment: .trailing
                    ),
                ],
                height: 20
            )
        }
        .padding(.vertical, 4)
    }

    /// 学分字段在列表里的展示格式。
    private var formattedCredit: String {
        let trimmed = row.creditText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "-" }
        return "\(trimmed)分"
    }

    /// 均分字段统一保留两位小数。
    private var formattedAverageScore: String {
        let trimmed = row.averageScore.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "-" }
        guard let value = Double(trimmed) else { return trimmed }
        return value.formatted(.number.precision(.fractionLength(2)))
    }
}

/// 成绩详情页。
///
/// 由列表直接 push 进入，使用平铺信息流替代旧的抽屉式详情。
private struct ScoreDetailView: View {
    let row: ScoreRow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summarySection
                Divider()
                detailSection
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("成绩详情")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(row.courseName.isEmpty ? "未命名课程" : row.courseName)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 18) {
                Text("成绩 \(row.score.isEmpty ? "-" : row.score)")
                Text("均分 \(formattedAverageScore)")
                Text(formattedCredit)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ScoreDetailMetaRow(title: "课程号", value: row.courseNumber)
                ScoreDetailMetaRow(title: "学期", value: row.term)
                ScoreDetailMetaRow(title: "课程性质", value: row.courseType)
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var detailSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("详细信息")
                .font(.headline)

            if remainingFields.isEmpty {
                Text("暂无更多信息")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(remainingFields.enumerated()), id: \.offset) { index, field in
                        VStack(spacing: 0) {
                            ScoreDetailFieldRow(field: field)

                            if index != remainingFields.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private var remainingFields: [ScoreField] {
        let hiddenKeys: Set<String> = ["课程名称", "成绩", "平均分", "学分", "课程编号", "开课学期", "课程性质"]
        return row.values.filter { field in
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && !hiddenKeys.contains(field.key)
        }
    }

    private var formattedCredit: String {
        let trimmed = row.creditText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "学分 -" }
        return "学分 \(trimmed)"
    }

    private var formattedAverageScore: String {
        let trimmed = row.averageScore.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "-" }
        guard let value = Double(trimmed) else { return trimmed }
        return value.formatted(.number.precision(.fractionLength(2)))
    }
}

private struct ScoreDetailMetaRow: View {
    let title: String
    let value: String

    var body: some View {
        LabeledContent(title, value: value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "-" : value)
    }
}

private struct ScoreDetailFieldRow: View {
    let field: ScoreField

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(field.key)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)

            Text(field.value)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
    }
}

/// 成绩卡片里的单列定义。
///
/// 用固定比例列把两行信息对齐，避免不同长度课程名把后面的字段全部挤歪。
private struct ScoreFixedColumnItem {
    let text: String
    let ratio: CGFloat
    let font: Font
    let color: Color
    var alignment: Alignment = .leading
}

/// 按固定比例切分宽度的一行文本。
private struct ScoreFixedColumnRow: View {
    let items: [ScoreFixedColumnItem]
    let height: CGFloat

    /// 按比例切分宽度的一整行内容。
    var body: some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    Text(item.text)
                        .font(item.font)
                        .foregroundStyle(item.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .monospacedDigit()
                        .frame(
                            width: totalWidth * item.ratio,
                            height: height,
                            alignment: item.alignment
                        )
                }
            }
        }
        .frame(height: height)
    }
}

/// 成绩筛选页。
///
/// 支持学期和种类的多选，首次默认全选，之后允许清空成 0 选项。
private struct ScoreFilterPage: View {
    let title: String
    let options: [String]
    @Binding var selectedValues: Set<String>
    let onToggleAll: () -> Void

    /// 通用多选筛选页。
    ///
    /// 学期筛选和种类筛选都复用这一套页面，只靠传入选项和绑定集合区分。
    var body: some View {
        List {
            Section {
                Button(toggleAllTitle) {
                    onToggleAll()
                }
            }

            Section {
                ForEach(options, id: \.self) { option in
                    Button {
                        toggle(option)
                    } label: {
                        HStack {
                            Text(option)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: selectedValues.contains(option) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedValues.contains(option) ? Color.accentColor : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 切换单个选项的勾选状态。
    private func toggle(_ option: String) {
        var next = selectedValues
        if next.contains(option) {
            next.remove(option)
        } else {
            next.insert(option)
        }
        selectedValues = next
    }

    /// 根据当前选择情况自动在“全选 / 全不选”间切换文案。
    private var toggleAllTitle: String {
        selectedValues.count == options.count ? "全不选" : "全选"
    }
}

/// 成绩排序页。
///
/// 排序只影响列表展示顺序，不改变统计口径；缺失排序值的课程会固定排在最后。
private struct ScoreSortPage: View {
    @Binding var sortIndex: ScoreSortIndex
    @Binding var sortOrder: ScoreSortOrder
    let onToggleOrder: () -> Void

    var body: some View {
        List {
            Section("排序索引") {
                ForEach(ScoreSortIndex.allCases) { index in
                    Button {
                        sortIndex = index
                    } label: {
                        HStack {
                            Text(index.title)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: sortIndex == index ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(sortIndex == index ? Color.accentColor : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                Button {
                    onToggleOrder()
                } label: {
                    HStack {
                        Label(sortOrder.title, systemImage: sortOrder.systemImage)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("切换")
                            .font(.subheadline)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            } header: {
                Text("排序方向")
            } footer: {
                Text("升序表示小的在上，降序表示大的在上。")
            }
        }
        .navigationTitle("成绩排序")
        .navigationBarTitleDisplayMode(.inline)
    }
}
