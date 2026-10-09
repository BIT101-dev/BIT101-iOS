#if DEBUG
import Foundation
import Testing
import UIKit
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
@testable import BIT101_iOS

@Suite("Network smoke coverage")
@MainActor
struct NetworkSmokeCoverageTests {
    @Test func imageProbeUsesAnAvailableResourceAcrossTheSampledList() {
        let empty = CommunityImage(mid: "empty", url: "", lowUrl: "")
        let image = CommunityImage(mid: "image", url: "https://image.invalid/full", lowUrl: "https://image.invalid/low")
        #expect(NetworkSmokePaging.imageURL(in: [empty, image]) == image.lowUrl)
        #expect(NetworkSmokePaging.imageURL(in: [empty]) == nil)
        #expect(NetworkSmokePaging.imageURL(in: [CommunityImage(mid: "full", url: image.url, lowUrl: "")]) == image.url)
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
            _ = try await NetworkSmokePaging.arrayPage { page in
                pages.append(page)
                if page == 1 { throw URLError(.timedOut) }
                return [user(1)]
            }
        }
        #expect(pages == [0, 1])
        pages = []
        let first: GalleryPageBatch<CommunityUser> = try await NetworkSmokePaging.batch { page in
            pages.append(page)
            return .init(items: [], nextSourcePage: page == 0 ? 4 : 5, canLoadMore: page == 0, sourceIDs: [page + 1])
        }
        #expect(first.items.isEmpty && pages == [0, 4])
        await #expect(throws: URLError.self) {
            let _: GalleryPageBatch<CommunityUser> = try await NetworkSmokePaging.batch { page in
                .init(items: [user(1)], nextSourcePage: 1, canLoadMore: true)
            }
        }
    }

    @Test func repeatedPagesFailAndPartialOverlapOrTerminalPagesAdvance() async throws {
        for repeated in [true, false] {
            await #expect(throws: URLError.self) {
                _ = try await NetworkSmokePaging.arrayPage { page in
                    [user(repeated || page == 0 ? 1 : 0)]
                }
            }
            await #expect(throws: URLError.self) {
                let _: GalleryPageBatch<CommunityUser> = try await NetworkSmokePaging.batch { page in
                    .init(items: [], nextSourcePage: page + 1, canLoadMore: true,
                        sourceIDs: [repeated || page == 0 ? 1 : 0])
                }
            }
        }
        for terminal in [false, true] {
            var pages: [Int] = []
            _ = try await NetworkSmokePaging.arrayPage { page in
                pages.append(page)
                return page == 0 ? [user(1), user(2)] : terminal ? [] : [user(2), user(3)]
            }
            #expect(pages == [0, 1])
            pages = []
            let _: GalleryPageBatch<CommunityUser> = try await NetworkSmokePaging.batch { page in
                pages.append(page)
                return .init(items: [], nextSourcePage: page + 1, canLoadMore: page == 0,
                    sourceIDs: page == 0 ? [1, 2] : terminal ? [] : [2, 3])
            }
            #expect(pages == [0, 1])
        }
    }

    @Test func terminalPagesExerciseContinuationAndMessagesUseTheirActualCursor() async throws {
        var pages: [Int] = []
        let empty: [CommunityUser] = try await NetworkSmokePaging.arrayPage { page in pages.append(page); return [] }
        #expect(empty.isEmpty && pages == [0, 1])
        let data = Data(#"{"from_user":{},"id":9,"link_obj":"poster1","obj":"poster1","text":"","update_time":""}"#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let message = try decoder.decode(GalleryMessage.self, from: data)
        var cursors: [Int?] = []
        _ = try await NetworkSmokePaging.messages { cursor in cursors.append(cursor); return cursor == Int.max ? [message] : [] }
        #expect(cursors == [Int.max, 9])
        cursors = []
        _ = try await NetworkSmokePaging.messages { cursor in cursors.append(cursor); return [] }
        #expect(cursors == [Int.max, 1])
        await #expect(throws: URLError.self) {
            _ = try await NetworkSmokePaging.messages { _ in [message] }
        }
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
        _ = try await NetworkSmokePaging.messages { cursor in
            requests += 1
            if emptyFirstPage && requests == 2 { messages = [message]; unread += 1 }
            let rows = messages.filter { cursor == nil || cursor == 0 || $0.id < (cursor ?? 0) }
            if (cursor == nil || cursor == 0) && !rows.isEmpty { unread = 0 }
            return rows
        }
        #expect(requests == 2 && unread == (emptyFirstPage ? 4 : 3))
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
        #expect(try await operations.comment("poster9", "fixture", { uploads.append($0) }, {}).images.map(\.mid) == ["uploaded"])
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
                if comment { _ = try await operations.comment("poster9", "fixture", record, {}) }
                else { _ = try await operations.create(.poster, "fixture", record, {}) }
            }
        }
        #expect(route.calls.filter { $0.1 == "POST" && $0.0 != "/upload/image" }.count == writes)
        route.failUpload = true
        for comment in [false, true] {
            await #expect(throws: (any Error).self) {
                let submit: CommunityWriteSmoke.Operations.RecordSubmission = { Issue.record("图片上传完成后记录业务提交") }
                if comment { _ = try await operations.comment("poster9", "fixture", { _ in }, submit) }
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
        private var comment: CommunityComment {
            CommunityComment(id: 1, obj: "fixture", images: [], user: user, anonymous: false,
                createTime: "", updateTime: "", like: false, likeNum: 0, commentNum: 0, own: false,
                rate: 0, replyUser: user, replyObj: "", text: "fixture", sub: [])
        }
        func fetchFeed(kind: GalleryFeedKind, page: Int?) async throws -> GalleryPageBatch<CommunityPoster> {
            observed.insert("gallery-\(kind.rawValue)"); return posterPage(page ?? 0)
        }
        private func posterPage(_ page: Int) -> GalleryPageBatch<CommunityPoster> {
            .init(items: page == 0 ? [poster] : [], nextSourcePage: page + 1, canLoadMore: false)
        }
        func fetchRecommendPage(sourcePage: Int) async throws -> GalleryPageBatch<CommunityPoster> { posterPage(sourcePage) }
        func fetchBotFeed(startPage: Int) async throws -> GalleryPageBatch<CommunityPoster> { posterPage(startPage) }
        func searchPosters(query: GallerySearchQuery, page: Int?) async throws -> GalleryPageBatch<CommunityPoster> {
            posterPage(page ?? 0)
        }
        func fetchMessageUnreadCounts() async throws -> GalleryMessageUnreadCounts { GalleryMessageUnreadCounts() }
        func fetchMessages(type: GalleryMessageType, lastID: Int?) async throws -> [GalleryMessage] { [] }
        func fetchPoster(id: Int) async throws -> GalleryPosterDetail {
            GalleryPosterDetail(anonymous: false, claim: poster.claim, commentNum: 0, createTime: "", editTime: "", id: stage == "entity-identity-failure" ? id + 1 : id, images: poster.images,
                like: false, likeNum: 0, own: false, plugins: "", public: true, tags: [], text: "fixture", title: "fixture", updateTime: "", user: user)
        }
        func fetchComments(objectID: String, order: CommunityCommentOrder, page: Int?) async throws -> GalleryPageBatch<CommunityComment> {
            observed.insert("gallery-comments-\(page ?? 0)")
            if stage == "gallery-comment-page-failure", page != nil { throw URLError(.cannotParseResponse) }
            if stage == "gallery-comment-page-failure" { return .init(items: [comment], nextSourcePage: 3, canLoadMore: true) }
            return .init(items: [], nextSourcePage: (page ?? 0) + 1, canLoadMore: false)
        }
        func fetchClaims() async throws -> [CommunityClaim] { [poster.claim] }
        func fetchReportTypes() async throws -> [GalleryReportType] { [] }
        func fetchCourses(search: String, page: Int) async throws -> [CourseSummary] {
            guard page == 0 || stage == "repeated-page-failure" else { return [] }
            return [CourseSummary(detail: CourseDetail(id: 1, name: "fixture", number: "COURSE", credit: 1, likeNum: 0, commentNum: 0, rate: 0, teachersName: "", teachersNumber: "", like: false))]
        }
        func fetchCourse(id: Int) async throws -> CourseDetail {
            observed.insert("course-detail")
            if stage == "community-failure" { throw URLError(.timedOut) }
            return CourseDetail(id: stage == "entity-identity-failure" ? id + 1 : id, name: "fixture", number: "COURSE", credit: 1, likeNum: 0, commentNum: 0, rate: 0, teachersName: "", teachersNumber: "", like: false)
        }
        func fetchCourseHistories(number: String) async throws -> [CourseHistoryGrade] { [] }
        func fetchComments(courseID: Int, page: Int?) async throws -> [CommunityComment] {
            observed.insert("course-comments-\(page ?? 0)")
            if stage == "course-comment-page-failure" { return [comment] }
            return []
        }
        func fetchPapers(search: String?, order: PaperSortOrder, page: Int) async throws -> [PaperSummary] {
            observed.insert("paper-list")
            guard page == 0 else { return [] }
            return [PaperSummary(id: 1, title: "fixture", intro: "", likeNum: 0, commentNum: 0, updateTime: "")]
        }
        func fetchPaper(id: Int) async throws -> PaperDetail {
            PaperDetail(id: stage == "entity-identity-failure" ? id + 1 : id, title: "fixture", intro: "", content: "fixture", createTime: "", updateTime: "", updateUser: user,
                anonymous: false, likeNum: 0, commentNum: 0, publicEdit: false, like: false, own: false)
        }
        func fetchPreviewMetadata(id: Int) async throws -> PaperPreviewMetadata { try await fetchPaper(id: id).previewMetadata }
        func fetchComments(paperID: Int, order: CommunityCommentOrder, page: Int?) async throws -> [CommunityComment] {
            observed.insert("paper-comments-\(page ?? 0)")
            if stage == "paper-comment-page-failure", page != nil { throw URLError(.cannotParseResponse) }
            return stage == "paper-comment-page-failure" ? [comment] : []
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
            return CourseSyncPayload(term: stage == "schedule-term-failure" ? "other-term" : term ?? "fixture-1", firstDayString: "2026-03-02", sourceFirstDayString: "2026-03-02",
                normalizationOffset: 0, rawWeeksByCourse: [], courses: [], exams: [])
        }
        func submitSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge, term: String?) async throws -> CourseSyncPayload { try await syncCourses(term: term) }
        func submitSMSCodeForTeachingCenterAuthentication(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws { webvpnVerified = true }
        func prepareTeachingCenterAccess() async throws {}
        func fetchCampuses() async throws -> [CampusRecord] { [CampusRecord(id: "campus", name: "fixture", code: "campus")] }
        func fetchBuildings(campusCode: String?) async throws -> [BuildingRecord] { [BuildingRecord(id: "building", name: "fixture", buildingCode: "building", campusName: "fixture", campusCode: "campus")] }
        func fetchClassrooms(buildingID: String, term: String) async throws -> [ClassroomRecord] { [ClassroomRecord(id: "room", name: "fixture", busyTimeCodes: [])] }
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
        func fetchScores(detail: Bool, authenticatedBy challenge: BITLoginAuthenticationChallenge) async throws -> [ScoreRow] { [] }
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
         "schedule-term-failure", "historical-term-success"])
    func completeOrchestration(stage: String) async throws {
        let image = try #require(UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { $0.fill(CGRect(x: 0, y: 0, width: 1, height: 1)) }.pngData())
        let services = Services(stage: stage, image: image)
        let productionServices = Services(stage: stage, image: image)
        let redirectHost = stage == "app-store-redirect-failure" ? "itunes.apple.com"
            : stage == "emergency-redirect-failure" ? "update.aihelpme.dev" : nil
        let external = External(image: image, redirectHost: redirectHost, aasaStage: stage)
        let association = External(image: image, aasaStage: stage)
        var reports: [ReleaseNetworkSmokeReport] = []
        var feedback = 0
        var rawWrites = 0
        let sessionEvidence = ["初始账号资料 ID：1", "无效凭据切换：认证拒绝", "恢复账号资料 ID：1"]
        let dependencies = ReleaseNetworkSmokeDependencies(requiresRequestEvidence: false, checkLogin: { "fixture" }, writeReport: { reports.append($0) },
            clearRawCourseResponse: {}, writeRawCourseResponse: { _, runID in
                rawWrites += 1
                #expect(runID == stage)
                if stage == "raw-write-failure" { throw CocoaError(.fileWriteNoPermission) }
            }, makeGallery: { services }, makeCourses: { services }, makePapers: { services }, makeMine: { services },
            productionSessionProbe: { sessionEvidence }, externalHTTPClient: HTTPClient(transport: external, observer: nil), aasaHTTPClient: HTTPClient(transport: association, observer: nil),
            feedbackProbe: { _ in feedback += 1 },
            loadScheduleCache: { ScheduleCache() }, makeScores: { services }, makeSchedule: { handler in services.rawResponse = handler; return services },
            makeProductionSchedule: { productionServices }, makeEclassSchedule: { services })
        let scope: NetworkSmokeScope = stage.hasPrefix("all-") || redirectHost != nil || stage.hasPrefix("aasa") ? .all : stage == "community-failure" || stage == "image-budget-failure" || stage == "entity-identity-failure" || stage == "repeated-page-failure" || stage.contains("comment-page") || stage.hasPrefix("cors") ? .bit101 : stage.hasPrefix("ddl") ? .ddl : .schedule
        let runner = ReleaseNetworkSmokeRunner(dependencies: dependencies)
        let smsHandler: SchoolSMSCodeHandler = { _ in "fixture-code" }
        let report = await runner.run(scope: scope, runID: stage, capture: stage == "raw-write-failure" ? .rawCourseResponse : .none,
            term: stage == "historical-term-success" ? "historical-1" : nil,
            schoolSMSCodeHandler: stage.hasPrefix("all-sms-") ? smsHandler : nil)
        if scope.includes(.bit101) {
            #expect(services.observed.isSuperset(of: ["gallery-follow", "gallery-hot", "gallery-newest"]))
            #expect(report.executedProbes.contains("话廊关注流") && report.executedProbes.contains("话廊热门流"))
        }
        #expect(report.passed == !stage.hasSuffix("failure"))
        #expect(report.productionSessionEvidence == (scope.includes(.bit101) ? sessionEvidence : []))
        if stage == "all-sms-success" {
            #expect(report.schoolSMSCoverage == "verified")
            #expect(services.webvpnVerified && productionServices.webvpnVerified)
            #expect(Set(report.verifiedSMSProbes.filter { $0.purpose == "webvpn" }.map(\.probe)) == ["生产学校会话", "当前学期"])
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
            #expect(report.failures.contains { $0.contains("学业课程列表") })
            #expect(Set(scope.requiredProbes).subtracting(report.executedProbes)
                == ["学业课程详情", "学业课程评论", "学业课程历史成绩", "学业课程网页详情"])
            #expect(!report.coverageComplete)
        } else { #expect(Set(report.executedProbes) == Set(scope.requiredProbes)) }
        #expect(reports.count == 1 && reports[0].passed == report.passed)
        if scope.includes(.bit101) { #expect(feedback == 1 && services.observed.contains("mine") && services.observed.contains("paper-list")) }
        #expect(association.requests.count == (scope.includes(.bit101) ? 1 : 0))
        #expect(external.requests.allSatisfy { $0.url?.path.hasSuffix("apple-app-site-association") == false })
        if scope.includes(.bit101) {
            #expect(!external.imageBudgets.isEmpty && external.imageBudgets.allSatisfy { $0 == RemoteImageResourceLimits.maximumEncodedBytes })
        }
        if stage == "entity-identity-failure" {
            #expect(report.failures.count == 3)
            for name in ["话廊帖子详情", "学业课程详情", "文章详情"] { #expect(report.failures.contains { $0.contains(name) }) }
        }
        if stage.contains("comment-page") {
            let kind = String(stage.prefix { $0 != "-" })
            let probe = kind == "gallery" ? "话廊帖子评论" : kind == "course" ? "学业课程评论" : "文章评论"
            #expect(report.failures.count == 1 && report.failures[0].contains(probe))
            #expect(services.observed.contains("\(kind)-comments-\(kind == "gallery" ? 3 : 1)"))
        }
        if stage.hasPrefix("cors") { #expect(report.failures.count == 1 && report.failures[0].contains("反馈接口跨域预检")) }
        if stage.hasPrefix("aasa") { #expect(report.failures.count == 1 && report.failures[0].contains("App 链接关联配置")) }
        if scope.includes(.schedule) { #expect(services.observed.contains("schedule")) }
        if scope.includes(.schedule) {
            #expect(report.currentTerm == "fixture-1")
            #expect(report.requestedTerm == (stage == "historical-term-success" ? "historical-1" : nil))
            #expect(report.validatedTerm == (stage == "schedule-term-failure" ? nil : report.requestedTerm ?? "fixture-1"))
        }
        if scope.includes(.ddl) { #expect(services.observed.isSuperset(of: ["eclass", "lexue"])) }
        if stage == "raw-write-failure" { #expect(rawWrites == 1 && report.failures.contains { $0.contains("原始课表采样写入") }) }
        if stage == "ddl-failure" || stage == "ddl-invalid-calendar-failure" {
            #expect(report.failures.count == 1 && report.failures[0].contains("乐学 DDL 下载"))
        }
        if let redirectHost {
            let probe = redirectHost == "itunes.apple.com" ? "App Store 更新接口" : "紧急更新配置接口"
            #expect(report.failures.count == 1 && report.failures[0].contains(probe))
        }
        let next = await runner.run(scope: .transcript, runID: "next", schoolSMSCodeHandler: stage == "all-sms-success" ? smsHandler : nil)
        #expect(next.passed && next.failures.isEmpty && next.coverageComplete)
        #expect(reports.count == 2)
    }
}
#endif
