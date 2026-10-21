import SchedulePorts
import GalleryFeature
import CommunityCore
import PaperFeature
import CommunityTransport
import ScoreDomain
import ScorePorts
@testable import ScheduleFeature
@testable import ScheduleInfrastructure
@testable import ScoreFeature
@testable import MapFeature
import ClientCore
import TransportCore
import DesignSystemKit
import ScheduleDomain
import XCTest
import Testing
import UIKit
import SwiftUI
import CoreLocation
@testable import BIT101_iOS
@MainActor
struct NetworkEvidenceProjectionTests {
#if DEBUG || RELEASE_NETWORK_SMOKE
    @Test func feedbackSmokeRequiresEveryCleanupAndQuotaReceiptField() throws {
        let fields = ["ok", "recordVerified", "temporaryRecordRemoved", "quotaReserved"]
        let valid = Dictionary(uniqueKeysWithValues: fields.map { ($0, true) })
        try FeedbackSubmissionClient.validateNetworkSmokeResponse(JSONEncoder().encode(valid))
        for field in fields {
            var missing = valid
            missing.removeValue(forKey: field)
            do {
                try FeedbackSubmissionClient.validateNetworkSmokeResponse(JSONEncoder().encode(missing))
                Issue.record("响应需要全部验收字段。")
            } catch { #expect(error.localizedDescription.contains(field)) }
            var rejected = valid
            rejected[field] = false
            #expect(throws: (any Error).self) { try FeedbackSubmissionClient.validateNetworkSmokeResponse(JSONEncoder().encode(rejected)) }
        }
    }
#endif

    @Test func communityConfigurationUsesTheCurrentAccountAndExistingObjects() throws {
        let request = try JSONDecoder().decode(ReleaseNetworkSmokeLaunchRequest.self,
            from: Data(#"{"scope":"bit101","runID":"configuration","capture":"communityFixtures"}"#.utf8))
        #expect(request.scope == .bit101 && request.capture == .communityFixtures)
        let value = NetworkSmokeCommunityConfiguration(accountID: 7, followTarget: 8,
            fixtures: .init(posterID: 41, courseID: 43, courseNumber: "CS-001", paperID: 42))
        let restored = try JSONDecoder().decode(NetworkSmokeCommunityConfiguration.self, from: JSONEncoder().encode(value))
        #expect(restored.accountID == 7 && restored.followTarget == 8 && restored.fixtures.isValid)
    }

    @Test func schoolBusinessSelectorsRemainVisibleInRequestEvidence() throws {
        var request = URLRequest(url: AppURL.required("https://example.invalid/classrooms?dicCode=48682&SFSY=1&GPA=1&appName=wdkbby&EMAP_LANG=zh&token=secret"))
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("XNXQDM=2025-2026-1&JXLDM=building&RQ=2026-09-07&XQDM=1&XNDM=2025-2026&password=secret".utf8)
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let evidence = NetworkSmokeHTTPRequestEvidence(request: request, response: response)
        #expect(evidence.query == ["dicCode": "48682", "SFSY": "1", "GPA": "1", "appName": "wdkbby", "EMAP_LANG": "zh", "token": "[REDACTED]",
                                  "XNXQDM": "2025-2026-1", "JXLDM": "building", "RQ": "2026-09-07", "XQDM": "1", "XNDM": "2025-2026"])
        #expect(evidence.finalQuery == evidence.query)
    }

    @Test("Probe identities stay separate from display labels")
    func probeIdentitiesUseCanonicalMachineValues() throws {
        let identities = NetworkSmokeProbe.allCases.map(\.rawValue)
        #expect(Set(identities).count == identities.count)
        #expect(identities.allSatisfy { $0.utf8.allSatisfy { $0 < 128 } })
        #expect(Set(identities) == Set(NetworkSmokeScope.all.requiredProbes + NetworkSmokeScope.communityWrites.requiredProbes))
        #expect(NetworkSmokeProbe.galleryNewest.rawValue == "gallery.newest")
        #expect(NetworkSmokeProbe.galleryNewest.displayName == "话廊最新列表")
        #expect(GalleryMessageType.allCases.map(NetworkSmokeProbe.message).map(\.rawValue) ==
            ["message.comment", "message.like", "message.follow", "message.subscription", "message.system"])
        #expect(PaperSortOrder.allCases.map(NetworkSmokeProbe.paperSort).map(\.rawValue) ==
            ["paper.list.newest", "paper.list.like", "paper.list.comment"])
    }

    @Test func businessProjectionKeepsTransportMetadataIndependent() throws {
        var request = URLRequest(url: AppURL.required("https://example.invalid/grades?token=secret"))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"detail":true,"password":"secret"}"#.utf8)
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let projection = NetworkSmokeHTTPRequestEvidence(request: request, response: response)
        #expect(projection.query == ["detail": "true", "token": "[REDACTED]"])
        let encoded = try JSONEncoder().encode(projection)
        #expect(try JSONDecoder().decode(NetworkSmokeHTTPRequestEvidence.self, from: encoded).query == projection.query)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("secret"))
        let metadata = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(HTTPRequestEvidence(request: request, response: response))) as? [String: Any])
        #expect(metadata["query"] == nil && metadata["responseCourseIDs"] == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["form", "json", "query"])
    func finalPostParametersComeFromTheFinalRequest(format: String) async throws {
        let url = AppURL.required("https://example.invalid/submit" + (format == "query" ? "?obj=paper1" : ""))
        var request = URLRequest(url: url); request.httpMethod = "POST"
        var finalRequest = request
        let contentType = format == "form" ? "application/x-www-form-urlencoded" : "application/json"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        finalRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = Data((format == "form" ? "XNXQDM=initial&password=secret" : #"{"obj":"paper1","password":"secret"}"#).utf8)
        finalRequest.httpBody = Data((format == "form" ? "XNXQDM=final&password=private" : #"{"obj":"paper2","password":"private"}"#).utf8)
        if format == "query" {
            request.httpBody = nil; finalRequest.httpBody = nil
            finalRequest.url = AppURL.required("https://example.invalid/submit?obj=paper2")
        }
        let finalURL = try #require(finalRequest.url)
        let response = try #require(HTTPURLResponse(url: finalURL, statusCode: 200, httpVersion: nil, headerFields: nil))
        let transport = FinalRequestTransport(base: StubTransport(result: .success((Data(), response))), finalRequest: finalRequest)
        var captured: NetworkSmokeHTTPRequestEvidence?
        try await HTTPRequestEvidenceContext.$didReceive.withValue({ request, response in captured = await NetworkSmokeHTTPRequestEvidence.capture(request: request, response: response.response, body: response.data, finalRequest: response.finalRequest) }) {
            _ = try await HTTPClient(transport: ForwardingTransport(base: transport), observer: nil).send(request)
        }
        let evidence = try #require(captured)
        #expect(evidence.finalMethod == "POST")
        let key = format == "form" ? "XNXQDM" : "obj"
        #expect(evidence.query[key] == (format == "form" ? "initial" : "paper1"))
        #expect(evidence.finalQuery[key] == (format == "form" ? "final" : "paper2"))
        let encoded = String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self)
        #expect(!encoded.contains("secret") && !encoded.contains("private"))
    }
    @Test(.timeLimit(.minutes(1)), arguments: [("[]", String?.some("0")), (#"[{"id":3,"text":"secret"},{"id":9,"text":"private"}]"#, .some("3")),
        ("{}", nil), ("invalid", nil)], ["poster1", "comment2", "private"])
    func requestEvidenceRecordsObjectsAndResponseCursorsWithRedactedContent(fixture: (String, String?), object: String) async throws {
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let client = HTTPClient(transport: StubTransport(result: .success((Data(fixture.0.utf8), response))), observer: nil)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["obj": object, "text": "secret", "password": "private"])
        var captured: NetworkSmokeHTTPRequestEvidence?
        try await HTTPRequestEvidenceContext.$didReceive.withValue({ request, response in captured = await NetworkSmokeHTTPRequestEvidence.capture(request: request, response: response.response, body: response.data, finalRequest: response.finalRequest) }) { _ = try await client.send(request) }
        let evidence = try #require(captured)
        #expect(evidence.responseMinimumID == fixture.1)
        #expect(evidence.query == ["obj": object == "private" ? "[REDACTED]" : object])
        let encoded = String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self)
        #expect(!encoded.contains("secret") && !encoded.contains("private"))
    }

    @Test(arguments: ["0", "99"], ["query", "form", "redirect", "sensitive-form", "query-json-sensitive"])
    func requestEvidencePreservesParameterAmbiguity(value: String, location: String) throws {
        let url = AppURL.required("https://example.invalid/probe?page=0&token=secret")
        var request = URLRequest(url: url)
        if location == "query" { request.url = AppURL.required(url.absoluteString + "&page=\(value)&token=secret") }
        if location == "form" {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("XNXQDM=0&XNXQDM=\(value)&password=secret".utf8)
        }
        if location == "sensitive-form" {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("password=secret&password=\(value)".utf8)
        }
        if location == "query-json-sensitive" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(#"{"token":"secret"}"#.utf8)
        }
        var finalRequest = request
        if location == "redirect" { finalRequest.url = AppURL.required(url.absoluteString + "&page=\(value)") }
        let finalURL = try #require(finalRequest.url)
        let response = try #require(HTTPURLResponse(url: finalURL, statusCode: 200, httpVersion: nil, headerFields: nil))
        let evidence = NetworkSmokeHTTPRequestEvidence(request: request, response: response, finalRequest: finalRequest)
        let key = location == "form" ? "XNXQDM" : location == "sensitive-form" ? "password" : location == "query-json-sensitive" ? "token" : "page"
        let ambiguous = location == "query" ? [key, "token"] : [key]
        #expect(evidence.ambiguousParameters == (location == "redirect" ? nil : ambiguous))
        #expect(evidence.finalAmbiguousParameters == ambiguous && evidence.finalQuery[key] == nil)
        let encoded = try JSONEncoder().encode(evidence)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("secret"))
        #expect(try JSONDecoder().decode(NetworkSmokeHTTPRequestEvidence.self, from: encoded).finalAmbiguousParameters == ambiguous)
    }

    @Test func requestEvidencePreservesBusinessSelectorsAndRedactsFormCredentials() throws {
        let url = AppURL.required("https://example.invalid/probe?search=BIT101&hide_bot=true&XXXQDM=campus&token=secret")
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("XNXQDM=2025-2026-1&JXLDM=B%2B%26+Room&password=secret".utf8)
        let evidence = NetworkSmokeHTTPRequestEvidence(request: request, response: response)
        #expect(evidence.query == ["search": "BIT101", "hide_bot": "true", "XXXQDM": "campus", "XNXQDM": "2025-2026-1", "JXLDM": "B+& Room", "token": "[REDACTED]"])
        #expect(evidence.bodyParameterNames == ["JXLDM", "XNXQDM", "password"])
        request.httpBody = Data("requestParamStr=%7B%22XNXQDM%22%3A%222025-2026-1%22%2C%22ZC%22%3A%221%22%7D&password=secret".utf8)
        #expect(NetworkSmokeHTTPRequestEvidence(request: request, response: response).query == ["search": "BIT101", "hide_bot": "true", "XXXQDM": "campus", "XNXQDM": "2025-2026-1", "token": "[REDACTED]"])
        #expect(NetworkSmokeHTTPRequestEvidence(request: request, response: response).bodyParameterNames ==
            ["password", "requestParamStr", "requestParamStr.XNXQDM", "requestParamStr.ZC"])
        #expect(!String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self).contains("secret"))
    }

    @Test func requestEvidenceRetainsJSONFiltersAndOpaqueFieldNames() throws {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"obj":"paper1","search":"BIT101","page":2,"anonymous":true,"password":"secret"}"#.utf8)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let evidence = NetworkSmokeHTTPRequestEvidence(request: request, response: response)
        #expect(evidence.query == ["obj": "paper1", "search": "BIT101", "page": "2"])
        #expect(evidence.bodyParameterNames == ["anonymous", "obj", "page", "password", "search"])
        #expect(evidence.finalBodyParameterNames == evidence.bodyParameterNames)
        #expect(!String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self).contains("secret"))
    }

    @Test(arguments: [(#"{"obj":"paper1","obj":"paper2"}"#, ["obj"]),
        (#"{"obj":"paper1","\u006fbj":"paper1"}"#, ["obj"]),
        (#"{"detail":true,"detail":false}"#, ["detail"]),
        (#"{"obj":"paper1","items":[{"id":1,"id":2}]}"#, ["id"]),
        (#"{"obj":"paper1","first":{"id":1},"second":{"id":2},"text":"{\"id\":3}"}"#, []),
        (#"{"obj":"paper1","text":"quote\" and brace }"}"#, [])], [false, true])
    func requestEvidencePreservesJSONKeyAmbiguity(fixture: (String, [String]), redirected: Bool) throws {
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let original = URLRequest(url: url)
        var request = original
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fixture.0.utf8)
        let evidence = NetworkSmokeHTTPRequestEvidence(request: redirected ? original : request, response: response,
            finalRequest: redirected ? request : nil)
        #expect(evidence.finalAmbiguousParameters == (fixture.1.isEmpty ? nil : fixture.1))
        #expect(evidence.ambiguousParameters == (redirected || fixture.1.isEmpty ? nil : fixture.1))
        for key in fixture.1 { #expect(evidence.finalQuery[key] == nil) }
    }

    @Test(arguments: [#"{"XNXQDM":"first","XNXQDM":"second"}"#,
        #"{"XNXQDM":"first","\u0058NXQDM":"first"}"#])
    func requestEvidencePreservesJSONFormKeyAmbiguity(json: String) throws {
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "requestParamStr", value: json)]
        var request = URLRequest(url: url)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(try #require(form.percentEncodedQuery).utf8)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let evidence = NetworkSmokeHTTPRequestEvidence(request: request, response: response)
        #expect(evidence.ambiguousParameters == ["XNXQDM"] && evidence.query["XNXQDM"] == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [(#"{"courses":[]}"#, [String]?.some([])), (#"{"courses":[{"id":41,"name":"secret"},{"id":43}]}"#, .some(["41", "43"])),
        (#"{"courses":[{"id":true}]}"#, nil), (#"{"courses":[{"id":0}]}"#, nil), ("{}", nil)])
    func requestEvidenceBindsEclassCourseResponsesWithoutTheirContent(fixture: (String, [String]?)) async throws {
        let url = AppURL.required("https://zy-eclass.bit.edu.cn/api/my-courses")
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let evidence = await NetworkSmokeHTTPRequestEvidence.capture(request: URLRequest(url: url), response: response, body: Data(fixture.0.utf8))
        #expect(evidence.responseCourseIDs == fixture.1)
        #expect(!String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self).contains("secret"))
    }

    @Test(.timeLimit(.minutes(1))) func finalRequestProjectionSurvivesTransportWrappers() async throws {
        let origin = AppURL.required("https://example.invalid/submit?obj=paper1&token=secret")
        let target = AppURL.required("https://other.invalid/final?obj=paper2&token=private")
        var request = URLRequest(url: origin); request.httpMethod = "POST"
        let response = try #require(HTTPURLResponse(url: target, statusCode: 200, httpVersion: nil, headerFields: nil))
        let base = FinalRequestTransport(base: StubTransport(result: .success((Data(), response))), finalRequest: URLRequest(url: target))
        let client = HTTPClient(transport: ForwardingTransport(base: base), observer: nil)
        var evidence: NetworkSmokeHTTPRequestEvidence?
        try await HTTPRequestEvidenceContext.$didReceive.withValue({ request, response in evidence = await NetworkSmokeHTTPRequestEvidence.capture(request: request, response: response.response, body: response.data, finalRequest: response.finalRequest) }) { _ = try await client.send(request) }
        let captured = try #require(evidence)
        #expect(captured.method == "POST" && captured.finalMethod == "GET")
        #expect(captured.endpoint == "https://example.invalid/submit" && captured.finalEndpoint == "https://other.invalid/final")
        #expect(captured.query["obj"] == "paper1" && captured.finalQuery == ["obj": "paper2", "token": "[REDACTED]"])
        #expect(NetworkSmokeHTTPRequestEvidence(request: request, response: response).finalMethod == "")
    }

    private let url = AppURL.required("https://example.invalid/module-test")
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func emergencyConfigurationEvidenceIdentifiesTheSampledKVContent(enabled: Bool) async throws {
        let url = AppURL.required("https://update.aihelpme.dev/emergency-update.json")
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let body = Data("{\"schema_version\":1,\"enabled\":\(enabled),\"notice_id\":\"maintenance\",\"message\":\"private content\"}".utf8)
        let evidence = await NetworkSmokeHTTPRequestEvidence.capture(request: URLRequest(url: url), response: response, body: body)
        let configuration = try #require(evidence.responseConfiguration)
        #expect(configuration.enabled == enabled && configuration.noticeID == "maintenance" && configuration.digest.count == 64)
        let changed = await NetworkSmokeHTTPRequestEvidence.capture(request: URLRequest(url: url), response: response, body: body + Data(" ".utf8))
        #expect(changed.responseConfiguration?.digest != configuration.digest)
        #expect(!String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self).contains("private content"))
    }
    @Test(arguments: ["limit", "claim_id", "tags"])
    func requestEvidenceKeepsUnexpectedParameterNames(key: String) throws {
        let url = AppURL.required("https://example.invalid/probe?\(key)=secret&\(key)=private")
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let evidence = NetworkSmokeHTTPRequestEvidence(request: URLRequest(url: url), response: response)
        #expect(evidence.ambiguousParameters == [key])
        let singleURL = AppURL.required("https://example.invalid/probe?\(key)=secret")
        let single = NetworkSmokeHTTPRequestEvidence(request: URLRequest(url: singleURL), response: response)
        #expect(single.query == [key: "[REDACTED]"])
        #expect(!String(decoding: try JSONEncoder().encode(single), as: UTF8.self).contains("secret"))
    }
    private struct StubTransport: HTTPTransport {
        let result: Result<(Data, URLResponse), any Error>
        func data(for request: URLRequest) async throws -> (Data, URLResponse) { try result.get() }
    }
    private struct FinalRequestTransport: HTTPTransport {
        let base: any HTTPTransport
        let finalRequest: URLRequest
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            HTTPRequestEvidenceContext.didReceiveFinalRequest?(finalRequest)
            return try await base.data(for: request)
        }
    }
    private struct ForwardingTransport: HTTPTransport {
        let base: any HTTPTransport
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            try await data(for: request, maximumBytes: nil)
        }
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            let response = try await HTTPClient(transport: base, observer: nil).send(request, accepting: 100 ..< 600, maximumBytes: maximumBytes)
            return (response.data, response.response)
        }
    }
}
