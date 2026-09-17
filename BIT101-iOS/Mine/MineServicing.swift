import Foundation

protocol MineOverviewServicing {
    func fetchMyInfo() async throws -> MineUserInfo
    func fetchFollowers(page: Int) async throws -> [GalleryUser]
    func fetchFollowings(page: Int) async throws -> [GalleryUser]
    func fetchMyPosters(page: Int) async throws -> [GalleryPoster]
}

protocol UserProfileServicing {
    func fetchUserInfo(id: Int) async throws -> MineUserInfo
    func fetchUserPosters(userID: Int, page: Int) async throws -> [GalleryPoster]
    func followUser(id: Int) async throws -> MineFollowResult
}

extension MineService: MineOverviewServicing, UserProfileServicing {}
