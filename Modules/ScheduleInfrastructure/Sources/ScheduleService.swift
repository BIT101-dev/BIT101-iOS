import SchedulePorts
import TransportCore
import ClientCore
import ScheduleDomain
//
//  ScheduleService.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Foundation

public struct ScheduleService {
    let schoolBaseURL = AppURL.required("https://jxzxehallapp.bit.edu.cn")
    let webVPNSchoolBaseURL = AppURL.required("https://webvpn.bit.edu.cn/https/77726476706e69737468656265737421faef5b842238695c720999bcd6572a216b231105adc27d")
    let bitLoginBaseURL = AppURL.required("https://login.bit101.flwfdd.xyz")
    let schoolSSOBaseURL = AppURL.required("https://sso.bit.edu.cn")
    let lexueBaseURL = AppURL.required("https://lexue.bit.edu.cn")
    let webVPNLexueBaseURL = AppURL.required("https://webvpn.bit.edu.cn/https/77726476706e69737468656265737421fcf25989227e6a596a468ca88d1b203b")
    let credentials: any SchoolCredentialsProviding
    let crypto: any SchoolServiceCryptoProviding
    let schoolSessionRestorer: any SchoolSessionRestoring
    let teachingCenterState: TeachingCenterSessionState
    let rawCourseResponseHandler: ((Data) -> Void)?
    let session: URLSession
    let transportOverride: (any HTTPTransport)?
    private let redirectDelegate = HTTPSUpgradingRedirectDelegate()
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

    /// 构造带共享 cookie 与 HTTPS 升级能力的会话；传入传输层用于离线契约测试。
    public init(
        credentials: any SchoolCredentialsProviding,
        crypto: any SchoolServiceCryptoProviding,
        schoolSessionRestorer: any SchoolSessionRestoring,
        teachingCenterState: TeachingCenterSessionState,
        rawCourseResponseHandler: ((Data) -> Void)? = nil,
        transport: (any HTTPTransport)? = nil
    ) {
        self.credentials = credentials
        self.crypto = crypto
        self.schoolSessionRestorer = schoolSessionRestorer
        self.teachingCenterState = teachingCenterState
        self.rawCourseResponseHandler = rawCourseResponseHandler
        transportOverride = transport
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpCookieStorage = teachingCenterState.cookieStorage
        // 教学中心提供校外 WebVPN 与校园网直连两条链路。配置关闭连接等待，让当前网络
        // 未解析主机及时返回 DNS 错误，直连回退继续执行。
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }

}

extension ScheduleService: ScheduleServicing {}
