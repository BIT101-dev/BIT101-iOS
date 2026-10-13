import ClientCore
import Foundation
import ScoreInfrastructure
import TransportCore

/// 生产组装入口选择凭据、认证传输和敏感下载传输。
extension ScoreService {
    init(authenticationHTTPClient: HTTPClient = HTTPClient(transport: NetworkSessionPool.scoreAuthentication)) {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "BIT101BitLoginURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = configured.flatMap(URL.init(string:)) ?? AppURL.required("https://login.bit101.flwfdd.xyz")
        self.init(
            credentials: AppAccountSession.storage,
            httpClient: authenticationHTTPClient,
            sensitiveHTTPClient: HTTPClient(transport: NetworkSessionPool.sensitiveDownloads),
            endpointBaseURL: endpoint
        )
    }
}
