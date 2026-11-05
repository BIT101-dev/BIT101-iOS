import ClientCore
import Foundation
import ScheduleDomain
import SchedulePorts
import TransportCore

@MainActor
public struct ScheduleService {
    let schoolBaseURL = SchoolServiceTarget.teachingCenter.baseURL
    let webVPNSchoolBaseURL = SchoolServiceTarget.teachingCenterWebVPNURL
    let bitLoginBaseURL = AppEndpoints.bit101Login
    let schoolSSOBaseURL = AppURL.required("https://sso.bit.edu.cn")
    let lexueBaseURL = AppURL.required("https://lexue.bit.edu.cn")
    let webVPNLexueBaseURL = AppURL.required(
        """
        https://webvpn.bit.edu.cn/https/77726476706e69737468656265737421fcf25989227e6a596a468ca\
        88d1b203b
        """
    )
    let credentials: any SchoolCredentialsProviding
    let crypto: any SchoolServiceCryptoProviding
    let schoolSessionRestorer: any SchoolSessionRestoring
    let teachingCenterState: TeachingCenterSessionState
    let rawCourseResponseHandler: ((Data) -> Void)?
    let nativeAuthenticator: (any SchoolServiceAuthenticating)?
    let httpClient: HTTPClient
    static let authenticationWaitSeconds: TimeInterval = 90
    struct AuthenticationCredentials: Encodable {
        let username: String?
        let password: String?
        let challengeID: String?

        enum CodingKeys: String, CodingKey {
            case username, password
            case challengeID = "challenge_id"
        }
    }

    struct CookieResponse: Decodable {
        let data: [String: String]
    }

    /// 传输与 Cookie 容器由宿主组装，服务负责学校业务请求。
    public init(
        credentials: any SchoolCredentialsProviding,
        crypto: any SchoolServiceCryptoProviding,
        schoolSessionRestorer: any SchoolSessionRestoring,
        teachingCenterState: TeachingCenterSessionState,
        rawCourseResponseHandler: ((Data) -> Void)? = nil,
        transport: any HTTPTransport,
        observer: (any HTTPClientObserving & Sendable)? = nil,
        nativeAuthenticator: (any SchoolServiceAuthenticating)? = nil
    ) {
        self.nativeAuthenticator = nativeAuthenticator
        self.credentials = credentials
        self.crypto = crypto
        self.schoolSessionRestorer = schoolSessionRestorer
        self.teachingCenterState = teachingCenterState
        self.rawCourseResponseHandler = rawCourseResponseHandler
        httpClient = HTTPClient(transport: transport, observer: observer)
    }

}

extension ScheduleService: ScheduleServicing {}
