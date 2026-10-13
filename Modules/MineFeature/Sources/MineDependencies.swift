import CommunityCore
import Observation

/// 个人主页消费账号概览与用户资料服务。
@MainActor
@Observable
public final class MineDependencies {
    let overview: any MineOverviewServicing
    let profile: any UserProfileServicing
    let deletePoster: (Int) async throws -> Void

    public init(
        overview: any MineOverviewServicing,
        profile: any UserProfileServicing,
        deletePoster: @escaping (Int) async throws -> Void
    ) {
        self.overview = overview
        self.profile = profile
        self.deletePoster = deletePoster
    }
}
