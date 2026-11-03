import ClientCore
import CommunityTransport
import Foundation
import ScheduleDomain
import SchedulePorts
import ScoreDomain
import ScoreInfrastructure
import Testing

@testable import BIT101_iOS
@testable import ScheduleFeature
@testable import ScheduleInfrastructure
@testable import TransportCore

extension NetworkClientTests {
    @Test("School redirects upgrade HTTPS targets and isolate cross-origin credentials")
    func schoolRedirectPolicy() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let sourceURL = try #require(URL(string: "https://sso.bit.edu.cn/cas/login"))
        let response = try #require(
            HTTPURLResponse(
                url: sourceURL,
                statusCode: 302,
                httpVersion: nil,
                headerFields: nil
            ))
        let task = session.dataTask(with: sourceURL)
        let delegate = HTTPSUpgradingRedirectDelegate()

        var sameOriginResult: URLRequest?
        var sameOriginRequest = URLRequest(
            url: try #require(URL(string: "http://sso.bit.edu.cn/cas/continue")))
        sameOriginRequest.setValue("Bearer token", forHTTPHeaderField: "Authorization")
        sameOriginRequest.setValue("challenge-token", forHTTPHeaderField: "X-Challenge-Token")
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: sameOriginRequest,
            completionHandler: { sameOriginResult = $0 }
        )
        #expect(sameOriginResult?.url?.absoluteString == "https://sso.bit.edu.cn/cas/continue")
        #expect(sameOriginResult?.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(
            sameOriginResult?.value(forHTTPHeaderField: "X-Challenge-Token") == "challenge-token")

        var manuallyHandledRedirect: URLRequest? = sameOriginRequest
        NoRedirectURLSessionDelegate().urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: sameOriginRequest,
            completionHandler: { manuallyHandledRedirect = $0 }
        )
        #expect(manuallyHandledRedirect == nil)

        var crossOriginResult: URLRequest?
        var crossOriginRequest = URLRequest(
            url: try #require(URL(string: "http://portal.example/landing")))
        crossOriginRequest.setValue("Bearer token", forHTTPHeaderField: "Authorization")
        crossOriginRequest.setValue("proxy-token", forHTTPHeaderField: "Proxy-Authorization")
        crossOriginRequest.setValue("session", forHTTPHeaderField: "Cookie")
        crossOriginRequest.setValue("community-session", forHTTPHeaderField: "fake-cookie")
        crossOriginRequest.setValue("challenge-token", forHTTPHeaderField: "x-challenge-token")
        crossOriginRequest.httpBody = Data("sensitive-body".utf8)
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: crossOriginRequest,
            completionHandler: { crossOriginResult = $0 }
        )
        #expect(crossOriginResult?.url?.absoluteString == "https://portal.example/landing")
        #expect(crossOriginResult?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(crossOriginResult?.value(forHTTPHeaderField: "Proxy-Authorization") == nil)
        #expect(crossOriginResult?.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(crossOriginResult?.value(forHTTPHeaderField: "fake-cookie") == nil)
        #expect(crossOriginResult?.value(forHTTPHeaderField: "X-Challenge-Token") == nil)
        #expect(crossOriginResult?.httpBody == nil)

        var crossOriginPostResult: URLRequest? = crossOriginRequest
        crossOriginRequest.httpMethod = "POST"
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: crossOriginRequest,
            completionHandler: { crossOriginPostResult = $0 }
        )
        #expect(crossOriginPostResult == nil)
    }

    @Test("bit-login challenge protocol is shared by school services")
    func sharedBITLoginChallengeProtocol() throws {
        let data = Data(
            #"""
            {"challenge_id":"challenge-1","access_token":"token","status":"waiting_sms","maske\#
            d_phone":"138****0000","expires_in":120}
            """#
            .utf8
        )
        let payload = try BITLoginChallengeSupport.decodePayload(from: data)
        let challenge = BITLoginChallengeSupport.challenge(from: payload, accessToken: "token")

        #expect(challenge.challengeID == "challenge-1")
        #expect(challenge.status == "waiting_sms")
        #expect(challenge.maskedPhone == "138****0000")
        #expect(
            BITLoginChallengeSupport.errorMessage(
                from: Data(#"{"detail":{"error":"验证码错误"}}"#.utf8)
            ) == "验证码错误"
        )
    }

    @Test("Schedule JSON requests preserve HTTPS and form contracts", .timeLimit(.minutes(1)))
    func scheduleJSONRequestContract() async throws {
        let transport = MockHTTPTransport { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.absoluteString == "https://school.example/api/courses.do")
            #expect(
                request.value(forHTTPHeaderField: "Accept")
                    == "application/json, text/javascript, */*; q=0.01")
            #expect(request.value(forHTTPHeaderField: "X-Requested-With") == "XMLHttpRequest")
            #expect(
                request.value(forHTTPHeaderField: "Content-Type")
                    == "application/x-www-form-urlencoded; charset=utf-8")
            let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
            #expect(body == "term=2025-2026-1&search=software%20%26%20engineering")

            let requestURL = try #require(request.url)
            let response = try #require(
                HTTPURLResponse(
                    url: requestURL,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
            return (Data(#"{"accepted":true}"#.utf8), response)
        }
        let service = ScheduleServiceFactory.make(transport: transport)
        let payload: SchoolProbePayload = try await service.sendJSONRequest(
            baseURL: try makeTestURL("http://school.example"),
            path: "/api/courses.do",
            method: "POST",
            body: [("term", "2025-2026-1"), ("search", "software & engineering")]
        )

        #expect(payload.accepted)
    }

    @Test(
        "Schedule service returns school business errors from nested envelopes",
        .timeLimit(.minutes(1)))
    func scheduleBusinessErrorContract() async throws {
        let transport = MockHTTPTransport { request in
            let requestURL = try #require(request.url)
            let response = try #require(
                HTTPURLResponse(
                    url: requestURL,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
            let data = Data(
                #"{"datas":{"cxxszhxqkb":{"extParams":{"code":3,"msg":"此学年学期的课表未发布"},"rows":[]}}}"#
                    .utf8)
            return (data, response)
        }
        let service = ScheduleServiceFactory.make(transport: transport)

        do {
            let _: SchoolProbePayload = try await service.sendJSONRequest(
                baseURL: try makeTestURL("https://school.example"),
                path: "/api/courses.do"
            )
            Issue.record("Expected a school business error")
        } catch ScheduleServiceError.schoolResponse(let message) {
            #expect(message == "此学年学期的课表未发布")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(
        "Schedule SMS continuation sends the challenge contract and preserves its state",
        .timeLimit(.minutes(1)))
    func scheduleSMSChallengeContract() async throws {
        let transport = MockHTTPTransport { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/api/auth/challenge-1/sms")
            #expect(request.value(forHTTPHeaderField: "X-Challenge-Token") == "access-token")
            let body = try #require(request.httpBody)
            let payload = try #require(
                JSONSerialization.jsonObject(with: body) as? [String: String])
            #expect(payload == ["code": "123456"])

            let requestURL = try #require(request.url)
            let response = try #require(
                HTTPURLResponse(
                    url: requestURL,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
            let data = Data(
                #"""
                {"challenge_id":"challenge-1","access_token":"access-token","status":"waiting_\#
                sms","masked_phone":"138****0000","expires_in":120}
                """#
                .utf8
            )
            return (data, response)
        }
        let service = ScheduleServiceFactory.make(transport: transport)
        let challenge = BITLoginAuthenticationChallenge(
            challengeID: "challenge-1",
            accessToken: "access-token",
            status: "waiting_sms",
            maskedPhone: "138****0000",
            expiresIn: 120,
            ownerIdentity: service.credentials.schoolSessionIdentity
        )

        do {
            try await service.submitTeachingCode("123456", for: challenge)
            Issue.record("Expected the server to keep the challenge in its SMS state")
        } catch ScheduleServiceError.secondFactorRequired(let updatedChallenge) {
            #expect(updatedChallenge.challengeID == challenge.challengeID)
            #expect(updatedChallenge.accessToken == challenge.accessToken)
            #expect(updatedChallenge.maskedPhone == challenge.maskedPhone)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(
        "Expired SMS challenge responses preserve challenge invalidation", .timeLimit(.minutes(1)))
    func scheduleExpiredSMSChallengeContract() async throws {
        let transport = MockHTTPTransport { request in
            #expect(request.url?.path == "/api/auth/challenge-1/sms")
            let requestURL = try #require(request.url)
            let response = try #require(
                HTTPURLResponse(
                    url: requestURL,
                    statusCode: 409,
                    httpVersion: nil,
                    headerFields: nil
                ))
            return (Data(#"{"message":"challenge expired"}"#.utf8), response)
        }
        let service = ScheduleServiceFactory.make(transport: transport)
        let challenge = BITLoginAuthenticationChallenge(
            challengeID: "challenge-1",
            accessToken: "access-token",
            status: "waiting_sms",
            maskedPhone: "138****0000",
            expiresIn: 120,
            ownerIdentity: service.credentials.schoolSessionIdentity
        )

        do {
            try await service.submitTeachingCode("123456", for: challenge)
            Issue.record("Expected the expired challenge to be rejected")
        } catch ScheduleServiceError.challengeInvalid(let message) {
            #expect(message.contains("challenge expired"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Network smoke scopes include exactly their typed probe areas")
    func networkSmokeScopeAreaMatrix() {
        let all = Set(NetworkSmokeArea.allCases)
        let expectations: [(NetworkSmokeScope, Set<NetworkSmokeArea>)] = [
            (.all, all.subtracting([.communityWrites, .communityWriteImages])),
            (.bit101, [.authentication, .bit101]),
            (.school, [.schedule, .ddl, .school, .transcript]),
            (.transcript, [.transcript]),
            (.schedule, [.schedule]),
            (.ddl, [.ddl]),
            (.communityWrites, [.authentication, .communityWrites, .communityWriteImages]),
            (.communityCleanup, [.authentication, .communityWrites]),
        ]

        for (scope, includedAreas) in expectations {
            for area in NetworkSmokeArea.allCases {
                #expect(scope.includes(area) == includedAreas.contains(area))
            }
        }
    }

    @Test("Smoke report separates service health from coverage completeness")
    func networkSmokeCoverageStatus() {
        let startedAt = Date()
        func makeReport(coverageGaps: [String]) -> ReleaseNetworkSmokeReport {
            ReleaseNetworkSmokeReport(
                runID: "test-run",
                scope: .all,
                startedAt: startedAt,
                finishedAt: startedAt,
                passed: true,
                failures: [],
                authenticationBlockers: [],
                scheduleCache: nil,
                executedProbes: NetworkSmokeScope.all.requiredProbes,
                skippedProbes: coverageGaps,
                coverageGaps: coverageGaps,
                schoolSMSCoverage: "not_run"
            )
        }

        let complete = makeReport(coverageGaps: [])
        let partial = makeReport(coverageGaps: ["详情探针（列表为空）"])
        #expect(complete.passed)
        #expect(complete.coverageComplete)
        #expect(partial.passed)
        #expect(!partial.coverageComplete)
    }

    @Test(
        "Every smoke scope requires its complete probe inventory",
        arguments: NetworkSmokeScope.allCases)
    func networkSmokeRequiredProbeInventory(_ scope: NetworkSmokeScope) {
        let required = scope.requiredProbes
        let firstID =
            switch scope {
            case .all, .bit101, .communityWrites, .communityCleanup: "community.login"
            case .school, .schedule: "schedule.current-term"
            case .transcript: "score.transcript"
            case .ddl: "eclass.authentication"
            }
        #expect(required.first == firstID)
        #expect(Set(required).count == required.count)
        let now = Date()
        func report(executed: [String]) -> ReleaseNetworkSmokeReport {
            ReleaseNetworkSmokeReport(
                runID: "inventory-test", scope: scope, startedAt: now, finishedAt: now,
                passed: true, failures: [], authenticationBlockers: [], scheduleCache: nil,
                executedProbes: executed, skippedProbes: [], coverageGaps: [],
                schoolSMSCoverage: "not_run"
            )
        }
        #expect(report(executed: required).coverageComplete)
        #expect(!report(executed: []).coverageComplete)
        for name in required {
            let incomplete = report(executed: required.filter { $0 != name } + ["unrelated probe"])
            #expect(!incomplete.coverageComplete)
            #expect(incomplete.missingRequiredProbes == [name])
        }
    }
}
