import CommunityCore
import Foundation

public protocol MineOverviewServicing {
    func fetchMyInfo() async throws -> MineUserInfo
    func fetchFollowers(page: Int) async throws -> [CommunityUser]
    func fetchFollowings(page: Int) async throws -> [CommunityUser]
    func fetchMyPosters(page: Int) async throws -> [CommunityPoster]
}

public protocol UserProfileServicing {
    func fetchUserInfo(id: Int) async throws -> MineUserInfo
    func fetchUserPosters(userID: Int, page: Int) async throws -> [CommunityPoster]
    func followUser(id: Int) async throws -> MineFollowResult
}

extension MineService: MineOverviewServicing, UserProfileServicing {}

