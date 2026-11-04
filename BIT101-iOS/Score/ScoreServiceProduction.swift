import ClientCore
import Foundation
import ScoreInfrastructure
import TransportCore

/// 生产组装入口选择凭据、认证传输和敏感下载传输。
extension ScoreService {
    init(
        authenticationHTTPClient: HTTPClient = HTTPClient(
            transport: NetworkSessionPool.scoreAuthentication),
        nativeAuthenticator: any SchoolServiceAuthenticating = AppNativeSchoolAuthentication.shared,
        schoolHTTPClient: HTTPClient = HTTPClient(transport: NetworkSessionPool.schoolCAS)
    ) {
        self.init(
            credentials: AppAccountSession.storage,
            httpClient: authenticationHTTPClient,
            sensitiveHTTPClient: HTTPClient(transport: NetworkSessionPool.sensitiveDownloads),
            endpointBaseURL: AppEndpoints.bit101Login,
            nativeAuthenticator: nativeAuthenticator,
            nativeHTTPClient: schoolHTTPClient
        )
    }
}
