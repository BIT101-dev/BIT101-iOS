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
    public var latestIDsByType: [String: [Int]] = [:]
    public var seenIDsByType: [String: [Int]] = [:]

    public init() {}
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
