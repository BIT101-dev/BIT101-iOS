import StorageCore
import ScheduleContracts
import ScheduleSharedStore
#if canImport(WatchConnectivity)

import Foundation
import OSLog
import os
// WCSessionDelegate callbacks enter through SDK nonisolated methods; state is
// handed back to the MainActor manager before mutation.
import WatchConnectivity
#if canImport(WidgetKit)
import WidgetKit
#endif

/// SDK 回复闭包由锁保护，并在取得快照后消费一次。
private nonisolated final class WatchScheduleReply: Sendable {
    private let reply: OSAllocatedUnfairLock<(([String: Any]) -> Void)?>
    init(_ reply: @escaping ([String: Any]) -> Void) { self.reply = OSAllocatedUnfairLock(uncheckedState: reply) }
    func send(_ data: Data?) {
        reply.withLock {
            $0?(data.map(WatchScheduleTransferProtocol.snapshotContext) ?? [:])
            $0 = nil
        }
    }
}

/// 镜像传输保留已编码的最高版本，迟到的读取沿当前镜像回复。
nonisolated struct WatchSnapshotDeliveryBuffer {
    private var revision: UInt64?
    private var data: Data?
    private(set) var pendingData: Data?
    private(set) var lastDeliveryError: String?

    mutating func stage(_ data: Data) { pendingData = data }
    mutating func discardPending() { pendingData = nil; lastDeliveryError = nil }

    mutating func deliver(using transfer: (Data) throws -> Void) -> Bool {
        guard let pendingData else { return true }
        do {
            try transfer(pendingData)
            discardPending()
            return true
        } catch {
            lastDeliveryError = error.localizedDescription
            return false
        }
    }

    mutating func accept(_ snapshot: ScheduleExternalSnapshot) throws -> Data {
        if let revision, snapshot.revision <= revision, let data { return data }
        let encoded = try ScheduleExternalSnapshotCodec.encode(snapshot)
        revision = snapshot.revision
        data = encoded
        return encoded
    }
}

/// App 与 Watch 入口组装当前进程的共享快照仓库。
nonisolated enum PlatformScheduleSnapshotStorage {
    static let store: ScheduleExternalSnapshotStore = {
#if os(iOS)
        let files = AppFileDirectories.files
#else
        let files = AppFileSystem.files
#endif
        return ScheduleExternalSnapshotStore(files: files, containerURL: files.appGroupContainerURL(identifier: ScheduleSharedContainer.identifier))
    }()
}

nonisolated enum WatchSnapshotReceptionPolicy {
    typealias ClearingBoundary = (revision: UInt64, generatedAt: Date)
    static func accepts(receivedAt: ContinuousClock.Instant, afterClearingAt clearedAt: ContinuousClock.Instant?) -> Bool {
        clearedAt.map { receivedAt > $0 } ?? true
    }

    static func accepts(_ snapshot: ScheduleExternalSnapshot, afterClearing cleared: ClearingBoundary?) -> Bool {
        guard let cleared else { return true }
        return snapshot.revision == 0 && cleared.revision == 0
            ? snapshot.generatedAt > cleared.generatedAt : snapshot.revision > cleared.revision
    }
}

/// 接收、版本比较与清理沿同一执行器完成。
actor WatchSnapshotPersistence {
    static let shared = WatchSnapshotPersistence()
    private let store: ScheduleExternalSnapshotStore
    private var clearedAt: ContinuousClock.Instant?
    private var clearedVersion: WatchSnapshotReceptionPolicy.ClearingBoundary?

    init(store: ScheduleExternalSnapshotStore = PlatformScheduleSnapshotStorage.store) { self.store = store }

    func latestRevision() -> UInt64 { max(store.latestRevision, clearedVersion?.revision ?? 0) }

    func receive(_ data: Data, receivedAt: ContinuousClock.Instant, accountIdentifier: String?) -> Result<Bool, WatchScheduleSyncError> {
        guard !data.isEmpty else { return .failure(.noSnapshot) }
        guard WatchSnapshotReceptionPolicy.accepts(receivedAt: receivedAt, afterClearingAt: clearedAt) else { return .failure(.staleSnapshot) }
        guard let snapshot = try? ScheduleExternalSnapshotCodec.decode(data) else { return .failure(.invalidPayload) }
        guard WatchSnapshotReceptionPolicy.accepts(snapshot, afterClearing: clearedVersion) else { return .failure(.staleSnapshot) }
        if let accountIdentifier, AccountStorageIdentity.stableToken(for: snapshot.studentID)
            != AccountStorageIdentity.stableToken(for: accountIdentifier) { return .failure(.staleSnapshot) }
        do { return .success(try store.writeIfNewer(snapshot)) }
        catch {
            return .failure(error as? ScheduleExternalSnapshotStoreError == .staleSnapshot ? .staleSnapshot : .persistenceFailed)
        }
    }

    func clear(at instant: ContinuousClock.Instant) -> Bool {
        guard clearedAt.map({ instant >= $0 }) ?? true else { return false }
        clearedAt = instant
        let snapshot = store.load()
        let cleared = store.clearRetainingVersion()
        if cleared, let snapshot, WatchSnapshotReceptionPolicy.accepts(snapshot, afterClearing: clearedVersion) {
            clearedVersion = (snapshot.revision, snapshot.generatedAt)
        }
        return cleared
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
        subsystem: "BIT101",
        category: "WatchScheduleSync"
    )

    #if os(iOS)
    private var deliveryBuffer = WatchSnapshotDeliveryBuffer()
    var lastDeliveryError: String? { deliveryBuffer.lastDeliveryError }
    #elseif os(watchOS)
    private let requestQueue = WatchScheduleRequestQueue()
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
            return try deliveryBuffer.accept(snapshot)
        } catch {
            Self.logger.error("Failed to encode the watch schedule snapshot: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// 从共享仓库读取并编码当前快照。
    private func currentSnapshotDataIfAvailable(for studentID: String, isLoggedIn: Bool, knownRevision: UInt64 = 0) async -> Data? {
        guard AppAccountSession.storage.hasResolvedSession else { return nil }
        guard let snapshot = await ScheduleExternalSnapshotWriteQueue.shared.snapshot(
            for: studentID, isLoggedIn: isLoggedIn, knownRevision: knownRevision),
              AppAccountSession.storage.hasResolvedSession else { return nil }
        do {
            return try deliveryBuffer.accept(snapshot)
        } catch {
            Self.logger.error("Failed to encode the watch schedule snapshot: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// 将快照镜像统一写入 `applicationContext`。
    ///
    /// 主动推送、前台即时回复和 `applicationContext` 请求共用这份逻辑。
    private func updateApplicationContext(
        withSnapshotData data: Data,
        session: WCSession
    ) {
        deliveryBuffer.stage(data)
        if !deliveryBuffer.deliver(using: { try session.updateApplicationContext(WatchScheduleTransferProtocol.snapshotContext($0)) }) {
            Self.logger.error("Failed to update the watch application context: \(self.lastDeliveryError ?? "", privacy: .public)")
        }
    }
    #endif

    #if os(iOS)
    /// 将最新课表快照推送给已配对的 watch。
    func push(snapshot: ScheduleExternalSnapshot) {
        guard AppAccountSession.storage.hasResolvedSession else { return }
        let studentID = AppAccountSession.storage.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard snapshot.studentID == AppStorageSession(accountIdentifier: studentID).accountStorageIdentifier else {
            return
        }
        activateIfNeeded()

        let session = WCSession.default
        guard let data = encodedSnapshotData(snapshot) else { return }
        guard session.activationState == .activated else {
            deliveryBuffer.stage(data)
            return
        }
        guard session.isPaired else { return }
        updateApplicationContext(withSnapshotData: data, session: session)
    }

    /// 从当前共享快照重新推送一次。
    func pushCurrentSnapshotIfAvailable(knownRevision: UInt64 = 0) {
        guard AppAccountSession.storage.hasResolvedSession else { return }
        activateIfNeeded()
        let session = WCSession.default
        let credentials = AppAccountSession.storage.communityCredentials
        let studentID = AppAccountSession.storage.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let isLoggedIn = AppAccountSession.storage.hasCachedSession
        Task {
            guard let data = await self.currentSnapshotDataIfAvailable(for: studentID, isLoggedIn: isLoggedIn, knownRevision: knownRevision),
                  credentials == AppAccountSession.storage.communityCredentials else { return }
            guard session.activationState == .activated else {
                deliveryBuffer.stage(data)
                return
            }
            guard session.isPaired else { return }
            self.updateApplicationContext(withSnapshotData: data, session: session)
        }
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
        Task { @MainActor in
            let knownRevision = await WatchSnapshotPersistence.shared.latestRevision()
            guard self.requestQueue.generation == generation else { return }
            let session = WCSession.default
            if session.isReachable {
                session.sendMessage(
                    WatchScheduleTransferProtocol.requestContext(knownRevision: knownRevision),
                    replyHandler: { @Sendable context in
                        let data = WatchScheduleTransferProtocol.snapshotData(from: context) ?? Data()
                        let receivedAt = ContinuousClock.now
                        Task { @MainActor in
                            guard self.requestQueue.generation == generation else { return }
                            let result = await self.persistSnapshotData(data, receivedAt: receivedAt)
                            guard self.requestQueue.generation == generation else { return }
                            completion(result)
                        }
                    },
                    errorHandler: { @Sendable error in
                        Task { @MainActor in
                            guard self.requestQueue.generation == generation else { return }
                            Self.logger.notice("Immediate watch sync failed; queueing a context request: \(String(describing: error), privacy: .public)")
                            do {
                                try WCSession.default.updateApplicationContext(WatchScheduleTransferProtocol.requestContext(knownRevision: knownRevision))
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
                try session.updateApplicationContext(WatchScheduleTransferProtocol.requestContext(knownRevision: knownRevision))
                completion(.success(.requested))
            } catch {
                Self.logger.error("Failed to queue the watch schedule request: \(String(describing: error), privacy: .public)")
                completion(.failure(.transferFailed))
            }
        }
    }

    func clearSnapshot() async -> Bool {
        requestQueue.clear()
        let cleared = await WatchSnapshotPersistence.shared.clear(at: .now)
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
                guard AppAccountSession.storage.hasResolvedSession, let data = self.deliveryBuffer.pendingData else { return }
                let studentID = AppAccountSession.storage.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard WCSession.default.isPaired, Self.isSnapshotData(data, for: studentID) else {
                    self.deliveryBuffer.discardPending()
                    return
                }
                self.updateApplicationContext(withSnapshotData: data, session: WCSession.default)
            }
        }
        #endif
        if let error {
            Self.logger.error("WatchConnectivity activation failed: \(String(describing: error), privacy: .public)")
        }
    }

    #if os(iOS)
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            let session = WCSession.default
            guard AppAccountSession.storage.hasResolvedSession, session.isReachable, session.activationState == .activated, session.isPaired,
                  let data = self.deliveryBuffer.pendingData else { return }
            let studentID = AppAccountSession.storage.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isSnapshotData(data, for: studentID) else { self.deliveryBuffer.discardPending(); return }
            self.updateApplicationContext(withSnapshotData: data, session: session)
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor in
            WCSession.default.activate()
        }
    }
    #endif

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
        if let knownRevision = WatchScheduleTransferProtocol.knownRevision(from: message) {
            let reply = WatchScheduleReply(replyHandler)
            Task { @MainActor in
                let credentials = AppAccountSession.storage.communityCredentials
                let studentID = AppAccountSession.storage.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
                let data = await self.currentSnapshotDataIfAvailable(for: studentID,
                    isLoggedIn: AppAccountSession.storage.hasCachedSession, knownRevision: knownRevision)
                guard credentials == AppAccountSession.storage.communityCredentials else { reply.send(nil); return }
                if let data { self.updateApplicationContext(withSnapshotData: data, session: WCSession.default) }
                reply.send(data)
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
        if let knownRevision = WatchScheduleTransferProtocol.knownRevision(from: applicationContext) {
            Task { @MainActor in
                self.pushCurrentSnapshotIfAvailable(knownRevision: knownRevision)
            }
            return
        }
        #endif

        guard let data = WatchScheduleTransferProtocol.snapshotData(from: applicationContext) else { return }
        let receivedAt = ContinuousClock.now
        Task { @MainActor in
            if case let .failure(error) = await self.persistSnapshotData(data, receivedAt: receivedAt) {
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
        persistence: WatchSnapshotPersistence = .shared,
        notificationCenter: NotificationCenter = .default,
        receivedAt: ContinuousClock.Instant = .now
    ) async -> Result<WatchScheduleSyncOutcome, WatchScheduleSyncError> {
        #if os(iOS)
        let credentials = AppAccountSession.storage.communityCredentials
        let currentStudentID = AppAccountSession.storage.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        let currentStudentID: String? = nil
        #endif
        let result = await persistence.receive(data, receivedAt: receivedAt, accountIdentifier: currentStudentID)
        #if os(iOS)
        guard credentials == AppAccountSession.storage.communityCredentials else { return .failure(.staleSnapshot) }
        #endif
        switch result {
        case let .success(changed):
            notificationCenter.post(name: Self.snapshotReceivedNotification, object: nil)
            #if canImport(WidgetKit)
            if changed { WidgetCenter.shared.reloadAllTimelines() }
            #endif
            return .success(.received)
        case let .failure(error):
            Self.logger.error("Failed to persist the watch schedule snapshot: \(String(describing: error), privacy: .public)")
            return .failure(error)
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
