#if canImport(WatchConnectivity)

import Foundation
import OSLog
import WatchConnectivity
#if canImport(WidgetKit)
import WidgetKit
#endif

enum WatchScheduleSyncError: Error, Equatable {
    case notSupported
    case noSnapshot
    case invalidPayload
    case persistenceFailed
    case transferFailed
}

/// iPhone 与 Apple Watch 之间的课表快照同步器。
///
/// 当前策略非常明确：
/// - iPhone 仍然是真相源，负责产生 `ScheduleExternalSnapshot`
/// - 通过 `WatchConnectivity` 把最新快照推到 watch
/// - watch 收到后写入本地 App Group，再由 watch widget 读取
@MainActor
final class WatchScheduleSyncManager: NSObject, WCSessionDelegate {
    static let shared = WatchScheduleSyncManager()
    nonisolated private static let logger = Logger(
        subsystem: "BIT101-dev.BIT101-iOS",
        category: "WatchScheduleSync"
    )

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
    /// 编码一份快照，供 iPhone -> watch 同步链路复用。
    private func encodedSnapshotData(_ snapshot: ScheduleExternalSnapshot) -> Data? {
        do {
            return try ScheduleExternalSnapshotCodec.encode(snapshot)
        } catch {
            Self.logger.error("Failed to encode the watch schedule snapshot: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// 从共享仓库读取并编码当前最新快照。
    private func currentSnapshotDataIfAvailable() -> Data? {
        guard let snapshot = ScheduleExternalSnapshotStore.load() else { return nil }
        return encodedSnapshotData(snapshot)
    }

    /// 统一把快照镜像写进 `applicationContext`。
    ///
    /// 这样主动推送、前台即时回复、被动重试三条链路都走同一份逻辑。
    private func updateApplicationContext(
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
    /// 把一份最新课表快照推送给已配对的 watch。
    func push(snapshot: ScheduleExternalSnapshot) {
        activateIfNeeded()

        let session = WCSession.default
        guard session.isPaired else { return }

        guard let data = encodedSnapshotData(snapshot) else { return }
        updateApplicationContext(withSnapshotData: data, session: session)
    }

    /// 从当前共享快照重新推送一次。
    func pushCurrentSnapshotIfAvailable() {
        let session = WCSession.default
        guard session.isPaired, let data = currentSnapshotDataIfAvailable() else { return }
        updateApplicationContext(withSnapshotData: data, session: session)
    }
    #endif

    #if os(watchOS)
    /// 在 watch 端主动请求 iPhone 重新推送最新课表快照。
    ///
    /// 优先走 `sendMessage` 做前台即时往返；如果当前不可达，再退回 `applicationContext` 的 best-effort 同步。
    func requestLatestSnapshotFromPhone(
        completion: @escaping (Result<Void, WatchScheduleSyncError>) -> Void = { _ in }
    ) {
        guard WCSession.isSupported() else {
            completion(.failure(.notSupported))
            return
        }

        activateIfNeeded()

        let session = WCSession.default
        if session.isReachable {
            session.sendMessageData(
                WatchScheduleTransferProtocol.requestData,
                replyHandler: { data in
                    Task { @MainActor in
                        completion(self.persistSnapshotData(data))
                    }
                },
                errorHandler: { error in
                    Task { @MainActor in
                        Self.logger.notice("Immediate watch sync failed; queueing a context request: \(String(describing: error), privacy: .public)")
                        do {
                            try session.updateApplicationContext(WatchScheduleTransferProtocol.requestContext)
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
        } catch {
            Self.logger.error("Failed to queue the watch schedule request: \(String(describing: error), privacy: .public)")
            completion(.failure(.transferFailed))
        }
    }
    #endif

    /// `WCSession` 激活完成后的入口。
    ///
    /// watch 端这里会主动补发一次拉取请求，确保用户第一次打开手表 App 时，
    /// 即使此前没有主动点“重新同步”，也能尽快收到手机侧的最新课表。
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        #if os(watchOS)
        if activationState == .activated {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                self.requestLatestSnapshotFromPhone()
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
            session.activate()
        }
    }
    #endif

    /// 处理 `sendMessageData` 的前台即时请求。
    ///
    /// 当前只在 watch -> iPhone “拉最新课表”这条链路上使用。
    /// 由于这是 nonisolated 的 delegate 回调，所以真正读取共享快照的动作
    /// 会再切回 `MainActor`，避免并发隔离 warning。
    nonisolated func session(
        _ session: WCSession,
        didReceiveMessageData messageData: Data,
        replyHandler: @escaping (Data) -> Void
    ) {
        #if os(iOS)
        if messageData == WatchScheduleTransferProtocol.requestData {
            Task { @MainActor in
                if let data = self.currentSnapshotDataIfAvailable() {
                    self.updateApplicationContext(withSnapshotData: data, session: session)
                    replyHandler(data)
                    return
                }

                replyHandler(Data())
            }
            return
        }
        #endif

        replyHandler(Data())
    }

    /// 处理字典形式的请求 / 回复。
    ///
    /// 这里主要保留给 `requestLatestSnapshot` 这种语义化字段，和
    /// `applicationContext` 的键保持一致，便于两条同步链复用同一套协议。
    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        #if os(iOS)
        if WatchScheduleTransferProtocol.requestsLatestSnapshot(message) {
            Task { @MainActor in
                let payload: [String: Any]
                if let data = self.currentSnapshotDataIfAvailable() {
                    self.updateApplicationContext(withSnapshotData: data, session: session)
                    payload = WatchScheduleTransferProtocol.snapshotContext(data)
                } else {
                    payload = [:]
                }
                replyHandler(payload)
            }
            return
        }
        #endif

        replyHandler([:])
    }

    /// 处理 `applicationContext` 的 best-effort 同步。
    ///
    /// 这条链路不保证每次都送达，但适合承载“最新状态镜像”；
    /// 因此主端在缓存更新时会不断覆盖它，watch 只需读取最后一份即可。
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
        Task { @MainActor in
            if case let .failure(error) = self.persistSnapshotData(data) {
                Self.logger.error("Failed to persist an application-context snapshot: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// 尝试把收到的快照数据落到本地共享仓库。
    ///
    /// 一旦成功保存，就立即触发 `WidgetCenter` 刷新，保证 Smart Stack
    /// 和手表 App 首页能尽快看到最新结果。
    @MainActor
    private func persistSnapshotData(_ data: Data) -> Result<Void, WatchScheduleSyncError> {
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

        do {
            try ScheduleExternalSnapshotStore.write(snapshot)
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
            return .success(())
        } catch {
            Self.logger.error("Failed to persist the watch schedule snapshot: \(String(describing: error), privacy: .public)")
            return .failure(.persistenceFailed)
        }
    }
}

#endif
