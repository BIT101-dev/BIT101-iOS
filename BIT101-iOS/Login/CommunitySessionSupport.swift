import TransportCore
import CommunityTransport
import Foundation

/// 应用认证适配将账号身份与凭据恢复交给社区会话契约。
extension CommunityAPIClient {
    init(
        storage: LoginStorage = .shared,
        httpClient: HTTPClient = .community,
        baseURL: URL = AppURL.required("https://bit101.flwfdd.xyz"),
        errorDomain: String
    ) {
        let coordinator = CommunitySessionRefreshCoordinator()
        self.init(
            httpClient: httpClient,
            baseURL: baseURL,
            errorDomain: errorDomain,
            credentials: { storage.communityCredentials },
            refreshHandler: { observed in
                try await coordinator.refresh(observed: observed, current: { storage.communityCredentials }) {
                    try await LoginService(storage: storage).renewCommunitySession(expectedIdentity: observed.identity)
                }
            }
        )
    }
}

extension CommunitySession {
    static func appSession(storage: LoginStorage = .shared, httpClient: HTTPClient = .community) -> CommunitySession {
        let coordinator = CommunitySessionRefreshCoordinator()
        return CommunitySession(
            httpClient: httpClient,
            baseURL: AppURL.required("https://bit101.flwfdd.xyz"),
            credentials: { storage.communityCredentials },
            refresh: { observed in
                try await coordinator.refresh(observed: observed, current: { storage.communityCredentials }) {
                    try await LoginService(storage: storage).renewCommunitySession(expectedIdentity: observed.identity)
                }
            }
        )
    }
}
