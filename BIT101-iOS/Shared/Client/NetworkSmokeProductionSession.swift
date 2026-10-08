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
    static func run() async throws {
        let identity = AppAccountSession.storage.communityCredentials.identity
        let client = HTTPClient(transport: NetworkSessionPool.productionCommunity)
        let mine = MineService(httpClient: client)
        let first = try await mine.fetchMyInfo()
        let restored = try await MineService(httpClient: client).fetchMyInfo()
        guard first.own, restored.own, first.user.id == restored.user.id,
              identity == AppAccountSession.storage.communityCredentials.identity else { throw URLError(.cannotParseResponse) }
    }

    static func school() -> ScheduleService {
        let state = AppSchoolSession.teachingCenter
        let api = BIT101APIClient(
            httpClient: HTTPClient(transport: NetworkSessionPool.productionSchoolCAS),
            noRedirectHTTPClient: HTTPClient(transport: NetworkSessionPool.productionSchoolCASManualRedirects))
        return ScheduleService(credentials: AppAccountSession.storage, crypto: AppScheduleServiceCrypto(),
            schoolSessionRestorer: AppScheduleSchoolSessionRestorer { try await LoginService(apiClient: api).restoreSchoolSessionIfNeeded() },
            teachingCenterState: state, rawCourseResponseHandler: nil,
            transport: NetworkSessionPool.productionTeachingCenter, observer: HTTPClient.appObserver)
    }
}
#endif
