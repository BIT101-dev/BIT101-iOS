import Foundation
import ClientCore
import CommunityTransport
import CommunityCore
import MineFeature
import ScheduleInfrastructure
import TransportCore

#if DEBUG || RELEASE_NETWORK_SMOKE
@MainActor
enum NetworkSmokeProductionSession {
    static func run() async throws -> [String] {
        let original = AppAccountSession.storage.communityCredentials
        var selected = original
        let client = HTTPClient(transport: NetworkSessionPool.productionCommunity)
        let session = CommunitySession(httpClient: client, baseURL: AppURL.required("https://bit101.flwfdd.xyz"),
            credentials: { selected }, refresh: { _ in throw MineServiceError.notLoggedIn })
        let mine = MineService(session: session, preferences: { AppCommunityDependencies.preferenceSnapshot })
        let first = try await mine.fetchMyInfo()
        guard first.own, first.user.id > 0 else { throw URLError(.cannotParseResponse) }
        var evidence = ["初始账号资料 ID：\(first.user.id)"]
        selected = CommunityCredentials(identity: .init(accountIdentifier: "community-smoke-invalid", generation: 1),
            cookie: "bit101-smoke-invalid-session")
        do {
            _ = try await mine.fetchMyInfo()
            throw URLError(.userAuthenticationRequired)
        } catch MineServiceError.notLoggedIn { evidence.append("无效凭据切换：认证拒绝") }
        selected = CommunityCredentials(identity: .init(accountIdentifier: original.identity.accountIdentifier, generation: 2),
            cookie: original.cookie)
        let restored = try await MineService(session: session, preferences: { AppCommunityDependencies.preferenceSnapshot }).fetchMyInfo()
        guard restored.own, first.user.id == restored.user.id,
              original.identity == AppAccountSession.storage.communityCredentials.identity else { throw URLError(.cannotParseResponse) }
        evidence.append("恢复账号资料 ID：\(restored.user.id)")
        return evidence
    }

    static func school() -> ScheduleService {
        let state = AppSchoolSession.teachingCenter
        let api = BIT101APIClient(
            httpClient: HTTPClient(transport: NetworkSessionPool.productionSchoolCAS),
            noRedirectHTTPClient: HTTPClient(transport: NetworkSessionPool.productionSchoolCASManualRedirects))
        return ScheduleService(credentials: AppAccountSession.storage, crypto: AppScheduleServiceCrypto(),
            schoolSessionRestorer: AppScheduleSchoolSessionRestorer { try await LoginService(storage: AppAccountSession.storage, apiClient: api).restoreSchoolSessionIfNeeded() },
            teachingCenterState: state, rawCourseResponseHandler: nil,
            transport: NetworkSessionPool.productionTeachingCenter, observer: HTTPClient.appObserver)
    }
}
#endif
