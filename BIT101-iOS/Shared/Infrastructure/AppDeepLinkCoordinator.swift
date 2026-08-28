import Combine
import Foundation

enum AppDeepLinkRoute: Equatable {
    case scheduleCourses
    case paper(Int)
    case gallery(Int)
    case course(Int)

    nonisolated init?(url: URL) {
        let scheme = url.scheme?.lowercased()
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        let routeHead: String
        let routeTail: String?

        if scheme == "https" || scheme == "http" {
            guard url.host?.lowercased() == "open.aihelpme.dev" else { return nil }
            routeHead = pathComponents.first ?? ""
            routeTail = pathComponents.dropFirst().first
        } else {
            guard scheme == "bit101" else { return nil }
            routeHead = url.host ?? pathComponents.first ?? ""
            routeTail = url.host == nil ? pathComponents.dropFirst().first : pathComponents.first
        }

        switch routeHead {
        case "schedule" where routeTail == "courses":
            self = .scheduleCourses
        case "paper":
            guard let routeTail, let id = Int(routeTail) else { return nil }
            self = .paper(id)
        case "gallery":
            guard let routeTail, let id = Int(routeTail) else { return nil }
            self = .gallery(id)
        case "course":
            guard let routeTail, let id = Int(routeTail) else { return nil }
            self = .course(id)
        default:
            return nil
        }
    }
}

/// 保留冷启动时先于登录壳层到达的 URL，待登录状态恢复后再消费。
@MainActor
final class AppDeepLinkCoordinator: ObservableObject {
    static let shared = AppDeepLinkCoordinator()

    @Published private(set) var pendingURL: URL?

    private init() {}

    func receive(_ url: URL) {
        pendingURL = url
    }

    func consume(_ url: URL) {
        guard pendingURL == url else { return }
        pendingURL = nil
    }
}
