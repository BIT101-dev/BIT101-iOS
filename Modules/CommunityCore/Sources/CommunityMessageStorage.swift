import StorageCore
import Combine
import Foundation

/// 消息中心的消息类型。
///
/// 类型集中提供标题和状态字典键。
public nonisolated enum GalleryMessageType: String, CaseIterable, Identifiable, Hashable, Sendable {
    case comment
    case like
    case follow
    case system

    /// 供 `Picker` 和状态字典使用的稳定标识。
    public var id: String { rawValue }

    /// 分段控件展示的中文标题。
    public var title: String {
        switch self {
        case .comment:
            return "评论"
        case .like:
            return "点赞"
        case .follow:
            return "关注"
        case .system:
            return "系统"
        }
    }

}

/// 本地保存的消息已读快照。
///
/// 服务端提供分类未读数，客户端按账号保存逐条消息的“伪新消息”状态。
public nonisolated struct GalleryMessageReadSnapshot: Codable, Equatable, Sendable {
    public static let maximumHistoryIDsPerType = 1_024
    public var latestIDsByType: [String: [Int]] = [:]
    public var seenIDsByType: [String: [Int]] = [:]
    public var retainedFromIDByType: [String: Int] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey { case latestIDsByType, seenIDsByType, retainedFromIDByType }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        latestIDsByType = try values.decodeIfPresent([String: [Int]].self, forKey: .latestIDsByType) ?? [:]
        seenIDsByType = try values.decodeIfPresent([String: [Int]].self, forKey: .seenIDsByType) ?? [:]
        retainedFromIDByType = try values.decodeIfPresent([String: Int].self, forKey: .retainedFromIDByType) ?? [:]
    }

    /// 各分类保留最近的已读 ID；保留边界之前的消息归为历史已读。
    public func compacted() -> Self {
        var result = self
        for (type, ids) in seenIDsByType {
            let floor = retainedFromIDByType[type] ?? Int.min
            let ordered = Set(ids).filter { $0 >= floor }.sorted()
            let retained = Array(ordered.suffix(Self.maximumHistoryIDsPerType))
            result.seenIDsByType[type] = retained
            if ordered.count > retained.count, let first = retained.first {
                result.retainedFromIDByType[type] = first
            }
        }
        for (type, ids) in latestIDsByType {
            let floor = result.retainedFromIDByType[type] ?? Int.min
            result.latestIDsByType[type] = Array(Set(ids).filter { $0 >= floor }.sorted().suffix(Self.maximumHistoryIDsPerType))
        }
        return result
    }

    /// 已读记录按分类取并集，历史边界取较新值，候选消息由本机响应维护。
    public func mergingReadState(_ other: Self) -> Self {
        var merged = self
        merged.retainedFromIDByType.merge(other.retainedFromIDByType, uniquingKeysWith: max)
        for (type, ids) in other.seenIDsByType {
            merged.seenIDsByType[type] = Array(Set(merged.seenIDsByType[type] ?? []).union(ids)).sorted()
        }
        return merged.compacted()
    }
}

@MainActor
public protocol GalleryMessageReadStoring: AnyObject {
    var currentSession: AppStorageSession { get }
    /// 本地保存和外部导入发布同一实例的账号变更。
    var changes: AnyPublisher<AppStorageSession, Never> { get }
    func replaceLatestIDs(_ ids: [Int], unreadCount: Int, for type: GalleryMessageType)
    func markSeen(ids: [Int], for type: GalleryMessageType)
    func unreadCount(for type: GalleryMessageType) -> Int
    func isUnread(id: Int, for type: GalleryMessageType) -> Bool
}
