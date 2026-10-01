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

@MainActor
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
        observer: (any HTTPClientObserving & Sendable)? = nil
    ) {
        self.credentials = credentials
        self.crypto = crypto
        self.schoolSessionRestorer = schoolSessionRestorer
        self.teachingCenterState = teachingCenterState
        self.rawCourseResponseHandler = rawCourseResponseHandler
        httpClient = HTTPClient(transport: transport, observer: observer)
    }

}

extension ScheduleService: ScheduleServicing {}
