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
        let routeComponents: [String]

        if scheme == "https" {
            guard url.host?.lowercased() == "open.aihelpme.dev" else { return nil }
            routeComponents = pathComponents
        } else {
            guard scheme == "bit101" else { return nil }
            if let host = url.host, !host.isEmpty {
                routeComponents = [host] + pathComponents
            } else {
                routeComponents = pathComponents
            }
        }

        guard let routeHead = routeComponents.first?.lowercased() else { return nil }

        switch routeHead {
        case "schedule" where routeComponents.count == 2 && routeComponents[1].lowercased() == "courses":
            self = .scheduleCourses
        case "paper":
            guard routeComponents.count == 2, let id = positiveID(from: routeComponents[1]) else { return nil }
            self = .paper(id)
        case "gallery":
            guard routeComponents.count == 2, let id = positiveID(from: routeComponents[1]) else { return nil }
            self = .gallery(id)
        case "course":
            guard routeComponents.count == 2, let id = positiveID(from: routeComponents[1]) else { return nil }
            self = .course(id)
        default:
            return nil
        }
    }

    private static func positiveID(from component: String) -> Int? {
        guard let id = Int(component), id > 0 else { return nil }
        return id
    }
}

/// 暂存等待登录状态恢复后处理的 URL，由调用方负责消费。
@MainActor
final class AppDeepLinkCoordinator: ObservableObject {
    static let shared = AppDeepLinkCoordinator()

    @Published private(set) var pendingURL: URL?

    private init() {}

    func receive(_ url: URL) {
        guard AppDeepLinkRoute(url: url) != nil else { return }
        pendingURL = url
    }

    func consume(_ url: URL) {
        guard pendingURL == url else { return }
        pendingURL = nil
    }
}
