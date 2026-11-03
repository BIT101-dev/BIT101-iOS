#if DEBUG
import Foundation
import ClientCore
@testable import ScheduleInfrastructure
import StorageCore
import MediaKit
import SchedulePorts
import ScorePorts
import ScoreDomain
import UIKit
import Testing
import ScheduleDomain
import TransportCore
import CommunityCore
import CommunityTransport
@testable import GalleryFeature
@testable import PaperFeature
@testable import MineFeature
import CourseFeature
@testable import BIT101_iOS

extension ReleaseNetworkSmokeLifecycleTests {
    final class Services: NetworkSmokeGalleryServicing, NetworkSmokeCourseServicing,
        NetworkSmokePaperServicing,
        NetworkSmokeMineServicing, NetworkSmokeScheduleServicing, ScoreListServicing,
        TrustedTranscriptServicing
    {
        let stage: String
        let image: Data
        var rawResponse: ((Data) -> Void)?
        var observed = Set<String>()
        var webvpnVerified = false
        var ssoVerified = false
        private var verificationChallenge: BITLoginAuthenticationChallenge {
            .init(
                challengeID: "fixture", accessToken: "fixture",
                status: stage == "all-sms-captcha-failure" ? "waiting_captcha" : "waiting_sms",
                maskedPhone: "***", expiresIn: 60)
        }
        init(stage: String, image: Data) {
            self.stage = stage
            self.image = image
        }
        private var user: CommunityUser {
            CommunityUser(
                id: 1, createTime: "", nickname: "fixture",
                avatar: CommunityImage(
                    mid: "image", url: "https://image.invalid/image.png", lowUrl: ""),
                motto: "",
                identity: CommunityIdentity(
                    id: 1, color: "", text: "", createTime: "", updateTime: "", deleteTime: nil)
            )
        }
        private var poster: CommunityPoster {
            makePoster(id: 1, likes: 2, date: "2026-01-02T00:00:00Z")
        }
        private func makePoster(id: Int, likes: Int, date: String) -> CommunityPoster {
            CommunityPoster(
                anonymous: false, claim: CommunityClaim(id: 1, text: "fixture"), commentNum: 0,
                createTime: date, editTime: "", id: id, images: [user.avatar],
                likeNum: likes, public: true, tags: [], text: "fixture", title: "fixture",
                updateTime: "", user: user)
        }
        private func comment(
            object: String, id: Int = 1, likes: Int = 0, date: String = "2026-01-01T00:00:00Z"
        ) -> CommunityComment {
            CommunityComment(
                id: id, obj: object, images: [], user: user, anonymous: false,
                createTime: date, updateTime: "", like: false, likeNum: likes, commentNum: 0,
                own: false,
                rate: 0, replyUser: user, replyObj: "", text: "fixture", sub: [])
        }
        func fetchFeed(kind: GalleryFeedKind, page: Int?) async throws -> GalleryPageBatch<
            CommunityPoster
        > {
            observed.insert("gallery-\(kind.rawValue)")
            return posterPage(page ?? 0)
        }
        private func posterPage(_ page: Int) -> GalleryPageBatch<CommunityPoster> {
            if stage == "feed-images-missing-success" {
                let value = CommunityPoster(
                    anonymous: false, claim: poster.claim, commentNum: 0,
                    createTime: poster.createTime, editTime: "", id: page + 1,
                    images: [],
                    likeNum: 0, public: true, tags: [], text: "fixture", title: "fixture",
                    updateTime: "", user: user)
                return .init(
                    items: page < 2 ? [value] : [], nextSourcePage: page + 1,
                    canLoadMore: page == 0)
            }
            return .init(
                items: page == 0 ? [poster] : [], nextSourcePage: page + 1, canLoadMore: false)
        }
        func fetchRecommendPage(sourcePage: Int) async throws -> GalleryPageBatch<
            CommunityPoster
        > { posterPage(sourcePage) }
        func fetchBotFeed(startPage: Int) async throws -> GalleryPageBatch<CommunityPoster> {
            let batch = posterPage(startPage)
            if stage == "bot-classification-failure" { return batch }
            let items = (stage == "bot-empty-gap" ? [] : batch.items).map {
                CommunityPoster(
                    anonymous: $0.anonymous, claim: $0.claim, commentNum: $0.commentNum,
                    createTime: $0.createTime,
                    editTime: $0.editTime, id: $0.id, images: $0.images, likeNum: $0.likeNum,
                    public: $0.public,
                    tags: ["BOT"], text: $0.text, title: $0.title, updateTime: $0.updateTime,
                    user: $0.user)
            }
            return .init(
                items: items, nextSourcePage: batch.nextSourcePage,
                canLoadMore: batch.canLoadMore, sourceIDs: batch.sourceIDs)
        }
        func searchPosters(query: GallerySearchQuery, page: Int?) async throws
            -> GalleryPageBatch<CommunityPoster>
        {
            observed.insert("gallery-search-\(query.order.rawValue)")
            if query.text == NetworkSmokePaging.excludedSearchText
                && stage != "gallery-search-ignored-failure"
            {
                return .init(items: [], nextSourcePage: (page ?? 0) + 1, canLoadMore: false)
            }
            if query.text.isEmpty {
                let second = makePoster(id: 2, likes: 1, date: "2026-01-01T00:00:00Z")
                let reversed = stage == "poster-\(query.order.rawValue)-order-failure"
                return .init(
                    items: (page ?? 0) == 0
                        ? (reversed ? [second, poster] : [poster, second]) : [],
                    nextSourcePage: (page ?? 0) + 1, canLoadMore: false)
            }
            return .init(
                items: (page ?? 0) == 0
                    ? [
                        makePoster(
                            id: stage == "gallery-search-target-failure" ? 1 : 41, likes: 2,
                            date: "2026-01-02T00:00:00Z")
                    ] : [], nextSourcePage: (page ?? 0) + 1, canLoadMore: false)
        }
        func fetchMessageUnreadCounts() async throws -> GalleryMessageUnreadCounts {
            GalleryMessageUnreadCounts()
        }
        func fetchMessages(type: GalleryMessageType, lastID: Int?) async throws
            -> [GalleryMessage]
        {
            observed.insert("message-read")
            guard stage != "message-empty-gap", let lastID, lastID > 8 else { return [] }
            let id = lastID == Int.max ? 9 : 8
            return try JSONDecoder().decode(
                [GalleryMessage].self,
                from: Data(
                    """
                    [{\"fromUser\":{},\"id\":\(id),\"linkObj\":\"poster1\",\"obj\":\"poster\
                    1\",\"text\":\"\",\"updateTime\":\"\"}]
                    """
                    .utf8))
        }
        func fetchPoster(id: Int) async throws -> GalleryPosterDetail {
            observed.insert("fixture-poster-\(id)")
            if stage == "maintained-fixtures-success", id == 1 {
                throw URLError(.resourceUnavailable)
            }
            return GalleryPosterDetail(
                anonymous: false, claim: poster.claim, commentNum: 0, createTime: "",
                editTime: "", id: stage == "entity-identity-failure" ? id + 1 : id,
                images: stage == "fixture-image-missing-failure"
                    ? []
                    : [
                        .init(
                            mid: "fixture", url: "https://image.invalid/fixture.png", lowUrl: ""
                        )
                    ],
                like: false, likeNum: 0, own: false, plugins: "", public: true, tags: [],
                text: "fixture", title: "fixture", updateTime: "", user: user)
        }
        func fetchComments(objectID: String, order: CommunityCommentOrder, page: Int?)
            async throws -> GalleryPageBatch<CommunityComment>
        {
            observed.insert("gallery-comments-\(page ?? 0)")
            observed.insert("gallery-order-\(order.rawValue)")
            if stage == "gallery-comment-ranking-failure", order == .like {
                return .init(
                    items: [
                        comment(object: objectID, likes: 1),
                        comment(object: objectID, id: 2, likes: 2),
                    ],
                    nextSourcePage: (page ?? 0) + 1, canLoadMore: false)
            }
            if stage == "gallery-comment-page-failure", page != nil {
                throw URLError(.cannotParseResponse)
            }
            if stage == "gallery-comment-page-failure" {
                return .init(
                    items: [comment(object: objectID)], nextSourcePage: 3, canLoadMore: true)
            }
            return .init(
                items: orderedComments(objectID, order: order, page: page ?? 0),
                nextSourcePage: (page ?? 0) + 1, canLoadMore: false)
        }
        private func orderedComments(_ object: String, order: CommunityCommentOrder, page: Int)
            -> [CommunityComment]
        {
            guard page == 0 else { return [] }
            let values = [
                comment(object: object, likes: 2, date: "2026-01-02T00:00:00Z"),
                comment(object: object, id: 2, likes: 1),
            ]
            return order == .oldest ? Array(values.reversed()) : values
        }
        func fetchClaims() async throws -> [CommunityClaim] { [poster.claim] }
        func fetchSubscriptions(page: Int) async throws -> [GallerySubscription] { [] }
        func fetchReportTypes() async throws -> [GalleryReportType] {
            let data =
                stage == "report-types-empty-gap"
                ? "[]"
                : stage == "report-types-duplicate-failure"
                    ? #"[{"id":1,"text":"first"},{"id":1,"text":"second"}]"#
                    : stage == "report-types-text-failure"
                        ? #"[{"id":1,"text":"  "}]"# : #"[{"id":1,"text":"fixture"}]"#
            return try JSONDecoder().decode([GalleryReportType].self, from: Data(data.utf8))
        }
        func fetchCourses(search: String, page: Int) async throws -> [CourseSummary] {
            if search == NetworkSmokePaging.excludedSearchText
                && stage != "course-search-ignored-failure"
            {
                return []
            }
            if !search.isEmpty { observed.insert("course-search-\(search)-\(page)") }
            if stage == "empty-list-failure" { return [] }
            guard
                page == 0 || stage == "repeated-page-failure"
                    || !search.isEmpty && stage == "course-search-later-success" && page <= 2
            else { return [] }
            let id =
                search.isEmpty || stage == "course-search-target-failure"
                ? 1 : stage == "course-search-later-success" && page < 2 ? page + 1 : 43
            return [
                CourseSummary(
                    detail: CourseDetail(
                        id: id, name: "fixture", number: "COURSE", credit: 1, likeNum: 0,
                        commentNum: 0, rate: 0, teachersName: "", teachersNumber: "",
                        like: false))
            ]
        }
        func fetchCourse(id: Int) async throws -> CourseDetail {
            observed.insert("course-detail")
            observed.insert("fixture-course-\(id)")
            if stage == "maintained-fixtures-success", id == 1 {
                throw URLError(.resourceUnavailable)
            }
            if stage == "community-failure" { throw URLError(.timedOut) }
            return CourseDetail(
                id: stage == "entity-identity-failure" ? id + 1 : id, name: "fixture",
                number: "COURSE", credit: 1, likeNum: 0, commentNum: 0, rate: 0,
                teachersName: "", teachersNumber: "", like: false)
        }
        func fetchCourseHistories(number: String) async throws -> [CourseHistoryGrade] {
            [
                .init(
                    term: "2026-2027-1",
                    avgScore: stage == "course-history-statistics-failure" ? 101 : 85,
                    maxScore: 100, studentNum: 30)
            ]
        }
        func fetchComments(courseID: Int, page: Int?) async throws -> [CommunityComment] {
            observed.insert("course-comments-\(page ?? 0)")
            if stage == "course-comment-ranking-failure" {
                return [
                    comment(object: "course\(courseID)"),
                    comment(object: "course\(courseID)", id: 2, date: "2026-01-02T00:00:00Z"),
                ]
            }
            if stage == "course-comment-page-failure" {
                return [comment(object: "course\(courseID)")]
            }
            return orderedComments("course\(courseID)", order: .newest, page: page ?? 0)
        }
        func fetchPapers(search: String?, order: PaperSortOrder, page: Int) async throws
            -> [PaperSummary]
        {
            if search == NetworkSmokePaging.excludedSearchText
                && stage != "paper-search-ignored-failure"
            {
                return []
            }
            observed.insert("paper-list")
            if let search { observed.insert("paper-search-\(search)-\(page)") }
            if stage == "paper-default-date-failure", search != nil { return [] }
            if stage == "empty-list-failure" { return [] }
            if stage == "paper-\(order.requestValue ?? "newest")-order-failure"
                || stage == "paper-newest-date-failure" && order == .newest
                || stage == "paper-default-date-failure"
            {
                return page == 0
                    ? (0..<2).map { index in
                        PaperSummary(
                            id: index + 1, title: "fixture", intro: "", likeNum: index,
                            commentNum: index,
                            updateTime: stage.contains("-date-")
                                ? "invalid"
                                : index == 0 ? "2026-01-01T00:00:00Z" : "2026-01-02T00:00:00Z")
                    } : []
            }
            guard page == 0 else { return [] }
            return [
                PaperSummary(
                    id: search == nil || stage == "paper-search-target-failure" ? 1 : 45,
                    title: "fixture", intro: "", likeNum: 2, commentNum: 2,
                    updateTime: "2026-01-02T00:00:00Z"),
                PaperSummary(
                    id: 2, title: "fixture", intro: "", likeNum: 1, commentNum: 1,
                    updateTime: "2026-01-01T00:00:00Z"),
            ]
        }
        func fetchPaper(id: Int) async throws -> PaperDetail {
            observed.insert("fixture-paper-\(id)")
            if stage == "maintained-fixtures-success", id == 1 {
                throw URLError(.resourceUnavailable)
            }
            let content =
                stage.contains("paper-media-")
                ? smokePaperContent.replacingOccurrences(
                    of: "\"url\":\"https://image.invalid/paper.png\"",
                    with:
                        """
                        \"url\":\"https://image.invalid/paper.png\",\"low_url\":\"https://i\
                        mage.invalid/paper-low.png\"
                        """
                ) : smokePaperContent
            return PaperDetail(
                id: stage == "entity-identity-failure" ? id + 1 : id, title: "fixture",
                intro: "", content: stage == "paper-content-failure" ? "" : content,
                createTime: "", updateTime: "", updateUser: user,
                anonymous: false, likeNum: 0, commentNum: 0, publicEdit: false, like: false,
                own: false)
        }
        func fetchPreviewMetadata(id: Int) async throws -> PaperPreviewMetadata {
            try await fetchPaper(id: id).previewMetadata
        }
        func fetchComments(paperID: Int, order: CommunityCommentOrder, page: Int?) async throws
            -> [CommunityComment]
        {
            observed.insert("paper-comments-\(page ?? 0)")
            observed.insert("paper-order-\(order.rawValue)")
            if stage == "paper-comment-ranking-failure", order == .oldest {
                return [
                    comment(object: "paper\(paperID)", date: "2026-01-02T00:00:00Z"),
                    comment(object: "paper\(paperID)", id: 2),
                ]
            }
            if stage == "paper-comment-page-failure", page != nil {
                throw URLError(.cannotParseResponse)
            }
            return stage == "paper-comment-page-failure"
                ? [comment(object: "paper\(paperID)")]
                : orderedComments("paper\(paperID)", order: order, page: page ?? 0)
        }
        func fetchMyInfo() async throws -> MineUserInfo {
            observed.insert("mine")
            return try await fetchUserInfo(id: 1)
        }
        func fetchUserInfo(id: Int) async throws -> MineUserInfo {
            MineUserInfo(
                user: user, followingNum: 0, followerNum: 0, following: false, follower: false,
                own: true)
        }
        func fetchUserPosters(userID: Int, page: Int) async throws -> [CommunityPoster] {
            page == 0 ? [poster] : []
        }
        func fetchMyPosters(page: Int) async throws -> [CommunityPoster] {
            page == 0 ? [poster] : []
        }
        func fetchFollowers(page: Int) async throws -> [CommunityUser] { [] }
        func fetchFollowings(page: Int) async throws -> [CommunityUser] { [] }
        func fetchCurrentTermOnly() async throws -> String {
            if stage.hasPrefix("all-sms-") && stage != "all-sms-not-required" && !webvpnVerified {
                throw ScheduleServiceError.secondFactorRequired(verificationChallenge)
            }
            return "fixture-1"
        }
        func fetchAvailableTerms() async throws -> [String] { ["fixture-1"] }
        func syncCourses(term: String?) async throws -> CourseSyncPayload {
            observed.insert("schedule")
            rawResponse?(Data("course-response".utf8))
            let exams: [ExamRecord] =
                stage == "invalid-exam-failure" || stage == "pending-exam-success"
                ? [
                    .init(
                        id: "exam", term: "fixture-1",
                        name: stage == "invalid-exam-failure" ? "" : "待排课程", courseID: "",
                        teacher: "", classroom: "", dateString: "", beginTime: "", endTime: "",
                        examMode: "", seatID: "")
                ] : []
            let pending = stage == "pending-course-gap"
            let courses: [CourseRecord] =
                stage == "empty-course-gap"
                ? []
                : [
                    .init(
                        id: "course", term: term ?? "fixture-1", name: "课程", teacher: "",
                        classroom: "",
                        description: "", weeks: pending ? [] : [1, 3, 5],
                        weekday: pending ? 0 : 1, startSection: pending ? 0 : 1,
                        endSection: pending ? 0 : 2,
                        campus: "", number: "CS101", credit: 1, hour: 1, type: "", category: "",
                        department: "")
                ]
            return CourseSyncPayload(
                term: stage == "schedule-term-failure" ? "other-term" : term ?? "fixture-1",
                firstDayString: "2026-03-02", sourceFirstDayString: "2026-03-02",
                normalizationOffset: 0, rawWeeksByCourse: courses.map(\.weeks),
                sourceDisplayWeeksByCourse: courses.map { _ in nil }, courses: courses,
                exams: exams)
        }
        func submitTeachingCode(_ code: String, for challenge: BITLoginAuthenticationChallenge)
            async throws
        { webvpnVerified = true }
        func prepareTeachingAccess() async throws {}
        func fetchCampuses() async throws -> [CampusRecord] {
            [CampusRecord(id: "campus", name: "fixture", code: "campus")]
        }
        func fetchBuildings(campusCode: String?) async throws -> [BuildingRecord] {
            [
                BuildingRecord(
                    id: "building", name: "fixture", buildingCode: "building",
                    campusName: "fixture",
                    campusCode: stage == "campus-selection-failure" ? "other" : "campus")
            ]
        }
        var classroomDate: Date?
        func fetchClassrooms(buildingID: String, term: String, date: Date) async throws
            -> [ClassroomRecord]
        {
            classroomDate = date
            if stage == "empty-classroom-gap" { return [] }
            return [
                ClassroomRecord(
                    id: "room", name: "fixture",
                    busyTimeCodes: stage == "invalid-classroom-failure" ? [0] : [])
            ]
        }
        func prefetchClassrooms(buildingID: String, term: String, date: Date) async throws
            -> [ClassroomRecord]?
        { try await fetchClassrooms(buildingID: buildingID, term: term, date: date) }
        func fetchEclassDDLEvents(schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws
            -> EclassDDLResult
        {
            if stage.hasPrefix("all-sms-") && stage != "all-sms-not-required" && !ssoVerified {
                let handler = try #require(schoolSMSCodeHandler)
                _ = try await handler(
                    .init(maskedPhone: "***", purpose: "school_sso_second_factor"))
                ssoVerified = true
            }
            return try await probeEclassEvents()
        }
        func probeEclassEvents() async throws -> EclassDDLResult {
            observed.insert("eclass")
            return EclassDDLResult(
                events: [], courseCount: 1, activityCount: 0, activityTypes: [:],
                homeworkWithoutDeadlineCount: 0)
        }
        func refreshLexueCalendarURL(schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws
            -> String
        { try await probeLexueCalendarURL() }
        func probeLexueCalendarURL() async throws -> String {
            "https://lexue.bit.edu.cn/fixture.ics"
        }
        func syncDDLEventsForPreflight(existingEvents: [DDLEventRecord], storedURL: String)
            async throws -> DDLSyncPayload
        {
            observed.insert("lexue")
            if stage == "ddl-failure" { throw URLError(.timedOut) }
            if stage == "ddl-invalid-calendar-failure" {
                throw ScheduleServiceError.invalidCalendarData
            }
            return DDLSyncPayload(url: storedURL, events: [])
        }
        func startScoreChallenge() async throws -> BITLoginAuthenticationChallenge {
            if stage.hasPrefix("all-sms-") && stage != "all-sms-not-required" {
                throw ScoreServiceError.secondFactorRequired(verificationChallenge)
            }
            return BITLoginAuthenticationChallenge(
                challengeID: "fixture", accessToken: "fixture", status: "authenticated",
                maskedPhone: nil, expiresIn: 60)
        }
        func fetchScores(
            detail: Bool, authenticatedBy challenge: BITLoginAuthenticationChallenge
        ) async throws -> [ScoreRow] {
            return [
                ScoreRow(
                    index: 0, headers: ["序号", "课程编号", "课程名称", "成绩", "开课学期", "学分"],
                    values: [
                        "1", "CS101", "课程",
                        stage == "all-score-mismatch-failure" && detail ? "80" : "90", "2025",
                        "2",
                    ])
            ]
        }
        func submitScoreCode(_ code: String, for challenge: BITLoginAuthenticationChallenge)
            async throws -> BITLoginAuthenticationChallenge
        {
            .init(
                challengeID: "fixture", accessToken: "fixture", status: "authenticated",
                maskedPhone: nil, expiresIn: 60)
        }
        func fetchTrustedPages(onPage: TrustedTranscriptPageDelivery?) async throws
            -> TrustedTranscriptPages
        {
            if stage.hasPrefix("all-sms-") && stage != "all-sms-not-required" {
                throw ScoreServiceError.secondFactorRequired(verificationChallenge)
            }
            return .init([image])
        }
        func submitTranscriptCode(
            _ code: String, for challenge: BITLoginAuthenticationChallenge
        ) async throws -> BITLoginAuthenticationChallenge { return challenge }
        func fetchTrustedPages(
            authenticatedBy challenge: BITLoginAuthenticationChallenge,
            onPage: TrustedTranscriptPageDelivery?
        ) async throws -> TrustedTranscriptPages { .init([image]) }
    }
    final class External: HTTPTransport {
        let image: Data
        let redirectHost: String?
        let aasaStage: String
        var requests: [URLRequest] = []
        var imageBudgets: [Int?] = []
        init(image: Data, redirectHost: String? = nil, aasaStage: String = "") {
            self.image = image
            self.redirectHost = redirectHost
            self.aasaStage = aasaStage
        }
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (
            Data, URLResponse
        ) {
            if let path = request.url?.path, path.hasSuffix(".jpg") || path.hasSuffix(".png") {
                imageBudgets.append(maximumBytes)
                if aasaStage == "image-budget-failure", maximumBytes != nil {
                    throw HTTPClientError.responseTooLarge
                }
            }
            let result = try await data(for: request)
            if let maximumBytes, result.0.count > maximumBytes {
                throw HTTPClientError.responseTooLarge
            }
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
                #expect(
                    request.value(forHTTPHeaderField: "Access-Control-Request-Method") == "POST"
                )
                #expect(
                    request.value(forHTTPHeaderField: "Access-Control-Request-Headers")
                        == "content-type")
                data = Data()
                status = 204
                headers["Access-Control-Allow-Origin"] = "*"
                headers["Access-Control-Allow-Methods"] =
                    aasaStage == "cors-method-failure" ? "OPTIONS" : "post, OPTIONS"
                headers["Access-Control-Allow-Headers"] =
                    aasaStage == "cors-header-failure" ? "x-custom" : "Content-Type"
            } else if url.path.hasSuffix("apple-app-site-association") {
                let json =
                    #"""
                    {"applinks":{"details":[{"appID":"Y2T72736G3.BIT101-dev.BIT101-iOS","p\#
                    aths":["/gallery/*","/course/*","/paper/*"]}]}}
                    """#
                data = Data(
                    (aasaStage == "aasa-exclusion-failure"
                        ? json.replacingOccurrences(
                            of: "\"/gallery/*\"", with: "\"NOT /gallery/*\",\"/gallery/*\"")
                        : json).utf8)
                headers["Content-Type"] =
                    aasaStage == "aasa-mime-failure" ? "text/plain" : "application/json"
                if aasaStage == "aasa-redirect-failure" {
                    status = 302
                    headers["Location"] = "/association"
                }
                if aasaStage == "aasa-followed-redirect-failure" {
                    finalURL = AppURL.required("https://open.aihelpme.dev/association")
                }
            } else if url.host == "itunes.apple.com" {
                #expect(
                    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                        .contains { $0.name == "requestTime" } == true)
                #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
                #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
                data = Data(
                    #"""
                    {"resultCount":1,"results":[{"version":"1.0","bundleId":"BIT101-dev.BI\#
                    T101-iOS","currentVersionReleaseDate":"2026-01-01T00:00:00Z","trackVie\#
                    wUrl":"https://apps.apple.com/app/id6761147125"}]}
                    """#
                    .utf8)
            } else if url.host == "update.aihelpme.dev" {
                data = Data(#"{"schema_version":1,"enabled":false}"#.utf8)
            } else if url.path.hasSuffix(".jpg") || url.path.hasSuffix(".png") {
                if aasaStage == "paper-image-failure", url.path == "/paper.png" {
                    throw URLError(.resourceUnavailable)
                }
                if aasaStage == "paper-media-original-failure", url.path == "/paper.png" {
                    throw URLError(.resourceUnavailable)
                }
                if aasaStage == "paper-media-thumbnail-failure", url.path == "/paper-low.png" {
                    throw URLError(.resourceUnavailable)
                }
                data = image
            } else {
                if url.path.isEmpty || url.path == "/" {
                    finalURL = try #require(URL(string: "https://bit101.cn/gallery/"))
                }
                data = Data(
                    """
                    <html><title>BIT101</title><body><a href=\"bit101:/\(url.path)\">fixtur\
                    e</a></body></html>
                    """
                    .utf8)
            }
            if url.host == redirectHost { status = 302 }
            return (
                data,
                try #require(
                    HTTPURLResponse(
                        url: finalURL, statusCode: status, httpVersion: nil,
                        headerFields: headers))
            )
        }
    }
}
#endif
