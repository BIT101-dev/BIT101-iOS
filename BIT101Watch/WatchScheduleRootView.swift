import SwiftUI

enum WatchScheduleRefreshState: Equatable {
    case idle
    case syncing
    case succeeded
    case failed

    var buttonTitle: String {
        switch self {
        case .syncing:
            return "同步中…"
        default:
            return "重新同步"
        }
    }

    var feedbackText: String? {
        switch self {
        case .succeeded:
            return "已同步"
        case .failed:
            return "同步未完成"
        default:
            return nil
        }
    }
}

/// watch 主页面使用的状态模型。
///
/// 它只关心三件事：
/// - 从共享快照仓库读取当前镜像
/// - 计算下一节课与后续课节
/// - 在需要时向 iPhone 发起一次显式刷新
@MainActor
final class WatchScheduleStatusModel: ObservableObject {
    /// 主页面最多展示的后续课节数量，避免长列表在手表上无限拉长。
    private static let maxVisibleOccurrences = 50
    private static let foregroundRefreshInterval: TimeInterval = 60

    @Published private(set) var snapshot: ScheduleExternalSnapshot?
    @Published private(set) var nextOccurrence: ScheduleExternalOccurrence?
    @Published private(set) var upcomingOccurrences: [ScheduleExternalOccurrence] = []
    @Published private(set) var refreshState: WatchScheduleRefreshState = .idle
    @Published private(set) var referenceDate = Date()

    private var refreshFeedbackTask: Task<Void, Never>?
    private var foregroundRefreshTask: Task<Void, Never>?

    deinit {
        refreshFeedbackTask?.cancel()
        foregroundRefreshTask?.cancel()
    }

    /// 激活同步链路，并尝试立刻拿到最新课表。
    func activate() {
        WatchScheduleSyncManager.shared.activateIfNeeded()
        reload()
        startForegroundRefresh()
        #if os(watchOS)
        WatchScheduleSyncManager.shared.requestLatestSnapshotFromPhone()
        #endif
    }

    /// watch App 从后台回到前台时，本地时间可能已经跨天或跨过上课/下课边界。
    ///
    /// 这里不依赖 iPhone 重新推送；即使手机不在身边，也会基于 watch 本地镜像重新计算
    /// “今天 / 明天”和当前/下一节状态。
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            reload()
            startForegroundRefresh()
        case .inactive, .background:
            stopForegroundRefresh()
        @unknown default:
            break
        }
    }

    /// 仅从本地镜像重载当前页面。
    ///
    /// 这个方法不会主动访问网络；它只消费 iPhone 已经推送过来的共享快照。
    func reload(now: Date = Date()) {
        referenceDate = now
        let resolved = ScheduleOccurrenceResolver.loadResolvedSnapshot(now: now, limit: Self.maxVisibleOccurrences)
        self.snapshot = resolved.snapshot
        self.nextOccurrence = resolved.nextOccurrence
        self.upcomingOccurrences = resolved.upcomingOccurrences
    }

    /// 显式请求手机端重新推送一次最新课表。
    func requestRefresh() {
        refreshFeedbackTask?.cancel()
        refreshState = .syncing
        #if os(watchOS)
        WatchScheduleSyncManager.shared.requestLatestSnapshotFromPhone()
        #endif
        reload()
        refreshFeedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, self.refreshState == .syncing else { return }
            self.refreshState = .failed
            self.scheduleRefreshStateReset()
        }
    }

    func handleSnapshotDidChange() {
        reload()
        guard refreshState == .syncing else { return }
        refreshFeedbackTask?.cancel()
        refreshState = .succeeded
        scheduleRefreshStateReset()
    }

    private func scheduleRefreshStateReset() {
        refreshFeedbackTask?.cancel()
        refreshFeedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self.refreshState = .idle
        }
    }

    private func startForegroundRefresh() {
        guard foregroundRefreshTask == nil else { return }
        foregroundRefreshTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.foregroundRefreshInterval))
                guard !Task.isCancelled else { return }
                self.reload()
            }
        }
    }

    private func stopForegroundRefresh() {
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
    }

    /// 清空 watch 本地已缓存的课表快照。
    func clearLocalData() {
        refreshFeedbackTask?.cancel()
        refreshState = .idle
        referenceDate = Date()
        ScheduleExternalSnapshotStore.clear()
        self.snapshot = nil
        self.nextOccurrence = nil
        self.upcomingOccurrences = []
    }

    var refreshButtonTitle: String {
        refreshState.buttonTitle
    }

    var refreshFeedbackText: String? {
        refreshState.feedbackText
    }

    var isRefreshing: Bool {
        refreshState == .syncing
    }
}

/// watch 主页面。
///
/// 展示顺序保持极简：先给出“当前/下一节”的摘要，再向下列出后续课节，
/// 让用户抬腕后能先看到最关键的信息，继续滚动时再看完整一些的安排。
struct WatchScheduleRootView: View {
    @ObservedObject var model: WatchScheduleStatusModel
    @State private var isShowingClearConfirmation = false

    var body: some View {
        TabView {
            primaryPage
            actionsPage
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        .navigationTitle("课表")
        .onAppear {
            model.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .scheduleExternalSnapshotDidChange)) { _ in
            model.handleSnapshotDidChange()
        }
        .confirmationDialog("清除本地课表数据？", isPresented: $isShowingClearConfirmation, titleVisibility: .visible) {
            Button("清除", role: .destructive) {
                model.clearLocalData()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅清除手表本地缓存，不影响手机端。")
        }
    }

    private var primaryPage: some View {
        ScrollView {
            if let snapshot = model.snapshot, snapshot.isLoggedIn, let next = model.nextOccurrence {
                LazyVStack(alignment: .leading) {
                    VStack(alignment: .leading) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(next.isCurrent(at: model.referenceDate) ? "正在上课" : "下一节")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Spacer(minLength: 0)

                            Text(next.relativeDayText(referenceDate: model.referenceDate))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text(next.title)
                            .font(.title2)
                            .lineLimit(2)

                        Text(next.rangeText)
                            .font(.title2)

                        if !next.classroom.isEmpty {
                            Text(next.classroom)
                                .font(.title2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    if model.upcomingOccurrences.count > 1 {
                        Divider()
                            .padding(.vertical, 2)

                        Text("后续课节")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(Array(model.upcomingOccurrences.dropFirst())) { occurrence in
                            VStack(alignment: .leading) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(occurrence.relativeDayText(referenceDate: model.referenceDate))
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.secondary)

                                    Spacer(minLength: 4)

                                    Text(occurrence.rangeText)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.secondary)
                                }

                                Text(occurrence.title)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(2)

                                if !occurrence.classroom.isEmpty {
                                    Text(occurrence.classroom)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let snapshot = model.snapshot, !snapshot.isLoggedIn {
                WatchScheduleEmptyStateView(message: "请先在手机上登录")
            } else if model.snapshot != nil {
                WatchScheduleEmptyStateView(message: "今天没课啦")
            } else {
                WatchScheduleEmptyStateView(
                    message: "打开手机 App 同步课表",
                    actionTitle: model.refreshButtonTitle,
                    feedbackText: model.refreshFeedbackText,
                    isActionDisabled: model.isRefreshing,
                    action: {
                        model.requestRefresh()
                    }
                )
            }
        }
    }

    private var actionsPage: some View {
        VStack(spacing: 10) {
            Text("操作")
                .font(.headline)

            Button(model.refreshButtonTitle) {
                model.requestRefresh()
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isRefreshing)

            if let feedbackText = model.refreshFeedbackText {
                Text(feedbackText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("清除数据", role: .destructive) {
                isShowingClearConfirmation = true
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct WatchScheduleEmptyStateView: View {
    let message: String
    var actionTitle: String? = nil
    var feedbackText: String? = nil
    var isActionDisabled = false
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            Text(message)
                .font(.headline)
                .multilineTextAlignment(.center)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .disabled(isActionDisabled)
            }

            if let feedbackText {
                Text(feedbackText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    }
}
