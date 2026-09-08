import SwiftUI

enum WatchScheduleRefreshState: Equatable {
    case idle
    case syncing
    case succeeded
    case failed

    var buttonTitle: String {
        self == .syncing ? "同步中…" : "重新同步"
    }

    var feedbackText: String? {
        switch self {
        case .succeeded:
            return "已同步"
        case .failed:
            return "同步未完成"
        case .idle, .syncing:
            return nil
        }
    }
}

/// 状态模型通过依赖闭包接入系统单例和时间来源，便于使用纯内存依赖测试。
@MainActor
struct WatchScheduleStatusDependencies {
    var now: () -> Date
    var loadResolvedSnapshot: (Date, Int) -> ScheduleExternalResolvedSnapshot
    var clearSnapshot: () -> Void
    var activateSync: () -> Void
    var requestLatestSnapshot: (@escaping (Result<Void, WatchScheduleSyncError>) -> Void) -> Void

    static let live = WatchScheduleStatusDependencies(
        now: Date.init,
        loadResolvedSnapshot: { now, limit in
            ScheduleOccurrenceResolver.loadResolvedSnapshot(now: now, limit: limit)
        },
        clearSnapshot: ScheduleExternalSnapshotStore.clear,
        activateSync: WatchScheduleSyncManager.shared.activateIfNeeded,
        requestLatestSnapshot: WatchScheduleSyncManager.shared.requestLatestSnapshotFromPhone
    )
}

/// watch 主页面状态模型协调共享快照、时间推进和镜像同步。
@MainActor
final class WatchScheduleStatusModel: ObservableObject {
    private static let maxVisibleOccurrences = 50
    private static let foregroundRefreshInterval: TimeInterval = 60

    @Published private(set) var snapshot: ScheduleExternalSnapshot?
    @Published private(set) var contentState: ScheduleExternalContentState = .missing
    @Published private(set) var nextOccurrence: ScheduleExternalOccurrence?
    @Published private(set) var upcomingOccurrences: [ScheduleExternalOccurrence] = []
    @Published private(set) var refreshState: WatchScheduleRefreshState = .idle
    @Published private(set) var referenceDate: Date

    private let dependencies: WatchScheduleStatusDependencies
    private var refreshFeedbackTask: Task<Void, Never>?
    private var foregroundRefreshTask: Task<Void, Never>?

    convenience init() {
        self.init(dependencies: .live)
    }

    init(dependencies: WatchScheduleStatusDependencies) {
        self.dependencies = dependencies
        self.referenceDate = dependencies.now()
    }

    deinit {
        refreshFeedbackTask?.cancel()
        foregroundRefreshTask?.cancel()
    }

    func activate() {
        dependencies.activateSync()
        reload()
        startForegroundRefresh()
        requestLatestSnapshot(reportResult: false)
    }

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

    func reload(now: Date? = nil) {
        let now = now ?? dependencies.now()
        referenceDate = now
        let resolved = dependencies.loadResolvedSnapshot(now, Self.maxVisibleOccurrences)
        snapshot = resolved.snapshot
        contentState = resolved.contentState
        nextOccurrence = resolved.nextOccurrence
        upcomingOccurrences = resolved.upcomingOccurrences
    }

    func requestRefresh() {
        refreshFeedbackTask?.cancel()
        refreshState = .syncing
        requestLatestSnapshot(reportResult: true)
        reload()
        refreshFeedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, self.refreshState == .syncing else { return }
            self.finishRefresh(as: .failed)
        }
    }

    func handleSnapshotDidChange() {
        reload()
        guard refreshState == .syncing else { return }
        finishRefresh(as: .succeeded)
    }

    func clearLocalData() {
        refreshFeedbackTask?.cancel()
        refreshState = .idle
        referenceDate = dependencies.now()
        dependencies.clearSnapshot()
        snapshot = nil
        contentState = .missing
        nextOccurrence = nil
        upcomingOccurrences = []
    }

    var refreshButtonTitle: String { refreshState.buttonTitle }
    var refreshFeedbackText: String? { refreshState.feedbackText }
    var isRefreshing: Bool { refreshState == .syncing }

    private func requestLatestSnapshot(reportResult: Bool) {
        dependencies.requestLatestSnapshot { [weak self] result in
            guard reportResult else { return }
            Task { @MainActor [weak self] in
                guard let self, self.refreshState == .syncing else { return }
                switch result {
                case .success:
                    self.reload()
                case .failure:
                    self.finishRefresh(as: .failed)
                }
            }
        }
    }

    private func finishRefresh(as state: WatchScheduleRefreshState) {
        refreshFeedbackTask?.cancel()
        refreshState = state
        refreshFeedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled, let self else { return }
            self.refreshState = .idle
        }
    }

    private func startForegroundRefresh() {
        guard foregroundRefreshTask == nil else { return }
        foregroundRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.foregroundRefreshInterval))
                guard !Task.isCancelled, let self else { return }
                self.reload()
            }
        }
    }

    private func stopForegroundRefresh() {
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
    }
}
