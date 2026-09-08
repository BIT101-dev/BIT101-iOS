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

/// 管理 iPhone 与 Apple Watch 之间的课表快照同步。
///
/// 同步策略如下：
/// - iPhone 作为课表真相源，生成 `ScheduleExternalSnapshot`
/// - `WatchConnectivity` 将最新快照发送到 watch
/// - watch 将快照写入本地 App Group，watch app 和 watch widget 读取共享快照
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
    private func currentSnapshotDataIfAvailable() -> Data? {
        guard let snapshot = ScheduleExternalSnapshotStore.load() else { return nil }
        return encodedSnapshotData(snapshot)
    }

    /// 将快照镜像统一写入 `applicationContext`。
    ///
    /// 主动推送、前台即时回复和 `applicationContext` 请求共用这份逻辑。
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
    /// 将最新课表快照推送给已配对的 watch。
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
    /// watch 端向 iPhone 请求最新课表快照。
    ///
    /// session 可达时使用 `sendMessage` 完成前台即时往返；session 不可达时，
    /// `applicationContext` 以 best-effort 方式传递请求。
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
    /// 该回调服务 watch -> iPhone 的“拉最新课表”请求。
    /// delegate 回调运行在 nonisolated 上下文，读取共享快照的动作通过
    /// `MainActor` 执行，以满足并发隔离要求。
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
        Task { @MainActor in
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
