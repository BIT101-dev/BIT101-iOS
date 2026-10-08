import StorageCore
import ScheduleContracts
import ScheduleSharedStore
#if canImport(WatchConnectivity)

import Foundation
import OSLog
// WCSessionDelegate callbacks enter through SDK nonisolated methods; state is
// handed back to the MainActor manager before mutation.
import WatchConnectivity
#if canImport(WidgetKit)
import WidgetKit
#endif

/// App 与 Watch 入口组装当前进程的共享快照仓库。
nonisolated enum PlatformScheduleSnapshotStorage {
    static let store = ScheduleExternalSnapshotStore(files: AppFileSystem.files, containerURL: AppFileSystem.files.appGroupContainerURL(identifier: ScheduleSharedContainer.identifier))
}

nonisolated enum WatchSnapshotReceptionPolicy {
    static func accepts(receivedAt: ContinuousClock.Instant, afterClearingAt clearedAt: ContinuousClock.Instant?) -> Bool {
        clearedAt.map { receivedAt > $0 } ?? true
    }
}

@MainActor
final class WatchScheduleRequestQueue {
    typealias Completion = @MainActor (Result<WatchScheduleSyncOutcome, WatchScheduleSyncError>) -> Void
    private(set) var generation: UInt64 = 0
    private var pending: (generation: UInt64, completion: Completion)?

    func begin(isActivated: Bool, completion: @escaping Completion) -> UInt64? {
        generation &+= 1
        pending = isActivated ? nil : (generation, completion)
        return isActivated ? generation : nil
    }

    func takePending() -> (generation: UInt64, completion: Completion)? {
        defer { pending = nil }
        return pending
    }

    func clear() {
        generation &+= 1
        pending = nil
    }
}

/// 管理 iPhone 与 Apple Watch 之间的课表快照同步。
///
/// 同步策略如下：
/// - iPhone 作为课表真相源，生成 `ScheduleExternalSnapshot`
/// - `WatchConnectivity` 将最新快照发送到 watch
/// - watch 将快照写入本地 App Group，watch app 和 watch widget 读取共享快照
@MainActor
final class WatchScheduleSyncManager: NSObject, WCSessionDelegate {
    static let shared = WatchScheduleSyncManager()
    static let snapshotReceivedNotification = Notification.Name("WatchScheduleSnapshotDidReceive")
    nonisolated private static let logger = Logger(
        subsystem: "BIT101-dev.BIT101-iOS",
        category: "WatchScheduleSync"
    )

    #if os(iOS)
    private var pendingSnapshotData: Data?
    #elseif os(watchOS)
    private let requestQueue = WatchScheduleRequestQueue()
    private var lastSnapshotClear: ContinuousClock.Instant?
    #endif

    private override init() {
        super.init()
    }

    /// 激活当前设备上的 `WCSession`。
    func activateIfNeeded() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        if session.delegate !== self {
            session.delegate = self
        }
        if session.activationState == .notActivated {
            session.activate()
        }
    }

    #if os(iOS)
    /// 为 iPhone -> watch 同步链路编码课表快照。
    private func encodedSnapshotData(_ snapshot: ScheduleExternalSnapshot) -> Data? {
        do {
            return try ScheduleExternalSnapshotCodec.encode(snapshot)
        } catch {
            Self.logger.error("Failed to encode the watch schedule snapshot: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// 从共享仓库读取并编码当前快照。
    private nonisolated static func currentSnapshotDataIfAvailable(for studentID: String) -> Data? {
        let accountToken = AppStorageSession(accountIdentifier: studentID).accountStorageIdentifier
        guard let snapshot = PlatformScheduleSnapshotStorage.store.load(),
              snapshot.studentID == studentID || snapshot.studentID == accountToken
        else { return nil }
        let normalizedSnapshot = snapshot.replacingStudentID(with: accountToken)
        do {
            if normalizedSnapshot != snapshot {
                try PlatformScheduleSnapshotStorage.store.write(normalizedSnapshot)
            }
            return try ScheduleExternalSnapshotCodec.encode(normalizedSnapshot)
        } catch {
            Self.logger.error("Failed to encode the watch schedule snapshot: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// 将快照镜像统一写入 `applicationContext`。
    ///
    /// 主动推送、前台即时回复和 `applicationContext` 请求共用这份逻辑。
    private nonisolated static func updateApplicationContext(
        withSnapshotData data: Data,
        session: WCSession
    ) {
        do {
            try session.updateApplicationContext(WatchScheduleTransferProtocol.snapshotContext(data))
        } catch {
            Self.logger.error("Failed to update the watch application context: \(String(describing: error), privacy: .public)")
        }
    }
    #endif

    #if os(iOS)
    /// 将最新课表快照推送给已配对的 watch。
    func push(snapshot: ScheduleExternalSnapshot) {
        let studentID = AppAccountSession.storage.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard snapshot.studentID == AppStorageSession(accountIdentifier: studentID).accountStorageIdentifier else {
            return
        }
        activateIfNeeded()

        let session = WCSession.default
        guard let data = encodedSnapshotData(snapshot) else { return }
        guard session.activationState == .activated else {
            pendingSnapshotData = data
            return
        }
        guard session.isPaired else { return }
        Self.updateApplicationContext(withSnapshotData: data, session: session)
    }

    /// 从当前共享快照重新推送一次。
    func pushCurrentSnapshotIfAvailable() {
        activateIfNeeded()
        let session = WCSession.default
        let studentID = AppAccountSession.storage.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Self.currentSnapshotDataIfAvailable(for: studentID) else { return }
        guard session.activationState == .activated else {
            pendingSnapshotData = data
            return
        }
        guard session.isPaired else { return }
        Self.updateApplicationContext(withSnapshotData: data, session: session)
    }
    #endif

    #if os(watchOS)
    /// watch 端向 iPhone 请求最新课表快照。
    ///
    /// session 可达时使用 `sendMessage` 完成前台即时往返；session 不可达时，
    /// `applicationContext` 以 best-effort 方式传递请求。
    /// SDK 后台回调使用 Sendable 闭包，completion 在 MainActor 返回快照落地或请求入队结果。
    func requestLatestSnapshotFromPhone(
        completion: @escaping @MainActor (Result<WatchScheduleSyncOutcome, WatchScheduleSyncError>) -> Void = { _ in }
    ) {
        guard WCSession.isSupported() else {
            completion(.failure(.notSupported))
            return
        }

        activateIfNeeded()
        guard let generation = requestQueue.begin(isActivated: WCSession.default.activationState == .activated,
            completion: completion) else { return }
        sendRequest(generation: generation, completion: completion)
    }

    private func sendRequest(generation: UInt64, completion: @escaping WatchScheduleRequestQueue.Completion) {
        let session = WCSession.default
        if session.isReachable {
            session.sendMessageData(
                WatchScheduleTransferProtocol.requestData,
                replyHandler: { @Sendable data in
                    Task { @MainActor in
                        guard self.requestQueue.generation == generation else { return }
                        completion(self.persistSnapshotData(data))
                    }
                },
                errorHandler: { @Sendable error in
                    Task { @MainActor in
                        guard self.requestQueue.generation == generation else { return }
                        Self.logger.notice("Immediate watch sync failed; queueing a context request: \(String(describing: error), privacy: .public)")
                        do {
                            try WCSession.default.updateApplicationContext(WatchScheduleTransferProtocol.requestContext)
                            completion(.success(.requested))
                        } catch {
                            Self.logger.error("Failed to queue the watch schedule request: \(String(describing: error), privacy: .public)")
                            completion(.failure(.transferFailed))
                        }
                    }
                }
            )
            return
        }

        do {
            try session.updateApplicationContext(WatchScheduleTransferProtocol.requestContext)
            completion(.success(.requested))
        } catch {
            Self.logger.error("Failed to queue the watch schedule request: \(String(describing: error), privacy: .public)")
            completion(.failure(.transferFailed))
        }
    }

    func clearSnapshot() -> Bool {
        requestQueue.clear()
        lastSnapshotClear = ContinuousClock.now
        let cleared = PlatformScheduleSnapshotStorage.store.clear()
        #if canImport(WidgetKit)
        if cleared { WidgetCenter.shared.reloadAllTimelines() }
        #endif
        return cleared
    }
    #endif

    /// 处理 `WCSession` 激活完成事件。
    ///
    /// watch App 激活后会主动发送一次拉取请求，让首次打开手表 App 的用户
    /// 直接获取手机侧的最新课表。
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        #if os(watchOS)
        Task { @MainActor in
            if let pending = self.requestQueue.takePending() {
                if activationState == .activated {
                    self.sendRequest(generation: pending.generation, completion: pending.completion)
                } else {
                    pending.completion(.failure(.transferFailed))
                }
            } else if activationState == .activated, self.requestQueue.generation == 0 {
                self.requestLatestSnapshotFromPhone()
            }
        }
        #endif
        #if os(iOS)
        if activationState == .activated {
            Task { @MainActor in
                guard let data = self.pendingSnapshotData else { return }
                self.pendingSnapshotData = nil
                let studentID = AppAccountSession.storage.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard WCSession.default.isPaired, Self.isSnapshotData(data, for: studentID) else { return }
                Self.updateApplicationContext(withSnapshotData: data, session: WCSession.default)
            }
        }
        #endif
        if let error {
            Self.logger.error("WatchConnectivity activation failed: \(String(describing: error), privacy: .public)")
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor in
            WCSession.default.activate()
        }
    }
    #endif

    /// 处理 `sendMessageData` 的前台即时请求。
    ///
    /// 该回调服务 watch -> iPhone 的“拉最新课表”请求。
    /// 账号读取与快照发布沿主线程临界区完成，回调回复携带该快照的单调版本。
    nonisolated func session(
        _ session: WCSession,
        didReceiveMessageData messageData: Data,
        replyHandler: @escaping (Data) -> Void
    ) {
        #if os(iOS)
        if messageData == WatchScheduleTransferProtocol.requestData {
            let data: Data? = DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    let studentID = AppAccountSession.storage.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let data = Self.currentSnapshotDataIfAvailable(for: studentID) else { return nil }
                    Self.updateApplicationContext(withSnapshotData: data, session: WCSession.default)
                    return data
                }
            }
            replyHandler(data ?? Data())
            return
        }
        #endif

        replyHandler(Data())
    }

    /// 处理字典形式的请求与回复。
    ///
    /// 该方法承载 `requestLatestSnapshot` 语义字段，并让它与
    /// `applicationContext` 的键保持一致，供两条同步链路复用同一套协议。
    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        #if os(iOS)
        if WatchScheduleTransferProtocol.requestsLatestSnapshot(message) {
            let data: Data? = DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    let studentID = AppAccountSession.storage.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let data = Self.currentSnapshotDataIfAvailable(for: studentID) else { return nil }
                    Self.updateApplicationContext(withSnapshotData: data, session: WCSession.default)
                    return data
                }
            }
            replyHandler(data.map(WatchScheduleTransferProtocol.snapshotContext) ?? [:])
            return
        }
        #endif

        replyHandler([:])
    }

    /// 处理 `applicationContext` 的 best-effort 同步。
    ///
    /// 该链路传递“最新状态镜像”，系统按 best-effort 语义交付；
    /// 主端在缓存更新时持续覆盖 `applicationContext`，watch 读取最后一份快照。
    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        #if os(iOS)
        if WatchScheduleTransferProtocol.requestsLatestSnapshot(applicationContext) {
            Task { @MainActor in
                self.pushCurrentSnapshotIfAvailable()
            }
            return
        }
        #endif

        guard let data = WatchScheduleTransferProtocol.snapshotData(from: applicationContext) else { return }
        let receivedAt = ContinuousClock.now
        Task { @MainActor in
            #if os(watchOS)
            guard WatchSnapshotReceptionPolicy.accepts(receivedAt: receivedAt, afterClearingAt: self.lastSnapshotClear) else { return }
            #endif
            if case let .failure(error) = self.persistSnapshotData(data) {
                Self.logger.error("Failed to persist an application-context snapshot: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// 将收到的快照数据写入本地共享仓库。
    ///
    /// 保存成功后，立即触发 `WidgetCenter` 刷新，让 Smart Stack
    /// 和手表 App 首页读取最新结果。
    @MainActor
    func persistSnapshotData(
        _ data: Data,
        store: ScheduleExternalSnapshotStore = PlatformScheduleSnapshotStorage.store,
        notificationCenter: NotificationCenter = .default
    ) -> Result<WatchScheduleSyncOutcome, WatchScheduleSyncError> {
        guard !data.isEmpty else {
            return .failure(.noSnapshot)
        }

        let snapshot: ScheduleExternalSnapshot
        do {
            snapshot = try ScheduleExternalSnapshotCodec.decode(data)
        } catch {
            Self.logger.error("Failed to decode the watch schedule snapshot: \(String(describing: error), privacy: .public)")
            return .failure(.invalidPayload)
        }

        #if os(iOS)
        let currentStudentID = AppAccountSession.storage.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountToken = AppStorageSession(accountIdentifier: currentStudentID).accountStorageIdentifier
        guard snapshot.studentID == currentStudentID || snapshot.studentID == accountToken else {
            return .failure(.staleSnapshot)
        }
        let snapshotToPersist = snapshot.replacingStudentID(with: accountToken)
        #else
        let snapshotToPersist = snapshot
        #endif

        do {
            let changed = try store.writeIfNewer(snapshotToPersist)
            notificationCenter.post(name: Self.snapshotReceivedNotification, object: nil)
            #if canImport(WidgetKit)
            if changed { WidgetCenter.shared.reloadAllTimelines() }
            #endif
            return .success(.received)
        } catch {
            if error as? ScheduleExternalSnapshotStoreError == .staleSnapshot { return .failure(.staleSnapshot) }
            Self.logger.error("Failed to persist the watch schedule snapshot: \(String(describing: error), privacy: .public)")
            return .failure(.persistenceFailed)
        }
    }

    #if os(iOS)
    private nonisolated static func isSnapshotData(_ data: Data, for studentID: String) -> Bool {
        guard let snapshot = try? ScheduleExternalSnapshotCodec.decode(data) else { return false }
        let accountToken = AppStorageSession(accountIdentifier: studentID).accountStorageIdentifier
        return snapshot.studentID == accountToken
    }
    #endif
}

#endif
