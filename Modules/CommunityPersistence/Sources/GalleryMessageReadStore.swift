import CommunityCore
import StorageCore
import Combine
import Foundation

/// 本地消息已读仓库。
///
/// 记录“当前分类最新一批消息”和“已被用户手动标记已读的消息”；系统通知申请保持独立。
public final class GalleryMessageReadStore: GalleryMessageReadStoring {
    private let changeSubject = PassthroughSubject<AppStorageSession, Never>()
    public var changes: AnyPublisher<AppStorageSession, Never> { changeSubject.eraseToAnyPublisher() }
    public var currentSession: AppStorageSession { session() }
    private let saveSubject = PassthroughSubject<AppStorageSession, Never>()
    public var localSaves: AnyPublisher<AppStorageSession, Never> { saveSubject.eraseToAnyPublisher() }
    private let session: () -> AppStorageSession

    private let snapshotStore: AccountScopedCodableStore<GalleryMessageReadSnapshot>

    public init(defaults: UserDefaults, session: @escaping () -> AppStorageSession) {
        self.session = session
        snapshotStore = AccountScopedCodableStore(keyPrefix: "gallery.message.read.snapshot", defaults: defaults, sessionProvider: session)
    }

    /// 读取当前账号对应的本地快照。
    ///
    /// 这里故意完全按账号隔离，避免切换学号后把上一个账号的消息已读状态串过来。
    private func loadSnapshot() -> GalleryMessageReadSnapshot {
        snapshotStore.load() ?? GalleryMessageReadSnapshot()
    }

    /// 回写当前账号的本地快照。
    private func saveSnapshot(_ snapshot: GalleryMessageReadSnapshot, shouldSync: Bool = true) {
        snapshotStore.save(snapshot)
        if shouldSync {
            saveSubject.send(session())
        }
        changeSubject.send(session())
    }

    public func syncSnapshot() -> GalleryMessageReadSnapshot {
        var snapshot = loadSnapshot()
        snapshot.latestIDsByType = [:]
        snapshot.seenIDsByType = snapshot.seenIDsByType.mapValues { Array(Set($0)).sorted() }
        return snapshot
    }

    public func applySyncedSnapshot(_ snapshot: GalleryMessageReadSnapshot) {
        saveSnapshot(loadSnapshot().mergingReadState(snapshot), shouldSync: false)
    }

    /// 用服务端给出的未读数量，重建当前分类的“候选新消息”集合。
    ///
    /// 当服务端未读数为 0 时保留本地结果，让用户打开列表后继续看到当前的新消息样式。
    public func replaceLatestIDs(_ ids: [Int], unreadCount: Int, for type: GalleryMessageType) {
        guard unreadCount > 0 else { return }

        var snapshot = loadSnapshot()
        let latestUnread = Array(ids.prefix(unreadCount))
        let normalizedLatest = normalize(latestUnread)
        let existingSeen = Set(snapshot.seenIDsByType[type.rawValue] ?? [])

        snapshot.latestIDsByType[type.rawValue] = normalizedLatest
        snapshot.seenIDsByType[type.rawValue] = Array(existingSeen).sorted()
        saveSnapshot(snapshot)
    }

    /// 把指定消息标记为已读。
    public func markSeen(ids: [Int], for type: GalleryMessageType) {
        var snapshot = loadSnapshot()
        let existing = Set(snapshot.seenIDsByType[type.rawValue] ?? [])
        snapshot.seenIDsByType[type.rawValue] = normalize(Array(existing.union(ids)))
        saveSnapshot(snapshot)
    }

    /// 当前分类本地仍被视作“新消息”的数量。
    ///
    /// 已读状态的判定规则是：出现在 latest 集合里，但还没出现在 seen 集合里。
    public func unreadCount(for type: GalleryMessageType) -> Int {
        let snapshot = loadSnapshot()
        let latest = Set(snapshot.latestIDsByType[type.rawValue] ?? [])
        guard !latest.isEmpty else { return 0 }
        let seen = Set(snapshot.seenIDsByType[type.rawValue] ?? [])
        return latest.subtracting(seen).count
    }

    /// 判断某条消息是否需要按“新消息”样式展示。
    public func isUnread(id: Int, for type: GalleryMessageType) -> Bool {
        let snapshot = loadSnapshot()
        let latest = Set(snapshot.latestIDsByType[type.rawValue] ?? [])
        guard latest.contains(id) else { return false }
        let seen = Set(snapshot.seenIDsByType[type.rawValue] ?? [])
        return !seen.contains(id)
    }

    /// 去重同时保留原始顺序。
    private func normalize(_ ids: [Int]) -> [Int] {
        Array(NSOrderedSet(array: ids)) as? [Int] ?? ids
    }
}
