import CommunityCore
import CommunityTransport
import Observation

/// 个人主页消费账号概览与用户资料服务。
@MainActor
@Observable
public final class MineDependencies {
    let overview: any MineOverviewServicing
    let profile: any UserProfileServicing
    let deletePoster: (Int) async throws -> Void
    let isRunningUITest: Bool

    public init(
        overview: any MineOverviewServicing,
        profile: any UserProfileServicing,
        deletePoster: @escaping (Int) async throws -> Void,
        isRunningUITest: Bool
    ) {
        self.overview = overview
        self.profile = profile
        self.deletePoster = deletePoster
        self.isRunningUITest = isRunningUITest
    }
}
