import CommunityCore
import Observation
import SwiftUI

/// 跨社区页面的目标工厂，由应用壳层组装并沿视图环境传递。
@MainActor
@Observable
final class CommunityDestinations {
    let deletePoster: (Int) async throws -> Void
    let profile: (Int) -> AnyView
    let poster: (CommunityPoster, (() -> Void)?) -> AnyView
    let papers: (Binding<Int?>, Binding<String>) -> AnyView

    init(
        deletePoster: @escaping (Int) async throws -> Void,
        profile: @escaping (Int) -> AnyView,
        poster: @escaping (CommunityPoster, (() -> Void)?) -> AnyView,
        papers: @escaping (Binding<Int?>, Binding<String>) -> AnyView
    ) {
        self.deletePoster = deletePoster
        self.profile = profile
        self.poster = poster
        self.papers = papers
    }
}
