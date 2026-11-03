import BIT101TestSupport
import CommunityCore
import CommunityTransport
import CourseFeature
import Foundation
import MineFeature
import PaperFeature
import Testing
import TransportCore

@testable import GalleryFeature

extension ServiceContractTests {
    @Test(.timeLimit(.minutes(1))) func authedPaperReadRestoresOnContentRequest() async throws {
        let transport = Transport([
            (401, ""), (200, "[" + paper + "]"), (200, paperDetailBody(own: true)), (200, "[]"),
        ])
        var credentials = CommunityCredentials(
            identity: .init(accountIdentifier: "contracts"), cookie: "expired")
        var restores = 0
        let session = CommunitySession(
            httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"), credentials: { credentials },
            refresh: { observed in
                #expect(observed.cookie == "expired")
                restores += 1
                credentials = .init(identity: observed.identity, cookie: "fresh")
            })
        let service = PaperService(session: session)
        #expect(
            try await service.fetchPapers(search: "文章", order: .newest, page: 0).first?.id == 17)
        let detail = try await service.fetchPaper(id: 17)
        _ = try await service.fetchComments(paperID: 17, order: .oldest, page: nil)
        #expect(detail.own && detail.like && detail.isViewerAuthenticated && restores == 1)
        #expect(transport.authenticationRequests.isEmpty)
        #expect(
            transport.requests.map { $0.value(forHTTPHeaderField: "fake-cookie") } == [
                "expired", "fresh", "fresh", "fresh",
            ])
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: [
            "poster0", "poster-1", "posterXYZ", "poster999999999999999999999", "paper1", "course1",
            "comment1", "poster17", "poster01",
        ])
    func messageLinksRequireIdentity(link: String) throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        func message(object: String) throws -> GalleryMessage {
            try decoder.decode(
                GalleryMessage.self,
                from: Data(
                    """
                    {\"from_user\":{},\"id\":9,\"link_obj\":\"\(link)\",\"obj\":\"\(object)\",\
                    \"text\":\"\",\"update_time\":\"\"}
                    """
                    .utf8))
        }
        let targets: [String: (CommunityResourceReference.Kind, Int)] = [
            "poster17": (.poster, 17), "poster01": (.poster, 1), "paper1": (.paper, 1),
            "course1": (.course, 1),
        ]
        let expected = targets[link]
        let direct = try message(object: "").linkedResource
        #expect(direct?.kind == expected?.0 && direct?.id == expected?.1)
        let fallback = try message(object: "poster17").linkedResource
        #expect(fallback?.kind == (expected?.0 ?? .poster) && fallback?.id == (expected?.1 ?? 17))
    }

    @Test(.timeLimit(.minutes(1))) func anonymousPaperReadKeepsItsPublicContract() async throws {
        let transport = Transport([(200, paperDetailBody(own: false))])
        let detail = try await PaperService(session: session(transport, cookie: "")).fetchPaper(
            id: 17)
        #expect(
            !detail.own && !detail.like && !detail.isViewerAuthenticated
                && transport.authenticationRequests.isEmpty)
        #expect(transport.requests.first?.value(forHTTPHeaderField: "fake-cookie") == nil)
    }

    @Test(.timeLimit(.minutes(1))) func paperPreviewReusesInvalidatesItIt() async throws {
        let transport = Transport([
            (200, paperDetailBody(own: true)), (200, paperDetailBody(own: true, title: "刷新")),
            (200, paperDetailBody(own: true)), (200, #"{"like":true,"like_num":4}"#),
            (200, paperDetailBody(own: true, title: "修改后")),
        ])
        let service = PaperService(session: session(transport))
        _ = try await service.fetchPreviewMetadata(id: 17)
        #expect(await service.cachedPaper(id: 17)?.title == "文章")
        #expect(transport.requests.count == 1)
        #expect(try await service.fetchPaper(id: 17).title == "刷新")
        _ = try await service.fetchPreviewMetadata(id: 17)
        _ = try await service.likePaper(id: 17)
        #expect(try await service.fetchPaper(id: 17).title == "修改后")
        #expect(transport.requests.count == 5)
    }

    @Test(.timeLimit(.minutes(1))) func paperPreviewKeepsBody() async throws {
        let transport = Transport([(401, ""), (200, paperDetailBody(own: true))])
        var credentials = CommunityCredentials(
            identity: .init(accountIdentifier: "contracts"), cookie: "expired")
        let session = CommunitySession(
            httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"), credentials: { credentials },
            refresh: { observed in
                credentials = .init(identity: observed.identity, cookie: "fresh")
            })
        let service = PaperService(session: session)
        _ = try await service.fetchPreviewMetadata(id: 17)
        #expect(await service.cachedPaper(id: 17)?.own == true)
        #expect(transport.requests.count == 2 && transport.authenticationRequests.isEmpty)
        #expect(
            transport.requests.map { $0.value(forHTTPHeaderField: "fake-cookie") } == [
                "expired", "fresh",
            ])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func prefetchedPaperBodyRefresh(failedListRefresh: Bool) async throws {
        let transport = Transport(
            [(200, paperDetailBody(own: true))], authenticationStatuses: [503])
        let service = PaperService(session: session(transport))
        _ = try await service.fetchPreviewMetadata(id: 17)
        transport.failure = URLError(.notConnectedToInternet)
        if failedListRefresh {
            await #expect(throws: URLError.self) {
                _ = try await service.fetchPapers(search: nil, order: .newest, page: 0)
            }
        }
        #expect(await service.cachedPaper(id: 17)?.own == true)
        #expect(
            transport.requests.count == (failedListRefresh ? 2 : 1)
                && transport.authenticationRequests.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func concurrentPaperPreviewsDirectly() async throws {
        let transport = Transport([])
        transport.responseForRequest = { request in
            let id = try #require(request.url?.lastPathComponent)
            return (
                200,
                self.paperDetailBody(own: true).replacingOccurrences(
                    of: "\"id\":17", with: "\"id\":\(id)")
            )
        }
        let service = PaperService(session: session(transport))
        let (starts, started) = AsyncStream<Void>.makeStream()
        let tasks = (17..<25).map { id in
            Task {
                started.yield(())
                return try await service.fetchPreviewMetadata(id: id)
            }
        }
        defer {
            tasks.forEach { $0.cancel() }
            started.finish()
        }
        var iterator = starts.makeAsyncIterator()
        for _ in tasks { _ = await iterator.next() }
        for task in tasks { _ = try await task.value }
        #expect(transport.authenticationRequests.isEmpty && transport.requests.count == 8)
        #expect(
            Set(transport.requests.compactMap { $0.url?.path })
                == Set((17..<25).map { "/papers/\($0)" }))
    }

    @Test(.timeLimit(.minutes(1))) func coursePaging() async throws {
        let detail = String(course.dropLast()) + #", "like":true}"#
        let transport = Transport([(200, "[" + course + "]"), (200, "[]"), (200, detail)])
        let service = CourseService(session: session(transport))
        let first = try await service.fetchCourses(search: "  操作系统 & A+B  ", page: 0)
        #expect(first.first?.credit == 3.5)
        #expect(first.first?.teachersName == "教师")
        #expect(first.first?.likeNum == 7)
        #expect(
            try query(transport.requests[0]) == [
                "search": "操作系统 & A+B", "order": "new", "page": "0",
            ])
        #expect(transport.requests[0].value(forHTTPHeaderField: "fake-cookie") == "fixture-cookie")
        #expect(try await service.fetchCourses(search: "", page: 1).isEmpty)
        #expect(try query(transport.requests[1]) == ["order": "new", "page": "1"])
        let value = try await service.fetchCourse(id: 42)
        #expect(value.like && value.id == 42)
        #expect(value.credit == 3.5)
        #expect(transport.requests[2].url?.path == "/courses/42")
    }

    @Test(.timeLimit(.minutes(1))) func courseHistoryEscapesDecodesStatistics() async throws {
        let transport = Transport([
            (
                200,
                #"[{"term":"2026-2027-1","avg_score":"85.5","max_score":100,"student_num":"37"}]"#
            )
        ])
        let values = try await CourseService(session: session(transport)).fetchCourseHistories(
            number: "MATH/1+中文%20")
        #expect(values.first?.avgScore == 85.5)
        #expect(values.first?.studentNum == 37)
        #expect(transport.requests.first?.url?.path == "/courses/histories/MATH/1+中文%20")
        #expect(transport.requests.first?.url?.absoluteString.contains("MATH%2F1%2B") == true)
        #expect(transport.requests.first?.url?.absoluteString.hasSuffix("%2520") == true)
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: [
            "1e300", #""1e300""#, #""NaN""#, #""Infinity""#, #""-Infinity""#, "37.9", #""37.9""#,
        ])
    func courseHistoryTreatsOutRangeCountsAsMissing(raw: String) async throws {
        let transport = Transport([(200, "[{\"term\":\"2026-2027-1\",\"student_num\":\(raw)}]")])
        let values = try await CourseService(session: session(transport)).fetchCourseHistories(
            number: "MATH")
        #expect(values.count == 1 && values[0].studentNum == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["NaN", "Infinity", "-Infinity"])
    func courseHistoryTreatsMissing(raw: String) async throws {
        let transport = Transport([
            (200, "[{\"term\":\"2026-2027-1\",\"avg_score\":\"\(raw)\",\"max_score\":\"\(raw)\"}]")
        ])
        let values = try await CourseService(session: session(transport)).fetchCourseHistories(
            number: "MATH")
        #expect(values.count == 1 && values[0].avgScore == nil && values[0].maxScore == nil)
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: [
            #"[{"term":"same"},{"term":"same"}]"#, #"[{"term":" "}]"#,
            #"[{"term":"term","student_num":-1}]"#, #"[{"term":"term","avg_score":-1}]"#,
            #"[{"term":"term","max_score":101}]"#, #"[{"term":"term","avg_score":1e300}]"#,
        ])
    func courseHistoryRejectsDuplicateTerms(body: String) async throws {
        let transport = Transport([(200, body)])
        let observer = ResponseObserver()
        await #expect(throws: CourseServiceError.self) {
            try await CourseService(session: session(transport, observer: observer))
                .fetchCourseHistories(number: "MATH")
        }
        #expect(observer.failures == 1)
    }

    @Test(.timeLimit(.minutes(1))) func expiredCourseCredentialsRestoreOnce() async throws {
        let transport = Transport([(401, #"{"message":"expired"}"#), (200, "[" + course + "]")])
        var cookie = "old-cookie"
        var restores = 0
        let session = CommunitySession(
            httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: {
                .init(
                    identity: .init(accountIdentifier: "contracts", generation: 2), cookie: cookie)
            },
            refresh: { observed in
                #expect(observed.cookie == "old-cookie")
                restores += 1
                cookie = "new-cookie"
            })
        let values = try await CourseService(session: session).fetchCourses(
            search: "CS101", page: 3)
        #expect(values.map(\.id) == [42])
        #expect(restores == 1 && transport.requests.count == 2)
        #expect(transport.requests[1].value(forHTTPHeaderField: "fake-cookie") == "new-cookie")
        #expect(try query(transport.requests[0]) == query(transport.requests[1]))
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: ["{}", "null", "<html>gateway</html>", #"[{"id":"invalid"}]"#])
    func malformedCourse(_ response: String) async {
        for course in [true, false] {
            do {
                let selected = session(
                    Transport([(200, response)]), cookie: course ? "fixture-cookie" : "")
                if course {
                    _ = try await CourseService(session: selected).fetchCourses(search: "", page: 0)
                } else {
                    _ = try await PaperService(session: selected).fetchPapers(
                        search: nil, order: .newest, page: 0)
                }
                Issue.record("损坏列表需要保留业务错误和解码原因。")
            } catch {
                let actual = error as NSError
                let expected =
                    course
                    ? CourseServiceError.invalidResponse as NSError
                    : PaperServiceError.invalidResponse as NSError
                #expect(actual.domain == expected.domain && actual.code == expected.code)
                #expect(actual.userInfo[NSUnderlyingErrorKey] != nil)
            }
        }
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: [(false, false), (false, true), (true, false), (true, true)], [400, 404, 500])
    func resourceAbsenceHasServiceTypeRecovery(fixture: (Bool, Bool), status: Int) async throws {
        let (paper, refresh) = fixture
        let response = paper ? #"{"message":"文章不存在Orz"}"# : #"{"message":"帖子不存在Orz"}"#
        let transport = Transport(
            (refresh ? [(401, #"{"message":"expired"}"#)] : []) + [(status, response)])
        do {
            if paper {
                _ = try await PaperService(session: session(transport)).fetchPaper(id: 17)
            } else {
                _ = try await GalleryService(
                    session: session(transport),
                    preferences: {
                        .init(
                            hideBots: false, hiddenUserIDs: [], hideAnonymous: false,
                            useWebView: false, hideMakeupOutliers: false)
                    }
                ).fetchPoster(id: 17)
            }
            Issue.record("已知缺失响应需要沿服务错误传播")
        } catch {
            if paper {
                guard case PaperServiceError.missingPaper = error else { throw error }
                #expect(error.localizedDescription == "文章已删除或暂时无法访问。")
            } else {
                guard case GalleryServiceError.missingPoster = error else { throw error }
                #expect(error.localizedDescription == "帖子已删除或暂时无法访问。")
            }
        }
        #expect(transport.requests.count == (refresh ? 2 : 1))
        #expect(transport.authenticationRequests.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
    func resourceClassificationKeepsUnknownRoutes(paper: Bool, list: Bool) async throws {
        let response =
            list
            ? (paper ? #"{"message":"文章不存在Orz"}"# : #"{"message":"帖子不存在Orz"}"#)
            : #"{"message":"Not Found"}"#
        let transport = Transport([(404, response)])
        do {
            if paper {
                let service = PaperService(session: session(transport))
                if list {
                    _ = try await service.fetchPapers(search: nil, order: .newest, page: 0)
                } else {
                    _ = try await service.fetchPaper(id: 17)
                }
            } else {
                let service = GalleryService(
                    session: session(transport),
                    preferences: {
                        .init(
                            hideBots: false, hiddenUserIDs: [], hideAnonymous: false,
                            useWebView: false, hideMakeupOutliers: false)
                    })
                if list {
                    _ = try await service.fetchFeed(kind: .newest, page: 0)
                } else {
                    _ = try await service.fetchPoster(id: 17)
                }
            }
            Issue.record("服务失败需要保留原请求状态")
        } catch {
            let failure = error as NSError
            #expect(
                failure.code == 404 && failure.domain == (paper ? "BIT101.Paper" : "BIT101.Gallery")
            )
        }
    }

    @Test(.timeLimit(.minutes(1))) func publicPaperPagesKeepAnonymousAccess() async throws {
        let detail =
            #"""
            {"id":17,"title":"文章","intro":"摘要","content":"正文","create_time":"","update_time":"\#
            ","update_user":\#(user),"anonymous":false,"like_num":3,"comment_num":4,"public_ed\#
            it":true,"like":false,"own":true}
            """#
        let transport = Transport([
            (200, "[" + paper + "]"), (200, "[]"), (200, detail), (200, "[]"),
        ])
        let service = PaperService(session: session(transport, cookie: ""))
        #expect(
            try await service.fetchPapers(search: "主题 & A+B", order: .comment, page: 2).first?
                .commentNum == 4)
        #expect(
            try query(transport.requests[0]) == [
                "search": "主题 & A+B", "order": "comment", "page": "2",
            ])
        #expect(transport.requests[0].value(forHTTPHeaderField: "fake-cookie") == nil)
        #expect(try await service.fetchPapers(search: nil, order: .newest, page: 3).isEmpty)
        #expect(try query(transport.requests[1]) == ["page": "3"])
        let value = try await service.fetchPaper(id: 17)
        #expect(value.updateUser.nickname == "作者" && value.publicEdit && value.own)
        #expect(value.content == "正文")
        #expect(try await service.fetchComments(paperID: 17, order: .oldest, page: 2).isEmpty)
        #expect(
            try query(transport.requests[3]) == ["obj": "paper17", "order": "old", "page": "2"])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [0, -1])
    func contentCreationRejectsInvalidIdentifiers(id: Int) async throws {
        let transport = Transport(Array(repeating: (200, "{\"id\":\(id)}"), count: 2))
        let shared = session(transport)
        let gallery = GalleryService(
            session: shared,
            preferences: {
                .init(
                    hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false,
                    hideMakeupOutliers: false)
            })
        await #expect(throws: CommunityCreateOutcomeUnknown.self) {
            try await gallery.createPoster(
                title: "标题", text: "正文", imageMids: [], anonymous: false,
                tags: [], claimID: 0, isPublic: true)
        }
        await #expect(throws: CommunityCreateOutcomeUnknown.self) {
            try await PaperService(session: shared).createPaper(
                title: "标题", intro: "摘要", content: "正文", anonymous: false)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [0, -1])
    func commentCreationKeepsInvalidIdsBoundary(id: Int) async throws {
        let comment =
            #"""
            {"id":\#(id),"obj":"poster1","images":[],"user":\#(user),"anonymous":false,"create\#
            _time":"","update_time":"","like":false,"like_num":0,"comment_num":0,"own":true,"r\#
            ate":0,"reply_user":\#(user),"reply_obj":"","text":"评论","sub":[]}
            """#
        let transport = Transport(Array(repeating: (200, comment), count: 3))
        let shared = session(transport)
        let gallery = GalleryService(
            session: shared,
            preferences: {
                .init(
                    hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false,
                    hideMakeupOutliers: false)
            })
        await #expect(throws: CommunityCreateOutcomeUnknown.self) {
            try await gallery.createComment(objectID: "poster1", text: "评论")
        }
        await #expect(throws: CommunityCreateOutcomeUnknown.self) {
            try await PaperService(session: shared).createComment(objectID: "paper1", text: "评论")
        }
        await #expect(throws: CommunityCreateOutcomeUnknown.self) {
            try await CourseService(session: shared).createComment(objectID: "course1", text: "评论")
        }
        #expect(transport.requests.count == 3)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["", "   ", "fixture-image"])
    func imageUploadRequiresAResourceIdentifier(mid: String) async throws {
        let response =
            """
            {\"mid\":\"\(mid)\",\"url\":\"https://example.invalid/image.jpg\",\"low_url\":\"htt\
            ps://example.invalid/small.jpg\"}
            """
        let transport = Transport([(200, response)])
        let observer = ResponseObserver()
        let gallery = GalleryService(
            session: session(transport, observer: observer),
            preferences: {
                .init(
                    hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false,
                    hideMakeupOutliers: false)
            })
        if mid == "fixture-image" {
            #expect(try await gallery.uploadImage(data: Data([1, 2, 3])).mid == mid)
        } else {
            await #expect(throws: GalleryServiceError.self) {
                try await gallery.uploadImage(data: Data([1, 2, 3]))
            }
        }
        #expect(observer.failures == (mid == "fixture-image" ? 0 : 1))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [0, -1, 18])
    func detailReadsRejectDifferentObjects(returnedID: Int) async throws {
        let paper = paperDetailBody(own: true).replacingOccurrences(
            of: "\"id\":17", with: "\"id\":\(returnedID)")
        let course =
            String(
                course.replacingOccurrences(of: "\"id\":42", with: "\"id\":\(returnedID)")
                    .dropLast()) + #", "like":false}"#
        let poster =
            String(poster(id: returnedID).dropLast())
            + #", "like":false, "own":true, "plugins":"[]"}"#
        let transport = Transport([(200, poster), (200, paper), (200, paper), (200, course)])
        let observer = ResponseObserver()
        let shared = session(transport, observer: observer)
        let gallery = GalleryService(
            session: shared,
            preferences: {
                .init(
                    hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false,
                    hideMakeupOutliers: false)
            })
        let invalid = GalleryServiceError.invalidResponse as NSError
        do {
            _ = try await gallery.fetchPoster(id: 17)
            Issue.record("详情需要拒绝其他资源编号。")
        } catch {
            let observed = error as NSError
            #expect(observed.domain == invalid.domain && observed.code == invalid.code)
        }
        let service = PaperService(session: shared)
        await #expect(throws: PaperServiceError.self) { try await service.fetchPaper(id: 17) }
        await #expect(throws: PaperServiceError.self) {
            try await service.fetchPreviewMetadata(id: 17)
        }
        await #expect(throws: CourseServiceError.self) {
            try await CourseService(session: shared).fetchCourse(id: 42)
        }
        #expect(transport.requests.count == 4)
        #expect(observer.failures == 4)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [0, -1, 18, 17], [false, true])
    func publicProfileResponseMatchesRequestedUser(returnedID: Int, authenticated: Bool)
        async throws
    {
        let returnedUser = user.replacingOccurrences(of: "\"id\":1", with: "\"id\":\(returnedID)")
        let profile =
            #"""
            {"user":\#(returnedUser),"followingNum":2,"followerNum":3,"following":false,"follo\#
            wer":false,"own":false}
            """#
        let transport = Transport([(200, profile)])
        let observer = ResponseObserver()
        let service = MineService(
            session: session(
                transport, cookie: authenticated ? "fixture-cookie" : "", observer: observer),
            preferences: {
                .init(
                    hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false,
                    hideMakeupOutliers: false)
            })
        if returnedID == 17 {
            let info = try await service.fetchUserInfo(id: 17)
            #expect(info.user.id == 17 && info.isViewerAuthenticated == authenticated)
        } else {
            await #expect(throws: MineServiceError.self) { try await service.fetchUserInfo(id: 17) }
        }
        #expect(transport.requests.map { $0.url?.path } == ["/user/info/17"])
        #expect(observer.failures == (returnedID == 17 ? 0 : 1))
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: ["valid", "object", "zero", "nested-zero", "duplicate", "nested-duplicate"])
    func commentServicesValidateObjects(damage: String) async throws {
        let comment =
            #"""
            {"id":5,"obj":"OBJECT","images":[],"user":\#(user),"anonymous":false,"create_time"\#
            :"","update_time":"","like":false,"like_num":0,"comment_num":0,"own":false,"rate":\#
            0,"reply_user":\#(user),"reply_obj":"","text":"评论","sub":[]}
            """#
        let childID = damage == "nested-zero" ? 0 : damage == "nested-duplicate" ? 5 : 6
        let child = comment.replacingOccurrences(of: "\"id\":5", with: "\"id\":\(childID)")
            .replacingOccurrences(of: "OBJECT", with: "comment5")
        var root = comment.replacingOccurrences(of: "\"sub\":[]", with: "\"sub\":[\(child)]")
        if damage == "zero" { root = root.replacingOccurrences(of: "\"id\":5", with: "\"id\":0") }
        let rows = "[" + root + (damage == "duplicate" ? "," + root : "") + "]"
        let objects = ["poster1", "course1", "paper1"]
        let transport = Transport(
            objects.map {
                (
                    200,
                    rows.replacingOccurrences(
                        of: "OBJECT", with: damage == "object" ? "poster2" : $0)
                )
            })
        let observer = ResponseObserver()
        let shared = session(transport, observer: observer)
        let gallery = GalleryService(
            session: shared,
            preferences: {
                .init(
                    hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false,
                    hideMakeupOutliers: false)
            })
        let course = CourseService(session: shared)
        let paper = PaperService(session: shared)
        if damage == "valid" {
            #expect(
                try await gallery.fetchRawComments(objectID: "poster1", order: .newest, page: nil)
                    .first?.sub.first?.id == 6)
            #expect(try await course.fetchComments(courseID: 1, page: nil).count == 1)
            #expect(try await paper.fetchComments(paperID: 1, order: .newest, page: nil).count == 1)
        } else {
            await #expect(throws: GalleryServiceError.self) {
                try await gallery.fetchRawComments(objectID: "poster1", order: .newest, page: nil)
            }
            await #expect(throws: CourseServiceError.self) {
                try await course.fetchComments(courseID: 1, page: nil)
            }
            await #expect(throws: PaperServiceError.self) {
                try await paper.fetchComments(paperID: 1, order: .newest, page: nil)
            }
        }
        #expect(observer.failures == (damage == "valid" ? 0 : 3))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func userPosterSearchChecksTheRequestedAuthor(matching: Bool) async throws {
        let rows = "[" + poster(id: 1, userID: matching ? 1 : 2) + "]"
        let transport = Transport([(200, rows)])
        let observer = ResponseObserver()
        let service = MineService(
            session: session(transport, observer: observer),
            preferences: {
                .init(
                    hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false,
                    hideMakeupOutliers: false)
            })
        if matching {
            #expect(try await service.fetchUserPosters(userID: 1, page: 0).first?.user.id == 1)
        } else {
            await #expect(throws: MineServiceError.self) {
                try await service.fetchUserPosters(userID: 1, page: 0)
            }
        }
        #expect(observer.failures == (matching ? 0 : 1))
    }

    @Test(.timeLimit(.minutes(1))) func paperCreationEditingPreserveWireContract() async throws {
        let transport = Transport([(200, #"{"id":17}"#), (204, ""), (204, "")])
        let service = PaperService(session: session(transport))
        #expect(
            try await service.createPaper(
                title: "标题", intro: "摘要", content: "正文", anonymous: true, publicEdit: false) == 17)
        try await service.updatePaper(
            id: 17, title: "编辑", intro: "摘要", content: "新正文", anonymous: false, publicEdit: true,
            lastUpdatedAt: "2026-10-01T08:00:00.123456789Z")
        try await service.deletePaper(id: 17)
        #expect(transport.requests.map(\.httpMethod) == ["POST", "PUT", "DELETE"])
        #expect(transport.requests.map { $0.url?.path } == ["/papers", "/papers/17", "/papers/17"])
        let created = try body(transport.requests[0])
        #expect(created["public_edit"] as? Bool == false && created["anonymous"] as? Bool == true)
        #expect(created["content"] as? String == "正文")
        let updated = try body(transport.requests[1])
        #expect(updated["public_edit"] as? Bool == true && updated["title"] as? String == "编辑")
        let lastTime = try #require(updated["last_time"] as? Double)
        #expect(abs(lastTime - 1_790_841_600.1234567) < 0.001)
        #expect(
            transport.requests[0].value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test(.timeLimit(.minutes(1))) func invalidArticleVersionStopsEditing() async {
        let transport = Transport([])
        let service = PaperService(session: session(transport))
        await #expect(throws: PaperServiceError.self) {
            try await service.updatePaper(
                id: 17, title: "编辑", intro: "摘要", content: "正文", anonymous: false,
                publicEdit: true, lastUpdatedAt: "")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func courseAnd() async throws {
        let comment =
            #"""
            {"id":5,"obj":"course42","images":[],"user":\#(user),"anonymous":false,"create_tim\#
            e":"","update_time":"","like":false,"like_num":0,"comment_num":0,"own":true,"rate"\#
            :8,"reply_user":\#(user),"reply_obj":"comment2","text":"回复","sub":[]}
            """#
        let like = #"{"like":true,"like_num":8}"#
        let transport = Transport([
            (200, comment), (200, comment), (200, comment),
            (200, like), (200, like), (200, like), (200, "[]"),
        ])
        let shared = session(transport)
        let courseService = CourseService(session: shared)
        let paperService = PaperService(session: shared)
        let galleryService = GalleryService(
            session: shared,
            preferences: {
                .init(
                    hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false,
                    hideMakeupOutliers: false)
            })
        #expect(
            try await courseService.createComment(
                objectID: "course42", text: "回复", replyObjectID: "comment2", replyUID: 1, rate: 8
            ).rate == 8)
        #expect(
            try await paperService.createComment(
                objectID: "paper17", text: "回复", replyObjectID: "comment2", replyUID: 1,
                anonymous: true
            ).id == 5)
        #expect(
            try await galleryService.createComment(
                objectID: "poster9", text: "回复", replyObjectID: "comment2", replyUID: 1,
                anonymous: true, imageMids: ["fixture-image"]
            ).id == 5)
        let courseBody = try body(transport.requests[0])
        let paperBody = try body(transport.requests[1])
        #expect(courseBody["rate"] as? Int == 8 && courseBody["reply_uid"] as? Int == 1)
        #expect(courseBody["reply_obj"] as? String == "comment2")
        #expect(paperBody["obj"] as? String == "paper17" && paperBody["anonymous"] as? Bool == true)
        let galleryBody = try body(transport.requests[2])
        #expect(
            galleryBody["obj"] as? String == "poster9"
                && galleryBody["image_mids"] as? [String] == ["fixture-image"])
        #expect(
            galleryBody["reply_obj"] as? String == "comment2"
                && galleryBody["reply_uid"] as? Int == 1)
        #expect(galleryBody["rate"] == nil && paperBody["rate"] == nil)
        #expect(try await courseService.like(objectID: "course42").like)
        #expect(try await paperService.sendLike(objectID: "paper17").like)
        #expect(try await galleryService.like(objectID: "poster9").like)
        for (request, object) in zip(transport.requests[3...5], ["course42", "paper17", "poster9"])
        {
            #expect(try body(request)["obj"] as? String == object)
        }
        #expect(try await courseService.fetchComments(courseID: 42, page: nil).isEmpty)
        #expect(try query(transport.requests[6]) == ["obj": "course42", "order": "new"])
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["like_num", "comment_num", "rate"])
    func courseDetailsValidateStatisticsAsTheirList(field: String) async throws {
        var value = try #require(
            JSONSerialization.jsonObject(with: Data(course.utf8)) as? [String: Any])
        value[field] = field == "rate" ? 11 : -1
        value["like"] = false
        let data = try JSONSerialization.data(withJSONObject: value)
        let observer = ResponseObserver()
        let service = CourseService(
            session: session(
                Transport([(200, String(decoding: data, as: UTF8.self))]), observer: observer))
        await #expect(throws: CourseServiceError.self) { try await service.fetchCourse(id: 42) }
        #expect(observer.failures == 1)
    }

    @Test(.timeLimit(.minutes(1))) func cancelledCourseAndPaperRequestsFinish() async {
        let transport = Transport([])
        let shared = session(transport)
        let task = Task {
            await #expect(throws: CancellationError.self) {
                try await CourseService(session: shared).fetchCourse(id: 42)
            }
            await #expect(throws: CancellationError.self) {
                try await PaperService(session: shared).fetchPaper(id: 17)
            }
        }
        task.cancel()
        await task.value
        #expect(transport.requests.isEmpty)
    }
}
