#if DEBUG
import Foundation
import Testing
import UIKit
import WebKit
import Combine
import ClientCore
import ScoreDomain
import ScorePorts
import ScheduleDomain
import SchedulePorts
@testable import ScheduleInfrastructure
import MediaKit
import CommunityCore
import CommunityTransport
@testable import GalleryFeature
import CourseFeature
@testable import MineFeature
@testable import PaperFeature
import TransportCore
import StorageCore
@testable import BIT101_iOS

@Suite("Network smoke coverage")
@MainActor
struct NetworkSmokeCoverageTests {
    private func smokeIdentity() -> CommunitySessionIdentity { .init(accountIdentifier: "fixture") }

    @Test(arguments: ["array", "batch", "messages"], [false, true])
    func pagingUsesItsInjectedSessionAcrossPages(kind: String, switchesAccount: Bool) async throws {
        var identity = smokeIdentity()
        var calls = 0
        func advance() {
            calls += 1
            if switchesAccount && calls == 2 { identity = .init(accountIdentifier: "other") }
        }
        let operation: () async throws -> Void = {
            switch kind {
            case "array":
                let _: [CommunityUser] = try await NetworkSmokePaging.arrayPage(currentIdentity: { identity }) { page in
                    advance(); return [user(page + 1)]
                }
            case "batch":
                let _: GalleryPageBatch<CommunityUser> = try await NetworkSmokePaging.batch(currentIdentity: { identity }) { page in
                    advance(); return .init(items: [user(page + 1)], nextSourcePage: page + 1, canLoadMore: page == 0, sourceIDs: [page + 1])
                }
            default:
                _ = try await NetworkSmokePaging.messages(currentIdentity: { identity }) { _ in advance(); return [] }
            }
        }
        if switchesAccount { await #expect(throws: CancellationError.self) { try await operation() } }
        else { try await operation() }
        #expect(calls == 2)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["provisional", "navigation", "process"])
    func galleryWebFailuresRenderTheRetryDocument(path: String) async throws {
        let coordinator = GalleryWebCoordinator(credentials: .init(cookie: { "fixture" }, changes: Empty().eraseToAnyPublisher()), openExternal: { _ in })
        let webView = WKWebView()
        webView.navigationDelegate = coordinator
        switch path {
        case "provisional": coordinator.webView(webView, didFailProvisionalNavigation: nil, withError: URLError(.notConnectedToInternet))
        case "navigation": coordinator.webView(webView, didFail: nil, withError: URLError(.networkConnectionLost))
        default: coordinator.webViewWebContentProcessDidTerminate(webView)
        }
        var text = ""
        let deadline = Date.now.addingTimeInterval(5)
        repeat {
            text = try await webView.evaluateJavaScript("document.body?.innerText ?? ''") as? String ?? ""
            if text.contains("重新加载") { break }
            try await Task.sleep(for: .milliseconds(50))
        } while Date.now < deadline
        #expect(text.contains("话廊网页加载失败") && text.contains("重新加载"))
        #expect(try await webView.evaluateJavaScript("document.querySelector('a')?.href") as? String == "https://bit101.cn/gallery")
    }

    private final class BotFeed: GalleryFeedServicing {
        var pages: [Int] = []
        func fetchBotFeed(startPage: Int) async throws -> GalleryPageBatch<CommunityPoster> {
            pages.append(startPage)
            return .init(items: [], nextSourcePage: startPage + 5, canLoadMore: startPage < 10, sourceIDs: [startPage + 1])
        }
        func fetchFeed(kind: GalleryFeedKind, page: Int?) async throws -> GalleryPageBatch<CommunityPoster> { throw URLError(.unsupportedURL) }
        func fetchRecommendPage(sourcePage: Int) async throws -> GalleryPageBatch<CommunityPoster> { throw URLError(.unsupportedURL) }
        func searchPosters(query: GallerySearchQuery, page: Int?) async throws -> GalleryPageBatch<CommunityPoster> { throw URLError(.unsupportedURL) }
    }

    @Test func emptyBotBatchesContinueThroughTheirSourceCursor() async {
        let service = BotFeed()
        let model = GalleryViewModel(service: service)
        await model.refresh(feed: .bot)
        #expect(service.pages == [0] && model.state(for: .bot).nextPage == 5 && model.state(for: .bot).canLoadMore)
        await model.enqueueLoadMore(for: .bot, currentPoster: nil).value
        #expect(service.pages == [0, 5] && model.state(for: .bot).nextPage == 10 && !model.state(for: .bot).isLoadingMore)
        await model.enqueueLoadMore(for: .bot, currentPoster: nil).value
        #expect(service.pages == [0, 5, 10] && model.state(for: .bot).nextPage == 15 && !model.state(for: .bot).canLoadMore)
    }

    private final class SelectorTransport: HTTPTransport {
        var body = Data()
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            return (body, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
    }

    @Test(arguments: ["complete", "missing", "wrong", "empty", "malformed"])
    func eclassSmokeBindsEveryReturnedCourseToItsActivityRequest(stage: String) async throws {
        let transport = SelectorTransport()
        transport.body = Data((stage == "malformed" ? "{}" : stage == "empty" ? #"{"courses":[]}"# : #"{"courses":[{"id":41},{"id":43}]}"#).utf8)
        let client = HTTPClient(transport: transport, observer: nil)
        let collector = NetworkSmokeRequestCollector()
        let operation = {
            var list = URLRequest(url: AppURL.required("https://zy-eclass.bit.edu.cn/api/my-courses"))
            list.httpMethod = "POST"
            _ = try await client.send(list)
            for id in stage == "empty" ? [] : stage == "missing" ? [41] : stage == "wrong" ? [41, 45] : [41, 43] {
                _ = try await client.send(URLRequest(url: AppURL.required("https://zy-eclass.bit.edu.cn/api/courses/\(id)/activities")))
            }
        }
        if stage == "complete" || stage == "empty" { try await collector.perform(operation, required: true) }
        else { await #expect(throws: NetworkSmokeRequestError.self) { try await collector.perform(operation, required: true) } }
    }

    @Test(arguments: ["0", "99"], [false, true])
    func requestEvidenceRejectsAmbiguousBusinessParameters(value: String, redirected: Bool) async throws {
        let url = AppURL.required("https://bit101.flwfdd.xyz/papers?page=0")
        let duplicate = AppURL.required(url.absoluteString + "&page=\(value)")
        let request = URLRequest(url: redirected ? url : duplicate)
        let finalRequest = URLRequest(url: duplicate)
        let response = try #require(HTTPURLResponse(url: duplicate, statusCode: 200, httpVersion: nil, headerFields: nil))
        let collector = NetworkSmokeRequestCollector()
        await #expect(throws: NetworkSmokeRequestError.self) {
            try await collector.perform({ await HTTPRequestEvidenceContext.didReceive?(request, HTTPResponse(data: Data(), response: response, finalRequest: finalRequest)) }, required: true)
        }
        #expect(collector.requests.count == 1 && HTTPRequestEvidenceContext.didReceive == nil)
    }

    @Test(arguments: ["complete", "missing", "wrong-source", "wrong-query", "extra"])
    func imageSmokeBindsEverySelectedResource(stage: String) async throws {
        let urls = ["https://cdn.example.invalid/image.png?token=first", "https://cdn.example.invalid/other.png"]
        let selected = stage == "missing" ? [urls[0]] : stage == "wrong-source" ? [urls[0], "https://other.example.invalid/image.png"]
            : stage == "wrong-query" ? [urls[0].replacingOccurrences(of: "first", with: "second"), urls[1]]
            : stage == "extra" ? urls + ["https://cdn.example.invalid/extra.png"] : urls
        let client = HTTPClient(transport: SelectorTransport(), observer: nil)
        let collector = NetworkSmokeRequestCollector()
        let operation = {
            for url in selected { _ = try await client.send(URLRequest(url: AppURL.required(url))) }
        }
        if stage == "complete" {
            try await collector.perform(operation, required: true, expectedParameters: NetworkSmokePaging.imageResourceParameters(urls))
        } else {
            await #expect(throws: NetworkSmokeRequestError.self) {
                try await collector.perform(operation, required: true, expectedParameters: NetworkSmokePaging.imageResourceParameters(urls))
            }
        }
    }

    @Test(arguments: ["correct", "wrong", "missing"])
    func buildingSmokeKeepsItsSelectedCampus(selection: String) async throws {
        let client = HTTPClient(transport: SelectorTransport(), observer: nil)
        let base = "https://jxzxehallapp.bit.edu.cn/jwapp/sys/kxjasbyMobile/modules/jxllb/cxjxl.do"
        let request = URLRequest(url: AppURL.required(base + (selection == "missing" ? "" : "?XXXQDM=" + (selection == "correct" ? "campus" : "other"))))
        let collector = NetworkSmokeRequestCollector()
        let operation = { try await client.send(request) }
        if selection == "correct" { _ = try await collector.perform(operation, required: true, expectedParameters: ["XXXQDM": "campus"]) }
        else { await #expect(throws: NetworkSmokeRequestError.self) { try await collector.perform(operation, required: true, expectedParameters: ["XXXQDM": "campus"]) } }
        let building = BuildingRecord(id: "building", name: "", buildingCode: "building", campusName: "", campusCode: selection == "correct" ? "campus" : "other")
        if selection == "correct" { try NetworkSmokePaging.checkBuildings([building], campusCode: "campus") }
        else { #expect(throws: URLError.self) { try NetworkSmokePaging.checkBuildings([building], campusCode: "campus") } }
    }

    @Test(arguments: ["valid", "empty", "text-only", "image-only", "unsupported", "broken-image"])
    func paperSmokeUsesTheProductionRendererAndRequiresReadableTextAndImages(stage: String) throws {
        let raw = stage == "empty" ? "" : stage == "text-only" ? "text" : stage == "image-only" ? #"{"blocks":[{"type":"image","data":{"file":{"url":"https://image.invalid/paper.png"}}}]}"#
            : stage == "unsupported" ? #"{"blocks":[{"type":"table","data":{}}]}"#
            : smokePaperContent.replacingOccurrences(of: "https://image.invalid/paper.png", with: stage == "broken-image" ? "javascript:alert(1)" : "https://image.invalid/paper.png")
        if stage == "valid" { #expect(try NetworkSmokePaging.checkPaperContent(raw) == ["https://image.invalid/paper.png"]) }
        else { #expect(throws: URLError.self) { try NetworkSmokePaging.checkPaperContent(raw) } }
    }

    @Test(arguments: ["correct", "wrong", "missing"])
    func requestEvidenceChecksTheSelectedTermAndBuilding(selection: String) async throws {
        let client = HTTPClient(transport: SelectorTransport(), observer: nil)
        var request = URLRequest(url: AppURL.required("https://jxzxehallapp.bit.edu.cn/jwapp/sys/kxjasbyMobile/kxjasbyController/cxkxjasqk.do"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = HTTPFormEncoding.body([("XNXQDM", "2025-2026-1")] + (selection == "missing" ? [] : [("JXLDM", selection == "correct" ? "selected-building" : "wrong-building")]))
        let collector = NetworkSmokeRequestCollector()
        let operation = { try await client.send(request) }
        let expected = ["XNXQDM": "2025-2026-1", "JXLDM": "selected-building"]
        if selection == "correct" { _ = try await collector.perform(operation, required: true, expectedParameters: expected) }
        else {
            await #expect(throws: NetworkSmokeRequestError.self) {
                try await collector.perform(operation, required: true, expectedParameters: expected)
            }
        }
        #expect(collector.requests.count == 1 && HTTPRequestEvidenceContext.didReceive == nil)
    }

    @Test(arguments: ["obj", "uid", "path"], ["correct", "wrong", "missing"])
    func requestEvidenceChecksTheSelectedCommunityInput(key: String, selection: String) async throws {
        let expected = key == "obj" ? "poster17" : key == "uid" ? "23" : "/courses/histories/课程 1"
        var components = try #require(URLComponents(string: "https://bit101.flwfdd.xyz" + (key == "path" ? "/courses/histories/17" : key == "obj" ? "/reaction/comments" : "/posters")))
        if key == "path" { components.path = expected }
        if key == "path", selection != "correct" {
            components.path = selection == "wrong" ? "/courses/histories/999" : "/user/check"
        } else if key != "path", selection != "missing" {
            components.queryItems = [URLQueryItem(name: key, value: selection == "correct" ? expected : key == "obj" ? "poster999" : "999")]
        }
        let url = try #require(components.url)
        let client = HTTPClient(transport: SelectorTransport(), observer: nil)
        let collector = NetworkSmokeRequestCollector()
        let operation = { try await client.send(URLRequest(url: url)) }
        if selection == "correct" { _ = try await collector.perform(operation, required: true, expectedParameters: [key: expected]) }
        else {
            await #expect(throws: NetworkSmokeRequestError.self) {
                try await collector.perform(operation, required: true, expectedParameters: [key: expected])
            }
        }
        #expect(collector.requests.count == 1 && HTTPRequestEvidenceContext.didReceive == nil)
    }

    @Test func smokeResponsesKeepTheirSelectedCommentParentAndPosterAuthor() throws {
        let user = user(23)
        let comment = CommunityComment(id: 1, obj: "paper17", images: [], user: user, anonymous: false,
            createTime: "", updateTime: "", like: false, likeNum: 0, commentNum: 0, own: false, rate: 0,
            replyUser: user, replyObj: "", text: "", sub: [])
        try NetworkSmokePaging.checkComments([comment], for: "paper17")
        #expect(throws: URLError.self) { try NetworkSmokePaging.checkComments([comment], for: "paper999") }
        let poster = CommunityPoster(anonymous: false, claim: .init(id: 0, text: ""), commentNum: 0, createTime: "", editTime: "",
            id: 1, images: [], likeNum: 0, public: true, tags: [], text: "", title: "", updateTime: "", user: user)
        try NetworkSmokePaging.checkPosters([poster], for: 23)
        #expect(throws: URLError.self) { try NetworkSmokePaging.checkPosters([poster], for: 999) }
    }

    @Test func serverAbsenceConfirmationTravelsThroughTheCleanupLaunchRequest() throws {
        let confirmation = CommunityWriteRecoveryConfirmation(marker: "功能验收 fixture", account: 1,
            serverReceipt: "backend-reconciliation", kinds: ["poster"], parents: ["course1"])
        let encoded = try JSONEncoder().encode(confirmation)
        let environment = ["BIT101_COMMUNITY_RECOVERY_CONFIRMATION": String(decoding: encoded, as: UTF8.self)]
        let request = try #require(ReleaseNetworkSmokeLaunchRequest(scope: .communityCleanup, environment: environment))
        #expect(request.communityRecoveryConfirmation?.serverReceipt == confirmation.serverReceipt)
        #expect(ReleaseNetworkSmokeLaunchRequest(scope: .ddl, environment: environment) == nil)
        let fileRequest = try JSONDecoder().decode(ReleaseNetworkSmokeLaunchRequest.self, from: JSONEncoder().encode(request))
        #expect(fileRequest.communityRecoveryConfirmation?.marker == confirmation.marker)
        #expect(fileRequest.communityRecoveryConfirmation?.kinds == ["poster"])
        #expect(ReleaseNetworkSmokeLaunchRequest(scope: .communityCleanup,
            environment: ["BIT101_COMMUNITY_RECOVERY_CONFIRMATION": "{}"]) == nil)
    }

    @Test func botSmokeRejectsOrdinaryPostersAndAcceptsRecognizedTags() throws {
        func poster(tags: [String]) -> CommunityPoster {
            CommunityPoster(anonymous: false, claim: .init(id: 0, text: ""), commentNum: 0, createTime: "", editTime: "",
                id: 1, images: [], likeNum: 0, public: true, tags: tags, text: "", title: "", updateTime: "", user: user(1))
        }
        try NetworkSmokePaging.checkBotPosters([])
        for tags in [["BOT"], ["机器人"], ["通知"], ["新闻"]] {
            try NetworkSmokePaging.checkBotPosters([poster(tags: tags)])
        }
        #expect(throws: URLError.self) { try NetworkSmokePaging.checkBotPosters([poster(tags: ["生活"])]) }
        #expect(throws: URLError.self) { try NetworkSmokePaging.checkBotPosters([poster(tags: ["BOT"]), poster(tags: [])]) }
    }

    @Test(arguments: PaperSortOrder.allCases)
    func paperSmokeChecksRankTimezonesAndTies(order: PaperSortOrder) throws {
        let first = PaperSummary(id: 1, title: "", intro: "", likeNum: 2, commentNum: 3, updateTime: "2026-01-02T00:00:00Z")
        let tied = PaperSummary(id: 2, title: "", intro: "", likeNum: 2, commentNum: 3, updateTime: "2026-01-02T08:00:00+08:00")
        let older = PaperSummary(id: 3, title: "", intro: "", likeNum: 1, commentNum: 2, updateTime: "2026-01-01 08:00:00")
        try NetworkSmokePaging.checkPapers([], order: order)
        try NetworkSmokePaging.checkPapers([first, tied, older], order: order)
        #expect(throws: URLError.self) { try NetworkSmokePaging.checkPapers([older, first], order: order) }
        if order == .newest {
            let invalid = PaperSummary(id: 4, title: "", intro: "", likeNum: 0, commentNum: 0, updateTime: "invalid")
            #expect(throws: URLError.self) { try NetworkSmokePaging.checkPapers([invalid], order: order) }
        }
    }

    @Test func maintainedFixturesValidateAndTravelThroughBothLaunchEntrypoints() throws {
        let fixture = NetworkSmokeFixtures(posterID: 41, courseID: 43, courseNumber: "COURSE", paperID: 45)
        let encoded = try JSONEncoder().encode(fixture)
        let payload = try JSONSerialization.data(withJSONObject: ["scope": "bit101", "runID": "fixture",
            "capture": "none", "fixtures": try JSONSerialization.jsonObject(with: encoded)])
        let request = try JSONDecoder().decode(ReleaseNetworkSmokeLaunchRequest.self, from: payload)
        #expect(request.fixtures?.isValid == true && request.fixtures?.courseID == 43)
        var components = try #require(URLComponents(string: "bit101://network-smoke/bit101"))
        components.queryItems = [.init(name: "fixtures", value: String(decoding: encoded, as: UTF8.self))]
        #expect(ReleaseNetworkSmokeLaunchRequest(url: try #require(components.url))?.fixtures?.posterID == 41)
        var environment = ["BIT101_NETWORK_SMOKE_FIXTURES": String(decoding: encoded, as: UTF8.self),
            "BIT101_VALIDATION_RUN_ID": "fixture", "BIT101_NETWORK_SMOKE_TERM": "2026-2027-1",
            "BIT101_COMMUNITY_FOLLOW_TARGET": "2", "BIT101_COMMUNITY_SMOKE_ACCOUNT": "1"]
        let environmentRequest = try #require(ReleaseNetworkSmokeLaunchRequest(scope: .bit101, environment: environment))
        #expect(environmentRequest.fixtures?.posterID == 41 && environmentRequest.fixtures?.courseID == 43)
        #expect(environmentRequest.scope == .bit101 && environmentRequest.runID == "fixture" && environmentRequest.capture == .none)
        #expect(environmentRequest.term == "2026-2027-1" && environmentRequest.communityFollowTarget == 2
            && environmentRequest.communityExpectedAccount == 1)
        for (key, value) in [("BIT101_NETWORK_SMOKE_CAPTURE", "invalid"), ("BIT101_NETWORK_SMOKE_FIXTURES", "{}"),
            ("BIT101_COMMUNITY_FOLLOW_TARGET", "0"), ("BIT101_COMMUNITY_SMOKE_ACCOUNT", "invalid")] {
            let original = environment[key]
            environment[key] = value
            #expect(ReleaseNetworkSmokeLaunchRequest(scope: .bit101, environment: environment) == nil)
            environment[key] = original
        }
        for value in [NetworkSmokeFixtures(posterID: 0, courseID: 43, courseNumber: "COURSE", paperID: 45),
            NetworkSmokeFixtures(posterID: 41, courseID: 43, courseNumber: " COURSE", paperID: 45)] {
            #expect(!value.isValid)
            components.queryItems = [.init(name: "fixtures", value: String(decoding: try JSONEncoder().encode(value), as: UTF8.self))]
            #expect(ReleaseNetworkSmokeLaunchRequest(url: try #require(components.url)) == nil)
        }
    }

    @Test func pendingSmokeRequestRequiresSuccessfulConsumption() throws {
        let files = PreferenceMemoryFiles()
        let url = files.temporaryDirectoryURL.appending(path: "network-smoke-request.json")
        let data = Data(#"{"scope":"bit101","runID":"fixture","capture":"none"}"#.utf8)
        try files.writeData(data, to: url, options: [.atomic])
        files.setFailures(removal: true)
        #expect(ReleaseNetworkSmokeLaunchRequest.readPendingFile(files: files, at: url) == nil)
        #expect(try files.readData(at: url) == data)
        files.setFailures()
        #expect(ReleaseNetworkSmokeLaunchRequest.readPendingFile(files: files, at: url)?.runID == "fixture")
        #expect(!files.fileExists(at: url))
        #expect(ReleaseNetworkSmokeLaunchRequest.readPendingFile(files: files, at: url) == nil)
    }

    @Test func imageProbeCollectsDistinctVariantsAcrossTheSampledList() {
        let empty = CommunityImage(mid: "empty", url: "", lowUrl: "")
        let image = CommunityImage(mid: "image", url: "https://image.invalid/full", lowUrl: "https://image.invalid/low")
        #expect(NetworkSmokePaging.imageURLs(in: [empty, image, image]) == [image.url, image.lowUrl])
        #expect(NetworkSmokePaging.imageURLs(in: [empty]).isEmpty)
        #expect(NetworkSmokePaging.imageURLs(in: [CommunityImage(mid: "full", url: image.url, lowUrl: "")]) == [image.url])
    }

    @Test func articleUnknownBlocksKeepTheirPositionAndOfferTheOriginal() {
        let raw = #"{"blocks":[{"id":"first","type":"paragraph","data":{"text":"正文"}},{"id":"future","type":"table","data":{"content":[["单元格"]]}},{"id":"last","type":"paragraph","data":{"text":"末段"}}]}"#
        let blocks = PaperContentRenderer.blocks(from: raw)
        #expect(blocks.map(\.id) == ["first", "future", "last"])
        if case .requiresOriginal = blocks[1] {} else { Issue.record("Extended content should keep an original-reading placeholder") }
        #expect(PaperEditorContentBuilder.canEditAsPlainText(raw) == false)
    }

    @Test(arguments: ["body", "blocks", "block"])
    func articleResourceBudgetsStopBeforeRichTextImport(kind: String) throws {
        let raw: String
        switch kind {
        case "body": raw = String(repeating: "x", count: PaperContentResourceLimits.maximumBodyBytes + 1)
        case "blocks":
            let block: [String: Any] = ["type": "paragraph", "data": ["text": "text"]]
            raw = String(decoding: try JSONSerialization.data(withJSONObject: ["blocks": Array(repeating: block,
                count: PaperContentResourceLimits.maximumBlocks + 1)]), as: UTF8.self)
        default:
            raw = String(decoding: try JSONSerialization.data(withJSONObject: ["blocks": [["type": "paragraph",
                "data": ["text": String(repeating: "x", count: PaperContentResourceLimits.maximumBlockBytes + 1)]]]]), as: UTF8.self)
        }
        let blocks = PaperContentRenderer.blocks(from: raw)
        #expect(blocks.count == 1)
        if case .requiresOriginal = blocks[0] {} else { Issue.record("Oversized content should offer original reading") }
    }

    private func user(_ id: Int) -> CommunityUser {
        .init(id: id, createTime: "", nickname: "fixture", avatar: .init(mid: "", url: "", lowUrl: ""), motto: "",
            identity: .init(id: 1, color: "", text: "", createTime: "", updateTime: "", deleteTime: nil))
    }

    @Test func pageFailureAndFilteredSourceCursorRemainPartOfTheProbe() async throws {
        var pages: [Int] = []
        await #expect(throws: URLError.self) {
            _ = try await NetworkSmokePaging.arrayPage(currentIdentity: smokeIdentity) { page in
                pages.append(page)
                if page == 1 { throw URLError(.timedOut) }
                return [user(1)]
            }
        }
        #expect(pages == [0, 1])
        pages = []
        let first: GalleryPageBatch<CommunityUser> = try await NetworkSmokePaging.batch(currentIdentity: smokeIdentity) { page in
            pages.append(page)
            return .init(items: [], nextSourcePage: page == 0 ? 4 : 5, canLoadMore: page == 0, sourceIDs: [page + 1])
        }
        #expect(first.items.isEmpty && pages == [0, 4])
        await #expect(throws: URLError.self) {
            let _: GalleryPageBatch<CommunityUser> = try await NetworkSmokePaging.batch(currentIdentity: smokeIdentity) { page in
                .init(items: [user(1)], nextSourcePage: 1, canLoadMore: true)
            }
        }
    }

    @Test func repeatedPagesFailAndPartialOverlapOrTerminalPagesAdvance() async throws {
        for repeated in [true, false] {
            var pages: [Int] = []
            await #expect(throws: URLError.self) {
                _ = try await NetworkSmokePaging.arrayPage(currentIdentity: smokeIdentity) { page in
                    pages.append(page)
                    return [user(repeated || page == 0 ? 1 : 0)]
                }
            }
            #expect(pages == (repeated ? [0, 1, 2, 3, 4] : [0, 1]))
            pages = []
            await #expect(throws: URLError.self) {
                let _: GalleryPageBatch<CommunityUser> = try await NetworkSmokePaging.batch(currentIdentity: smokeIdentity) { page in
                    pages.append(page)
                    return .init(items: [], nextSourcePage: page + 1, canLoadMore: true,
                        sourceIDs: [repeated || page == 0 ? 1 : 0])
                }
            }
            #expect(pages == (repeated ? [0, 1, 2, 3, 4] : [0, 1]))
        }
        for terminal in [false, true] {
            var pages: [Int] = []
            _ = try await NetworkSmokePaging.arrayPage(currentIdentity: smokeIdentity) { page in
                pages.append(page)
                return page == 0 ? [user(1), user(2)] : terminal ? [] : [user(2), user(3)]
            }
            #expect(pages == [0, 1])
            pages = []
            let _: GalleryPageBatch<CommunityUser> = try await NetworkSmokePaging.batch(currentIdentity: smokeIdentity) { page in
                pages.append(page)
                return .init(items: [], nextSourcePage: page + 1, canLoadMore: page == 0,
                    sourceIDs: page == 0 ? [1, 2] : terminal ? [] : [2, 3])
            }
            #expect(pages == [0, 1])
        }
    }

    @Test func temporaryRepeatedPagesRecoverAndSampleContinuationImages() async throws {
        for repeated in [1, 3] {
            var pages: [Int] = []
            let values = try await NetworkSmokePaging.arrayPage(currentIdentity: smokeIdentity) { page in
                pages.append(page)
                return [user(page <= repeated ? 1 : 2)]
            }
            #expect(values.map(\.id) == [1, 2] && pages == Array(0...(repeated + 1)))
            pages = []
            let sample: GalleryPageBatch<CommunityUser> = try await NetworkSmokePaging.batch(currentIdentity: smokeIdentity) { page in
                pages.append(page)
                let id = page <= repeated ? 1 : 2
                let value = CommunityUser(id: id, createTime: "", nickname: "fixture",
                    avatar: .init(mid: "image", url: id == 2 ? "https://image.invalid/continuation" : "", lowUrl: ""), motto: "",
                    identity: .init(id: 1, color: "", text: "", createTime: "", updateTime: "", deleteTime: nil))
                return .init(items: [value], nextSourcePage: page + 1, canLoadMore: true, sourceIDs: [id])
            }
            #expect(sample.items.map(\.id) == [1, 2] && pages == Array(0...(repeated + 1)))
            #expect(sample.sourceIDs == [1, 2] && sample.nextSourcePage == repeated + 2)
            #expect(NetworkSmokePaging.imageURLs(in: sample.items.map(\.avatar)) == ["https://image.invalid/continuation"])
        }
    }

    @Test func terminalPagesExerciseContinuationAndMessagesUseTheirActualCursor() async throws {
        var pages: [Int] = []
        let empty: [CommunityUser] = try await NetworkSmokePaging.arrayPage(currentIdentity: smokeIdentity) { page in pages.append(page); return [] }
        #expect(empty.isEmpty && pages == [0, 1])
        await #expect(throws: URLError.self) {
            let _: [CommunityUser] = try await NetworkSmokePaging.arrayPage(requiresContent: true, currentIdentity: smokeIdentity) { _ in [] }
        }
        let data = Data(#"{"from_user":{},"id":9,"link_obj":"poster1","obj":"poster1","text":"","update_time":""}"#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let message = try decoder.decode(GalleryMessage.self, from: data)
        var cursors: [Int?] = []
        _ = try await NetworkSmokePaging.messages(currentIdentity: smokeIdentity) { cursor in cursors.append(cursor); return cursor == Int.max ? [message] : [] }
        #expect(cursors == [Int.max, 9])
        cursors = []
        _ = try await NetworkSmokePaging.messages(currentIdentity: smokeIdentity) { cursor in cursors.append(cursor); return [] }
        #expect(cursors == [Int.max, 1])
        await #expect(throws: URLError.self) {
            _ = try await NetworkSmokePaging.messages(currentIdentity: smokeIdentity) { _ in [message] }
        }
    }

    @Test func briefAndDetailedScoresKeepTheSameCourseIdentityAndGrade() throws {
        let headers = ["序号", "课程编号", "课程名称", "成绩", "开课学期"]
        let first = ScoreRow(index: 0, headers: headers, values: ["1", "CS101", "课程", "90", "2025"])
        let detailed = ScoreRow(index: 1, headers: headers + ["平均分"], values: ["2", "CS101", "课程", "90", "2025", "80"])
        try NetworkSmokePaging.checkScores(brief: [first], detailed: [detailed])
        try NetworkSmokePaging.checkScores(brief: [], detailed: [])
        for values in [["2", "CS102", "课程", "90", "2025"], ["2", "CS101", "课程", "80", "2025"]] {
            #expect(throws: URLError.self) { try NetworkSmokePaging.checkScores(brief: [first], detailed: [ScoreRow(index: 0, headers: headers, values: values)]) }
        }
        #expect(throws: URLError.self) { try NetworkSmokePaging.checkScores(brief: [first], detailed: []) }
    }

    @Test(arguments: [false, true])
    func messageSamplingPreservesUnreadCountsAsNewMessagesArrive(emptyFirstPage: Bool) async throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let message = try decoder.decode(GalleryMessage.self,
            from: Data(#"{"from_user":{},"id":9,"link_obj":"poster1","obj":"poster1","text":"","update_time":""}"#.utf8))
        var messages: [GalleryMessage] = emptyFirstPage ? [] : [message]
        var unread = 3
        var requests = 0
        _ = try await NetworkSmokePaging.messages(currentIdentity: smokeIdentity) { cursor in
            requests += 1
            if emptyFirstPage && requests == 2 { messages = [message]; unread += 1 }
            let rows = messages.filter { cursor == nil || cursor == 0 || $0.id < (cursor ?? 0) }
            if (cursor == nil || cursor == 0) && !rows.isEmpty { unread = 0 }
            return rows
        }
        #expect(requests == 2 && unread == (emptyFirstPage ? 4 : 3))
    }

    @Test func messageSmokeUsesTheProductionCursorAndRejectsUnorderedPages() async throws {
        func messages(_ ids: [Int]) throws -> [GalleryMessage] {
            let rows = ids.map { ["fromUser": [:], "id": $0, "linkObj": "", "obj": "", "text": "", "updateTime": ""] as [String: Any] }
            return try JSONDecoder().decode([GalleryMessage].self, from: JSONSerialization.data(withJSONObject: rows))
        }
        for (first, second, valid) in [([9, 8], [7, 6], true), ([9, 8, 8], [7], false), ([8, 9], [7], false),
                                     ([9, 0], [], false), ([9, 8], [6, 7], false), ([9, 8], [7, 7], false), ([9, 8], [8], false)] {
            let firstPage = try messages(first), secondPage = try messages(second)
            var requested: [Int?] = [], page = GalleryMessageListState()
            page.applyFirstCursorPage(firstPage)
            let operation = { try await NetworkSmokePaging.messages(currentIdentity: smokeIdentity) { cursor in requested.append(cursor); return cursor == Int.max ? firstPage : secondPage } }
            if valid { _ = try await operation(); #expect(requested == [Int.max, page.nextCursor]) }
            else { await #expect(throws: URLError.self) { try await operation() } }
        }
    }

    private final class MediaRoute: HTTPTransport {
        var calls: [(String, String)] = []
        var referenced: [[String]] = []
        var brokenReference = false
        var failUpload = false
        var onUpload: (() -> Void)?
        private var image: [String: Any] { ["mid": "uploaded", "url": "https://example.invalid/image.jpg", "low_url": ""] }
        private var user: [String: Any] {
            ["id": 1, "create_time": "", "nickname": "fixture", "avatar": image, "motto": "",
                "identity": ["id": 1, "color": "", "text": "", "create_time": "", "update_time": ""]]
        }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            let method = request.httpMethod ?? "GET"
            calls.append((url.path, method))
            let result: [String: Any]
            if url.path == "/upload/image" {
                if failUpload { throw URLError(.networkConnectionLost) }
                #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data;") == true)
                let body = try #require(request.httpBody)
                #expect(body.range(of: Data([0xFF, 0xD8])) != nil)
                result = image
                onUpload?()
            } else if method == "POST" {
                let body = try #require(request.httpBody)
                let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                referenced.append(try #require(payload["image_mids"] as? [String]))
                if url.path == "/posters" { result = ["id": 9] }
                else {
                    result = ["id": 10, "obj": "poster9", "images": [image], "user": user, "anonymous": false,
                        "create_time": "", "update_time": "", "like": false, "like_num": 0, "comment_num": 0,
                        "own": true, "rate": 0, "reply_user": user, "reply_obj": "", "text": "fixture", "sub": []]
                }
            } else {
                result = ["id": 9, "title": "fixture", "text": "fixture", "anonymous": false, "claim": ["id": 0, "text": ""],
                    "comment_num": 0, "create_time": "", "edit_time": "", "images": brokenReference ? [] : [image],
                    "like": false, "like_num": 0, "own": true, "plugins": "[]", "public": false, "tags": [],
                    "update_time": "", "user": user]
            }
            return (try JSONSerialization.data(withJSONObject: result),
                try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
    }

    @Test func productionWritesUploadJPEGAndVerifyServerImageReferences() async throws {
        let route = MediaRoute()
        let session = CommunitySession(httpClient: HTTPClient(transport: route, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: { .init(identity: .init(accountIdentifier: "fixture"), cookie: "fixture") }, refresh: { _ in })
        let gallery = GalleryService(session: session, preferences: {
            .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        })
        var operations = CommunityWriteSmoke.Operations.production(gallery: gallery)
        var uploads: [String] = []
        #expect(try await operations.create(.poster, "fixture", { uploads.append($0) }, {}) == 9)
        #expect(try await operations.comment(.init(kind: .poster, object: "poster9"), "fixture", { uploads.append($0) }, {}).images.map(\.mid) == ["uploaded"])
        #expect(uploads == ["uploaded", "uploaded"])
        let imageData = try CommunityWriteMedia.jpeg()
        #expect(imageData == (try CommunityWriteMedia.jpeg()) && UIImage(data: imageData)?.size == CGSize(width: 1, height: 1))
        #expect(route.referenced == [["uploaded"], ["uploaded"]])
        #expect(route.calls.filter { $0.0 == "/upload/image" }.count == 2)
        route.brokenReference = true
        let created = try await operations.create(.poster, "fixture", { _ in }, {})
        #expect(try await operations.read(.poster, created)?.imageMids != ["uploaded"])
        let writes = route.calls.filter { $0.1 == "POST" && $0.0 != "/upload/image" }.count
        for comment in [false, true] {
            await #expect(throws: CocoaError.self) {
                let record: CommunityWriteSmoke.Operations.RecordImage = { _ in throw CocoaError(.fileWriteNoPermission) }
                if comment { _ = try await operations.comment(.init(kind: .poster, object: "poster9"), "fixture", record, {}) }
                else { _ = try await operations.create(.poster, "fixture", record, {}) }
            }
        }
        #expect(route.calls.filter { $0.1 == "POST" && $0.0 != "/upload/image" }.count == writes)
        route.failUpload = true
        for comment in [false, true] {
            await #expect(throws: (any Error).self) {
                let submit: CommunityWriteSmoke.Operations.RecordSubmission = { Issue.record("图片上传完成后记录业务提交") }
                if comment { _ = try await operations.comment(.init(kind: .poster, object: "poster9"), "fixture", { _ in }, submit) }
                else { _ = try await operations.create(.poster, "fixture", { _ in }, submit) }
            }
        }
        #expect(route.calls.filter { $0.1 == "POST" && $0.0 != "/upload/image" }.count == writes)
        route.failUpload = false
        var identity = CommunitySessionIdentity(accountIdentifier: "fixture")
        operations.identity = { identity }
        let scoped = operations.scoped(to: identity)
        route.onUpload = { identity = .init(accountIdentifier: "other") }
        await #expect(throws: CancellationError.self) {
            _ = try await scoped.create(.poster, "fixture", { _ in Issue.record("上传完成后沿账号归属保存资源") }, {})
        }
        #expect(route.calls.filter { $0.1 == "POST" && $0.0 != "/upload/image" }.count == writes)
    }
}
#endif

#if DEBUG
private let smokePaperContent = #"{"blocks":[{"type":"header","data":{"text":"Title","level":1}},{"type":"paragraph","data":{"text":"Readable <b>body</b>"}},{"type":"image","data":{"file":{"url":"https://image.invalid/paper.png"}}}]}"#
extension ReleaseNetworkSmokeLifecycleTests {
    private final class Services: NetworkSmokeGalleryServicing, NetworkSmokeCourseServicing, NetworkSmokePaperServicing,
        NetworkSmokeMineServicing, NetworkSmokeScheduleServicing, ScoreListServicing, TrustedTranscriptServicing {
        let stage: String
        let image: Data
        var rawResponse: ((Data) -> Void)?
        var observed = Set<String>()
        var webvpnVerified = false
        var ssoVerified = false
        private var smsChallenge: BITLoginAuthenticationChallenge { .init(challengeID: "fixture", accessToken: "fixture", status: "sms_required", maskedPhone: "***", expiresIn: 60) }
        init(stage: String, image: Data) { self.stage = stage; self.image = image }
        private var user: CommunityUser {
            CommunityUser(id: 1, createTime: "", nickname: "fixture", avatar: CommunityImage(mid: "image", url: "https://image.invalid/image.png", lowUrl: ""), motto: "",
                identity: CommunityIdentity(id: 1, color: "", text: "", createTime: "", updateTime: "", deleteTime: nil))
        }
        private var poster: CommunityPoster {
            CommunityPoster(anonymous: false, claim: CommunityClaim(id: 1, text: "fixture"), commentNum: 0, createTime: "", editTime: "", id: 1, images: [user.avatar],
                likeNum: 0, public: true, tags: [], text: "fixture", title: "fixture", updateTime: "", user: user)
        }
        private func comment(object: String) -> CommunityComment {
            CommunityComment(id: 1, obj: object, images: [], user: user, anonymous: false,
                createTime: "", updateTime: "", like: false, likeNum: 0, commentNum: 0, own: false,
                rate: 0, replyUser: user, replyObj: "", text: "fixture", sub: [])
        }
        func fetchFeed(kind: GalleryFeedKind, page: Int?) async throws -> GalleryPageBatch<CommunityPoster> {
            observed.insert("gallery-\(kind.rawValue)"); return posterPage(page ?? 0)
        }
        private func posterPage(_ page: Int) -> GalleryPageBatch<CommunityPoster> {
            if stage == "feed-images-missing-success" {
                let value = CommunityPoster(anonymous: false, claim: poster.claim, commentNum: 0, createTime: "", editTime: "", id: page + 1,
                    images: [],
                    likeNum: 0, public: true, tags: [], text: "fixture", title: "fixture", updateTime: "", user: user)
                return .init(items: page < 2 ? [value] : [], nextSourcePage: page + 1, canLoadMore: page == 0)
            }
            return .init(items: page == 0 ? [poster] : [], nextSourcePage: page + 1, canLoadMore: false)
        }
        func fetchRecommendPage(sourcePage: Int) async throws -> GalleryPageBatch<CommunityPoster> { posterPage(sourcePage) }
        func fetchBotFeed(startPage: Int) async throws -> GalleryPageBatch<CommunityPoster> {
            let batch = posterPage(startPage)
            if stage == "bot-classification-failure" { return batch }
            let items = batch.items.map {
                CommunityPoster(anonymous: $0.anonymous, claim: $0.claim, commentNum: $0.commentNum, createTime: $0.createTime,
                    editTime: $0.editTime, id: $0.id, images: $0.images, likeNum: $0.likeNum, public: $0.public,
                    tags: ["BOT"], text: $0.text, title: $0.title, updateTime: $0.updateTime, user: $0.user)
            }
            return .init(items: items, nextSourcePage: batch.nextSourcePage, canLoadMore: batch.canLoadMore, sourceIDs: batch.sourceIDs)
        }
        func searchPosters(query: GallerySearchQuery, page: Int?) async throws -> GalleryPageBatch<CommunityPoster> {
            posterPage(page ?? 0)
        }
        func fetchMessageUnreadCounts() async throws -> GalleryMessageUnreadCounts { GalleryMessageUnreadCounts() }
        func fetchMessages(type: GalleryMessageType, lastID: Int?) async throws -> [GalleryMessage] { [] }
        func fetchPoster(id: Int) async throws -> GalleryPosterDetail {
            observed.insert("fixture-poster-\(id)")
            if stage == "maintained-fixtures-success", id == 1 { throw URLError(.resourceUnavailable) }
            return GalleryPosterDetail(anonymous: false, claim: poster.claim, commentNum: 0, createTime: "", editTime: "", id: stage == "entity-identity-failure" ? id + 1 : id,
                images: stage == "fixture-image-missing-failure" ? [] : [.init(mid: "fixture", url: "https://image.invalid/fixture.png", lowUrl: "")],
                like: false, likeNum: 0, own: false, plugins: "", public: true, tags: [], text: "fixture", title: "fixture", updateTime: "", user: user)
        }
        func fetchComments(objectID: String, order: CommunityCommentOrder, page: Int?) async throws -> GalleryPageBatch<CommunityComment> {
            observed.insert("gallery-comments-\(page ?? 0)")
            if stage == "gallery-comment-page-failure", page != nil { throw URLError(.cannotParseResponse) }
            if stage == "gallery-comment-page-failure" { return .init(items: [comment(object: objectID)], nextSourcePage: 3, canLoadMore: true) }
            return .init(items: [], nextSourcePage: (page ?? 0) + 1, canLoadMore: false)
        }
        func fetchClaims() async throws -> [CommunityClaim] { [poster.claim] }
        func fetchReportTypes() async throws -> [GalleryReportType] { [] }
        func fetchCourses(search: String, page: Int) async throws -> [CourseSummary] {
            if stage == "empty-list-failure" { return [] }
            guard page == 0 || stage == "repeated-page-failure" else { return [] }
            return [CourseSummary(detail: CourseDetail(id: 1, name: "fixture", number: "COURSE", credit: 1, likeNum: 0, commentNum: 0, rate: 0, teachersName: "", teachersNumber: "", like: false))]
        }
        func fetchCourse(id: Int) async throws -> CourseDetail {
            observed.insert("course-detail")
            observed.insert("fixture-course-\(id)")
            if stage == "maintained-fixtures-success", id == 1 { throw URLError(.resourceUnavailable) }
            if stage == "community-failure" { throw URLError(.timedOut) }
            return CourseDetail(id: stage == "entity-identity-failure" ? id + 1 : id, name: "fixture", number: "COURSE", credit: 1, likeNum: 0, commentNum: 0, rate: 0, teachersName: "", teachersNumber: "", like: false)
        }
        func fetchCourseHistories(number: String) async throws -> [CourseHistoryGrade] { [] }
        func fetchComments(courseID: Int, page: Int?) async throws -> [CommunityComment] {
            observed.insert("course-comments-\(page ?? 0)")
            if stage == "course-comment-page-failure" { return [comment(object: "course\(courseID)")] }
            return []
        }
        func fetchPapers(search: String?, order: PaperSortOrder, page: Int) async throws -> [PaperSummary] {
            observed.insert("paper-list")
            if stage == "empty-list-failure" { return [] }
            if stage == "paper-\(order.requestValue ?? "newest")-order-failure" {
                return page == 0 ? (0..<2).map { index in
                    PaperSummary(id: index + 1, title: "fixture", intro: "", likeNum: index, commentNum: index,
                        updateTime: index == 0 ? "2026-01-01T00:00:00Z" : "2026-01-02T00:00:00Z")
                } : []
            }
            guard page == 0 else { return [] }
            return [PaperSummary(id: 1, title: "fixture", intro: "", likeNum: 0, commentNum: 0, updateTime: "2026-01-01T00:00:00Z")]
        }
        func fetchPaper(id: Int) async throws -> PaperDetail {
            observed.insert("fixture-paper-\(id)")
            if stage == "maintained-fixtures-success", id == 1 { throw URLError(.resourceUnavailable) }
            return PaperDetail(id: stage == "entity-identity-failure" ? id + 1 : id, title: "fixture", intro: "", content: stage == "paper-content-failure" ? "" : smokePaperContent, createTime: "", updateTime: "", updateUser: user,
                anonymous: false, likeNum: 0, commentNum: 0, publicEdit: false, like: false, own: false)
        }
        func fetchPreviewMetadata(id: Int) async throws -> PaperPreviewMetadata { try await fetchPaper(id: id).previewMetadata }
        func fetchComments(paperID: Int, order: CommunityCommentOrder, page: Int?) async throws -> [CommunityComment] {
            observed.insert("paper-comments-\(page ?? 0)")
            if stage == "paper-comment-page-failure", page != nil { throw URLError(.cannotParseResponse) }
            return stage == "paper-comment-page-failure" ? [comment(object: "paper\(paperID)")] : []
        }
        func fetchMyInfo() async throws -> MineUserInfo { observed.insert("mine"); return try await fetchUserInfo(id: 1) }
        func fetchUserInfo(id: Int) async throws -> MineUserInfo { MineUserInfo(user: user, followingNum: 0, followerNum: 0, following: false, follower: false, own: true) }
        func fetchUserPosters(userID: Int, page: Int) async throws -> [CommunityPoster] { page == 0 ? [poster] : [] }
        func fetchMyPosters(page: Int) async throws -> [CommunityPoster] { page == 0 ? [poster] : [] }
        func fetchFollowers(page: Int) async throws -> [CommunityUser] { [] }
        func fetchFollowings(page: Int) async throws -> [CommunityUser] { [] }
        func fetchCurrentTermOnly() async throws -> String {
            if stage == "all-sms-success" && !webvpnVerified { throw ScheduleServiceError.secondFactorRequired(smsChallenge) }
            return "fixture-1"
        }
        func fetchAvailableTerms() async throws -> [String] { ["fixture-1"] }
        func syncCourses(term: String?) async throws -> CourseSyncPayload {
            observed.insert("schedule")
            rawResponse?(Data("course-response".utf8))
            let exams: [ExamRecord] = stage == "invalid-exam-failure" || stage == "pending-exam-success"
                ? [.init(id: "exam", term: "fixture-1", name: stage == "invalid-exam-failure" ? "" : "待排课程", courseID: "",
                    teacher: "", classroom: "", dateString: "", beginTime: "", endTime: "", examMode: "", seatID: "")] : []
            return CourseSyncPayload(term: stage == "schedule-term-failure" ? "other-term" : term ?? "fixture-1", firstDayString: "2026-03-02", sourceFirstDayString: "2026-03-02",
                normalizationOffset: 0, rawWeeksByCourse: [], courses: [], exams: exams)
        }
        func submitSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge, term: String?) async throws -> CourseSyncPayload { try await syncCourses(term: term) }
        func submitSMSCodeForTeachingCenterAuthentication(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws { webvpnVerified = true }
        func prepareTeachingCenterAccess() async throws {}
        func fetchCampuses() async throws -> [CampusRecord] { [CampusRecord(id: "campus", name: "fixture", code: "campus")] }
        func fetchBuildings(campusCode: String?) async throws -> [BuildingRecord] { [BuildingRecord(id: "building", name: "fixture", buildingCode: "building", campusName: "fixture", campusCode: stage == "campus-selection-failure" ? "other" : "campus")] }
        func fetchClassrooms(buildingID: String, term: String) async throws -> [ClassroomRecord] {
            [ClassroomRecord(id: "room", name: "fixture", busyTimeCodes: stage == "invalid-classroom-failure" ? [0] : [])]
        }
        func fetchEclassDDLEvents(schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws -> EclassDDLResult {
            if stage == "all-sms-success" && !ssoVerified {
                let handler = try #require(schoolSMSCodeHandler)
                _ = try await handler(.init(maskedPhone: "***", purpose: "school_sso_second_factor"))
                ssoVerified = true
            }
            return try await fetchEclassDDLEventsForPreflight()
        }
        func fetchEclassDDLEventsForPreflight() async throws -> EclassDDLResult {
            observed.insert("eclass")
            return EclassDDLResult(events: [], courseCount: 1, activityCount: 0, activityTypes: [:], homeworkWithoutDeadlineCount: 0)
        }
        func refreshLexueCalendarURL(schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws -> String { try await refreshLexueCalendarURLForPreflight() }
        func refreshLexueCalendarURLForPreflight() async throws -> String { "https://lexue.bit.edu.cn/fixture.ics" }
        func syncDDLEventsForPreflight(existingEvents: [DDLEventRecord], storedURL: String) async throws -> DDLSyncPayload {
            observed.insert("lexue")
            if stage == "ddl-failure" { throw URLError(.timedOut) }
            if stage == "ddl-invalid-calendar-failure" { throw ScheduleServiceError.invalidCalendarData }
            return DDLSyncPayload(url: storedURL, events: [])
        }
        func startScoreChallenge() async throws -> BITLoginAuthenticationChallenge {
            if stage == "all-sms-success" { throw ScoreServiceError.secondFactorRequired(smsChallenge) }
            return BITLoginAuthenticationChallenge(challengeID: "fixture", accessToken: "fixture", status: "authenticated", maskedPhone: nil, expiresIn: 60) }
        func fetchScores(detail: Bool, authenticatedBy challenge: BITLoginAuthenticationChallenge) async throws -> [ScoreRow] {
            guard stage == "all-score-mismatch-failure" else { return [] }
            return [ScoreRow(index: 0, headers: ["课程编号", "课程名称", "成绩", "开课学期"],
                values: ["CS101", "课程", detail ? "80" : "90", "2025"])]
        }
        func submitScoreSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> BITLoginAuthenticationChallenge { .init(challengeID: "fixture", accessToken: "fixture", status: "authenticated", maskedPhone: nil, expiresIn: 60) }
        func fetchTrustedTranscriptPages() async throws -> [Data] {
            if stage == "all-sms-success" { throw ScoreServiceError.secondFactorRequired(smsChallenge) }
            return [image]
        }
        func submitTranscriptSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> [Data] { [image] }
    }

    private final class External: HTTPTransport {
        let image: Data
        let redirectHost: String?
        let aasaStage: String
        var requests: [URLRequest] = []
        var imageBudgets: [Int?] = []
        init(image: Data, redirectHost: String? = nil, aasaStage: String = "") {
            self.image = image; self.redirectHost = redirectHost; self.aasaStage = aasaStage
        }
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            if let path = request.url?.path, path.hasSuffix(".jpg") || path.hasSuffix(".png") {
                imageBudgets.append(maximumBytes)
                if aasaStage == "image-budget-failure", maximumBytes != nil { throw HTTPClientError.responseTooLarge }
            }
            let result = try await data(for: request)
            if let maximumBytes, result.0.count > maximumBytes { throw HTTPClientError.responseTooLarge }
            return result
        }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            let url = try #require(request.url)
            var finalURL = url
            let data: Data
            var status = 200
            var headers: [String: String] = [:]
            if request.httpMethod == "OPTIONS" {
                #expect(request.value(forHTTPHeaderField: "Origin") == "https://bit101.cn")
                #expect(request.value(forHTTPHeaderField: "Access-Control-Request-Method") == "POST")
                #expect(request.value(forHTTPHeaderField: "Access-Control-Request-Headers") == "content-type")
                data = Data(); status = 204; headers["Access-Control-Allow-Origin"] = "*"
                headers["Access-Control-Allow-Methods"] = aasaStage == "cors-method-failure" ? "OPTIONS" : "post, OPTIONS"
                headers["Access-Control-Allow-Headers"] = aasaStage == "cors-header-failure" ? "x-custom" : "Content-Type"
            } else if url.path.hasSuffix("apple-app-site-association") {
                let json = #"{"applinks":{"details":[{"appID":"Y2T72736G3.BIT101-dev.BIT101-iOS","paths":["/gallery/*","/course/*","/paper/*"]}]}}"#
                data = Data((aasaStage == "aasa-exclusion-failure" ? json.replacingOccurrences(of: "\"/gallery/*\"", with: "\"NOT /gallery/*\",\"/gallery/*\"") : json).utf8)
                headers["Content-Type"] = aasaStage == "aasa-mime-failure" ? "text/plain" : "application/json"
                if aasaStage == "aasa-redirect-failure" { status = 302; headers["Location"] = "/association" }
                if aasaStage == "aasa-followed-redirect-failure" { finalURL = AppURL.required("https://open.aihelpme.dev/association") }
            } else if url.host == "itunes.apple.com" {
                #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "requestTime" } == true)
                #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
                #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
                data = Data(#"{"resultCount":1,"results":[{"version":"1.0","bundleId":"BIT101-dev.BIT101-iOS","currentVersionReleaseDate":"2026-01-01T00:00:00Z","trackViewUrl":"https://apps.apple.com/app/id6761147125"}]}"#.utf8)
            } else if url.host == "update.aihelpme.dev" {
                data = Data(#"{"schema_version":1,"enabled":false}"#.utf8)
            } else if url.path.hasSuffix(".jpg") || url.path.hasSuffix(".png") {
                if aasaStage == "paper-image-failure", url.path == "/paper.png" { throw URLError(.resourceUnavailable) }
                data = image
            } else {
                if url.path.isEmpty || url.path == "/" { finalURL = try #require(URL(string: "https://bit101.cn/gallery/")) }
                data = Data("<html><a href=\"bit101:/\(url.path)\">fixture</a></html>".utf8)
            }
            if url.host == redirectHost { status = 302 }
            return (data, try #require(HTTPURLResponse(url: finalURL, statusCode: status, httpVersion: nil, headerFields: headers)))
        }
    }

    @Test("Full smoke orchestration preserves success, intermediate failures and subsequent scopes", arguments:
        ["all-success", "all-sms-success", "all-sms-not-required", "community-failure", "schedule-success", "ddl-success", "ddl-failure", "ddl-invalid-calendar-failure", "raw-write-failure",
         "app-store-redirect-failure", "emergency-redirect-failure", "aasa-redirect-failure", "aasa-followed-redirect-failure",
         "aasa-mime-failure", "aasa-exclusion-failure", "image-budget-failure", "entity-identity-failure", "repeated-page-failure",
         "gallery-comment-page-failure", "course-comment-page-failure", "paper-comment-page-failure", "cors-method-failure", "cors-header-failure",
         "schedule-term-failure", "historical-term-success", "maintained-fixtures-success", "feed-images-missing-success", "fixture-image-missing-failure",
         "missing-fixtures-failure", "fixture-course-number-failure", "empty-list-failure", "all-score-mismatch-failure",
         "bot-classification-failure", "paper-like-order-failure", "paper-comment-order-failure", "paper-newest-order-failure", "paper-content-failure", "paper-image-failure", "campus-selection-failure",
         "invalid-exam-failure", "pending-exam-success", "invalid-classroom-failure",
         "school-independent-success", "transcript-independent-success", "schedule-independent-success", "ddl-independent-success"])
    func completeOrchestration(stage: String) async throws {
        let image = try #require(UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { $0.fill(CGRect(x: 0, y: 0, width: 1, height: 1)) }.pngData())
        let services = Services(stage: stage, image: image)
        let productionServices = Services(stage: stage, image: image)
        let redirectHost = stage == "app-store-redirect-failure" ? "itunes.apple.com"
            : stage == "emergency-redirect-failure" ? "update.aihelpme.dev" : nil
        let external = External(image: image, redirectHost: redirectHost, aasaStage: stage)
        let association = External(image: image, aasaStage: stage)
        let externalClient = HTTPClient(transport: external, observer: nil)
        let files = PreferenceMemoryFiles()
        let media = AppMedia.makeEnvironment(files: files, previewStorage: MediaPreviewStorage(files: files),
            imageHTTPClient: externalClient, avatarHTTPClient: externalClient)
        var reports: [ReleaseNetworkSmokeReport] = []
        var feedback = 0
        var rawWrites = 0
        var loginChecks = 0
        let sessionEvidence = ["初始账号资料 ID：1", "无效凭据切换：认证拒绝", "恢复账号资料 ID：1"]
        let dependencies = ReleaseNetworkSmokeDependencies(requiresRequestEvidence: false, checkLogin: {
            loginChecks += 1
            if stage.contains("independent") { throw URLError(.notConnectedToInternet) }
            return "fixture"
        }, writeReport: { reports.append($0) },
            clearRawCourseResponse: {}, writeRawCourseResponse: { _, runID in
                rawWrites += 1
                #expect(runID == stage)
                if stage == "raw-write-failure" { throw CocoaError(.fileWriteNoPermission) }
            }, makeGallery: { services }, makeCourses: { services }, makePapers: { services }, makeMine: { services },
            productionSessionProbe: { sessionEvidence }, externalHTTPClient: externalClient,
            imageProbe: { try await media.verifyRemoteImage(at: $0) }, aasaHTTPClient: HTTPClient(transport: association, observer: nil),
            feedbackProbe: { _ in feedback += 1 },
            loadScheduleCache: { ScheduleCache() }, makeScores: { services }, makeSchedule: { handler in services.rawResponse = handler; return services },
            makeProductionSchedule: { productionServices }, makeEclassSchedule: { services })
        let scope: NetworkSmokeScope = stage.hasPrefix("school-") ? .school : stage.hasPrefix("transcript-") ? .transcript : stage.hasPrefix("all-") || redirectHost != nil || stage.hasPrefix("aasa") ? .all : stage == "community-failure" || stage == "image-budget-failure" || stage == "entity-identity-failure" || stage == "repeated-page-failure" || stage.contains("comment-page") || stage.hasPrefix("cors") || stage.hasPrefix("bot-") || stage.hasPrefix("paper-") || stage.contains("fixtures") || stage == "feed-images-missing-success" || stage == "fixture-image-missing-failure" || stage == "fixture-course-number-failure" || stage == "empty-list-failure" ? .bit101 : stage.hasPrefix("ddl") ? .ddl : .schedule
        let runner = ReleaseNetworkSmokeRunner(dependencies: dependencies)
        let smsHandler: SchoolSMSCodeHandler = { _ in "fixture-code" }
        let report = await runner.run(scope: scope, runID: stage, capture: stage == "raw-write-failure" ? .rawCourseResponse : .none,
            term: stage == "historical-term-success" ? "historical-1" : nil,
            fixtures: stage == "missing-fixtures-failure" ? nil : NetworkSmokeFixtures(posterID: 41, courseID: 43,
                courseNumber: stage == "fixture-course-number-failure" ? "OTHER" : "COURSE", paperID: 45),
            schoolSMSCodeHandler: stage.hasPrefix("all-sms-") ? smsHandler : nil)
        if scope.includes(.bit101) {
            #expect(services.observed.isSuperset(of: ["gallery-follow", "gallery-hot", "gallery-newest"]))
            #expect(report.executedProbes.contains("gallery.following") && report.executedProbes.contains("gallery.hot"))
        }
        #expect(report.passed == (!stage.hasSuffix("failure") || stage == "missing-fixtures-failure"), "\(stage): \(report.failures)")
        if stage == "maintained-fixtures-success" {
            #expect(services.observed.isSuperset(of: ["fixture-poster-41", "fixture-course-43", "fixture-paper-45"]))
            #expect(external.requests.contains { $0.url?.path == "/paper.png" })
        }
        if stage == "feed-images-missing-success" || stage == "maintained-fixtures-success" {
            #expect(external.requests.contains { $0.url?.path == "/fixture.png" })
        }
        if stage == "fixture-image-missing-failure" {
            #expect(report.failures.contains { $0.contains("gallery.image") })
        }
        if stage == "missing-fixtures-failure" {
            #expect(!report.coverageComplete && report.skippedProbes.contains { $0.contains("维护对象配置") })
        }
        #expect(report.productionSessionEvidence == (scope.includes(.bit101) ? sessionEvidence : []))
        if stage == "all-sms-success" {
            #expect(report.schoolSMSCoverage == "verified")
            #expect(services.webvpnVerified && productionServices.webvpnVerified)
            #expect(Set(report.verifiedSMSProbes.filter { $0.purpose == "webvpn" }.map(\.probe)) == ["school.session", "schedule.current-term"])
            #expect(Set(report.verifiedSMSProbes.map(\.purpose)) == NetworkSmokeScope.all.requiredSMSPurposes)
        }
        if stage.hasPrefix("all-sms-") {
            #expect(Set(report.authenticatedSchoolProbes.map(\.purpose)) == NetworkSmokeScope.all.requiredSMSPurposes)
            #expect(Set(report.requestedSMSPurposes) == Set(report.verifiedSMSProbes.map(\.purpose)))
            #expect(report.coverageComplete)
        }
        if stage == "all-sms-not-required" {
            #expect(report.schoolSMSCoverage == "not_required")
            #expect(report.verifiedSMSProbes.isEmpty && report.requestedSMSPurposes.isEmpty)
        }
        if stage == "repeated-page-failure" {
            #expect(report.failures.contains { $0.contains("course.list") })
            #expect(services.observed.contains("fixture-course-43"))
            #expect(report.coverageComplete)
        }
        if stage == "missing-fixtures-failure" {
            #expect(Set(scope.requiredProbes).subtracting(report.executedProbes)
                == ["gallery.detail", "gallery.image", "gallery.comments", "gallery.web", "course.detail", "course.comments",
                    "course.history", "course.web", "paper.detail", "paper.image", "paper.comments", "paper.web"])
        } else {
            let deferred: Set<String> = stage == "entity-identity-failure" ? ["paper.image", "gallery.image"]
                : stage == "paper-content-failure" ? ["paper.image"] : stage == "campus-selection-failure" ? ["classroom.occupancy"] : []
            #expect(Set(report.executedProbes) == Set(scope.requiredProbes).subtracting(deferred))
        }
        #expect(reports.count == 1 && reports[0].passed == report.passed)
        #expect(loginChecks == (scope.includes(.authentication) ? 1 : 0))
        if scope.includes(.bit101) { #expect(feedback == 1 && services.observed.contains("mine") && services.observed.contains("paper-list")) }
        #expect(association.requests.count == (scope.includes(.bit101) ? 1 : 0))
        #expect(external.requests.allSatisfy { $0.url?.path.hasSuffix("apple-app-site-association") == false })
        if scope.includes(.bit101) {
            #expect(!external.imageBudgets.isEmpty && external.imageBudgets.allSatisfy { $0 == RemoteImageResourceLimits.maximumEncodedBytes })
        }
        if stage == "entity-identity-failure" {
            #expect(report.failures.count == 3)
            for name in ["gallery.detail", "course.detail", "paper.detail"] { #expect(report.failures.contains { $0.contains(name) }) }
        }
        if stage == "paper-content-failure" || stage == "paper-image-failure" || stage == "campus-selection-failure" {
            let probe = stage == "paper-content-failure" ? "paper.detail" : stage == "paper-image-failure" ? "paper.image" : "classroom.buildings"
            #expect(report.failures.count == 1 && report.failures[0].contains(probe))
        }
        if stage.contains("comment-page") {
            let kind = String(stage.prefix { $0 != "-" })
            let probe = kind == "gallery" ? "gallery.comments" : kind == "course" ? "course.comments" : "paper.comments"
            #expect(report.failures.count == 1 && report.failures[0].contains(probe))
            #expect(services.observed.contains("\(kind)-comments-\(kind == "gallery" ? 3 : 1)"))
        }
        if stage.hasPrefix("cors") { #expect(report.failures.count == 1 && report.failures[0].contains("feedback.preflight")) }
        if stage.hasPrefix("aasa") { #expect(report.failures.count == 1 && report.failures[0].contains("web.association")) }
        if scope.includes(.schedule) { #expect(services.observed.contains("schedule")) }
        if scope.includes(.schedule) {
            #expect(report.currentTerm == "fixture-1")
            #expect(report.requestedTerm == (stage == "historical-term-success" ? "historical-1" : nil))
            #expect(report.validatedTerm == (stage == "schedule-term-failure" || stage == "invalid-exam-failure" ? nil : report.requestedTerm ?? "fixture-1"))
        }
        if report.executedProbes.contains("classroom.occupancy") {
            let occupancy = try #require(report.requestEvidence.first { $0.probe == "classroom.occupancy" })
            #expect(occupancy.expectedParameters == ["XNXQDM": report.requestedTerm ?? "fixture-1", "JXLDM": "building",
                "RQ": ScheduleDateCodec.formatDate(Date()), "XQDM": "1", "XNDM": stage == "historical-term-success" ? "historical" : "fixture"])
        }
        if scope.includes(.ddl) { #expect(services.observed.isSuperset(of: ["eclass", "lexue"])) }
        if stage == "raw-write-failure" { #expect(rawWrites == 1 && report.failures.contains { $0.contains("原始课表采样写入") }) }
        if stage == "ddl-failure" || stage == "ddl-invalid-calendar-failure" {
            #expect(report.failures.count == 1 && report.failures[0].contains("lexue.ddl"))
        }
        if let redirectHost {
            let probe = redirectHost == "itunes.apple.com" ? "update.app-store" : "update.emergency"
            #expect(report.failures.count == 1 && report.failures[0].contains(probe))
        }
        let next = await runner.run(scope: .transcript, runID: "next", schoolSMSCodeHandler: stage == "all-sms-success" ? smsHandler : nil)
        #expect(next.passed && next.failures.isEmpty && next.coverageComplete)
        #expect(reports.count == 2)
    }
}
#endif
