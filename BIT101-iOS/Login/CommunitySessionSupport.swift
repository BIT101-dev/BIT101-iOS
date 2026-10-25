import TransportCore
import CommunityTransport
import Foundation

/// 应用认证适配将账号身份与凭据恢复交给社区会话契约。
extension CommunityAPIClient {
    init(
        storage: LoginStorage = AppAccountSession.storage,
        httpClient: HTTPClient? = nil,
        baseURL: URL = AppURL.required("https://bit101.flwfdd.xyz"),
        errorDomain: String
    ) {
        let selectedClient = httpClient ?? HTTPClient(transport: NetworkSessionPool.community, storage: storage)
        let login = LoginService(storage: storage, apiClient: BIT101APIClient(
            httpClient: selectedClient, noRedirectHTTPClient: selectedClient))
        self.init(
            httpClient: selectedClient,
            baseURL: baseURL,
            errorDomain: errorDomain,
            credentials: { storage.communityCredentials },
            refreshHandler: { observed in
                try await login.renewCommunitySession(observed: observed)
            }, backgroundRefresh: { login.startCommunitySessionRecovery(observed: $0) }
        )
    }
}

extension CommunitySession {
    static func appSession(storage: LoginStorage = AppAccountSession.storage, httpClient: HTTPClient? = nil) -> CommunitySession {
        let selectedClient = httpClient ?? HTTPClient(transport: NetworkSessionPool.community, storage: storage)
        let login = LoginService(storage: storage, apiClient: BIT101APIClient(
            httpClient: selectedClient, noRedirectHTTPClient: selectedClient))
        return CommunitySession(
            httpClient: selectedClient,
            baseURL: AppURL.required("https://bit101.flwfdd.xyz"),
            credentials: { storage.communityCredentials },
            refresh: { observed in
                try await login.renewCommunitySession(observed: observed)
            },
            credentialsChanges: storage.credentialsChanges,
            backgroundRefresh: { login.startCommunitySessionRecovery(observed: $0) }
        )
    }
}
