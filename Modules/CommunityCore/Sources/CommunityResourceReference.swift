import Foundation

/// 社区资源统一使用种类与正整数标识解析消息和收藏目标。
public nonisolated struct CommunityResourceReference: Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case poster, paper, course

        public var title: String {
            switch self {
            case .poster: "帖子"
            case .paper: "文章"
            case .course: "课程"
            }
        }
    }

    public let kind: Kind
    public let id: Int

    public init?(objectID: String) {
        for kind in Kind.allCases where objectID.hasPrefix(kind.rawValue) {
            let suffix = String(objectID.dropFirst(kind.rawValue.count))
            guard let id = Int(suffix), id > 0 else { return nil }
            self.kind = kind
            self.id = id
            return
        }
        return nil
    }
}
