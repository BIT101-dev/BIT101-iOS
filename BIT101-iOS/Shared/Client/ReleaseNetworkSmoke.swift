import ClientCore
import CommunityCore
import CourseFeature
import Foundation
import GalleryFeature
import MediaKit
import MineFeature
import PaperFeature
import ScheduleContracts
import ScheduleDomain
import ScheduleInfrastructure
import SchedulePorts
import ScoreDomain
import ScoreFeature
import ScoreInfrastructure
import ScorePorts
import TransportCore

// MARK: - Release network smoke

#if DEBUG || RELEASE_NETWORK_SMOKE

@MainActor
final class ReleaseNetworkSmokeRunner {
    private static let executionGate = NetworkSmokeExecutionGate()
    let dependencies: ReleaseNetworkSmokeDependencies
    var failures: [String] = []
    var communitySessionAvailable = true
    var communityWriteEvidence: [String] = []
    var productionSessionEvidence: [String] = []
    var authenticationBlockers: [String] = []
    var scheduleCache: ScheduleCacheAuditSnapshot?
    var eclassDDL: EclassDDLAudit?
    var executedProbes: [String] = []
    var skippedProbes: [String] = []
    var coverageGaps: [String] = []
    var requestEvidence: [NetworkSmokeRequestEvidence] = []
    var schoolSMSHandler: SchoolSMSCodeHandler?
    var schoolSMSSchedule: (any NetworkSmokeScheduleServicing)?
    var smsSubmissions = 0
    var submittedSMSPurposes: [String] = []
    var verifiedSMSProbes: [SchoolSMSProbeEvidence] = []
    var authenticatedSchoolProbes: [SchoolSMSProbeEvidence] = []
    var requestedSMSPurposes: [String] = []
    var requestedScheduleTerm: String?
    var currentScheduleTerm: String?
    var validatedScheduleTerm: String?

    init(dependencies: ReleaseNetworkSmokeDependencies = .init()) {
        self.dependencies = dependencies
    }

    func emit(_ message: String) { print(message) }

    func run(
        scope: NetworkSmokeScope,
        runID: String = UUID().uuidString,
        capture: NetworkSmokeCapture = .none,
        term requestedTerm: String? = nil,
        communityFollowTarget: Int? = nil,
        communityExpectedAccount: Int? = nil,
        communityRecoveryConfirmation: CommunityWriteRecoveryConfirmation? = nil,
        fixtures: NetworkSmokeFixtures? = nil,
        schoolSMSCodeHandler: SchoolSMSCodeHandler? = nil
    ) async -> ReleaseNetworkSmokeReport {
        let startedAt = Date()
        let acquired = await Self.executionGate.acquire()
        guard acquired && !Task.isCancelled else {
            if acquired { Self.executionGate.release() }
            return ReleaseNetworkSmokeReport(
                runID: runID, scope: scope, startedAt: startedAt, finishedAt: Date(),
                passed: false, failures: ["网络 Smoke 排队已取消"], authenticationBlockers: [],
                scheduleCache: nil,
                executedProbes: [], skippedProbes: [], coverageGaps: ["执行已取消"],
                schoolSMSCoverage: "not_run",
                requiredProbes: scope.requiredProbes)
        }
        defer { Self.executionGate.release() }
        failures = []
        communitySessionAvailable = true
        communityWriteEvidence = []
        productionSessionEvidence = []
        authenticationBlockers = []
        scheduleCache = nil
        eclassDDL = nil
        executedProbes = []
        skippedProbes = []
        coverageGaps = []
        requestEvidence = []
        smsSubmissions = 0
        submittedSMSPurposes = []
        verifiedSMSProbes = []
        authenticatedSchoolProbes = []
        requestedSMSPurposes = []
        let normalizedTerm = requestedTerm?.trimmingCharacters(in: .whitespacesAndNewlines)
        requestedScheduleTerm = normalizedTerm?.isEmpty == false ? normalizedTerm : nil
        currentScheduleTerm = nil
        validatedScheduleTerm = nil
        if let handler = schoolSMSCodeHandler {
            schoolSMSHandler = { [weak self] request in
                self?.requestedSMSPurposes.append(request.purpose)
                print("NETWORK_SMOKE_SMS_REQUIRED purpose=\(request.purpose)")
                let code = try await handler(request)
                self?.smsSubmissions += 1
                self?.submittedSMSPurposes.append(request.purpose)
                return code
            }
        } else {
            schoolSMSHandler = nil
        }
        #if RELEASE_NETWORK_SMOKE
        AppNativeSchoolAuthentication.smokeSMSCodeHandler = schoolSMSHandler
        defer { AppNativeSchoolAuthentication.smokeSMSCodeHandler = nil }
        #endif
        defer {
            schoolSMSHandler = nil
            schoolSMSSchedule = nil
        }
        if capture == .communityFixtures {
            return await NetworkSmokeProductionSession.prepareReport(
                runID: runID, dependencies: dependencies)
        }

        if scope != .communityCleanup && scope != .communityWrites {
            do { try dependencies.clearRawCourseResponse() } catch {
                let area = Self.failureArea(for: scope)
                recordFailure("原始课表采样清理", error.localizedDescription, area: area, scope: scope)
                return await finishReport(runID: runID, scope: scope, startedAt: startedAt)
            }
        }

        if scope.includes(.authentication) {
            executedProbes.append("community.login")
            print("NETWORK_SMOKE_START name=community.login")
            let loginStartedAt = Date()
            do {
                let loginResult = try await captureNetworkRequests(
                    "community.login", required: true
                ) {
                    try await self.dependencies.checkLogin()
                }
                if let signedInStudentID = loginResult, !signedInStudentID.isEmpty {
                    print(
                        """
                        NETWORK_SMOKE_PASS name=community.login elapsed=\
                        \(Self.duration(Date().timeIntervalSince(loginStartedAt)))
                        """
                    )
                } else {
                    communitySessionAvailable = false
                    recordFailure(
                        "community.login", "社区登录状态验证失败", area: .authentication, scope: scope)
                }
            } catch {
                communitySessionAvailable = false
                recordFailure(
                    "community.login", error.localizedDescription, area: .authentication,
                    scope: scope, elapsed: Date().timeIntervalSince(loginStartedAt))
            }
        }

        if scope == .communityWrites || scope == .communityCleanup {
            communityWriteEvidence =
                await probe(.communityWrites, area: .communityWrites, scope: scope) {
                    try await self.dependencies.communityWriteProbe(
                        runID, scope == .communityCleanup, communityFollowTarget,
                        communityExpectedAccount, fixtures, communityRecoveryConfirmation,
                        { images in
                            let urls = NetworkSmokePaging.imageURLs(in: images)
                            guard !urls.isEmpty else { throw URLError(.cannotParseResponse) }
                            self.executedProbes.append(NetworkSmokeProbe.galleryImage.rawValue)
                            try await self.captureNetworkRequests(
                                NetworkSmokeProbe.galleryImage.rawValue,
                                required: true,
                                expectedParameters: NetworkSmokePaging.imageResourceParameters(
                                    urls)
                            ) {
                                try await self.fetchAllImages(urls: urls)
                            }
                        })
                } ?? []
            return await finishReport(runID: runID, scope: scope, startedAt: startedAt)
        }

        let gallery = dependencies.makeGallery()
        let mine = dependencies.makeMine()
        let messageOwner = dependencies.communityIdentity()
        let myInfo = await probe(.myProfile, area: .bit101, scope: scope) {
            try await mine.fetchMyInfo()
        }
        let courses = dependencies.makeCourses()
        await runInParallel([
            {
                _ = await self.probe(.appAssociation, area: .bit101, scope: scope) {
                    let request = URLRequest(
                        url: Self.aasaURL, cachePolicy: .reloadIgnoringLocalCacheData,
                        timeoutInterval: 30)
                    return try Self.validateAASA(
                        try await self.dependencies.aasaHTTPClient.send(request))
                }
            },
            {
                _ = await self.probe(.shareIcon, area: .bit101, scope: scope) {
                    try await self.fetchImageCount(
                        urlString: "https://open.aihelpme.dev/share-icon.jpg")
                }
            },
            {
                _ = await self.probe(.feedbackPreflight, area: .bit101, scope: scope) {
                    var request = URLRequest(
                        url: AppEndpoints.feedbackReports)
                    request.httpMethod = "OPTIONS"
                    request.setValue("https://bit101.cn", forHTTPHeaderField: "Origin")
                    request.setValue(
                        "POST", forHTTPHeaderField: "Access-Control-Request-Method")
                    request.setValue(
                        "content-type", forHTTPHeaderField: "Access-Control-Request-Headers")
                    let response = try await self.dependencies.externalHTTPClient.send(
                        request, accepting: 200..<300)
                    let methods = Set(
                        (response.response.value(
                            forHTTPHeaderField: "Access-Control-Allow-Methods") ?? "")
                            .split(separator: ",").map {
                                $0.trimmingCharacters(in: .whitespaces).uppercased()
                            })
                    let headers = Set(
                        (response.response.value(
                            forHTTPHeaderField: "Access-Control-Allow-Headers") ?? "")
                            .split(separator: ",").map {
                                $0.trimmingCharacters(in: .whitespaces).lowercased()
                            })
                    guard response.response.statusCode == 204, response.data.isEmpty,
                        response.response.value(
                            forHTTPHeaderField: "Access-Control-Allow-Origin") == "*",
                        methods.contains("POST"), headers.contains("content-type")
                    else { throw URLError(.badServerResponse) }
                    return true
                }
            },
        ])
        // The Worker root intentionally redirects to the public gallery landing page.
        _ = await probe(.homeRedirect, area: .bit101, scope: scope) {
            try await self.fetchHTMLCount(
                urlString: "https://open.aihelpme.dev",
                expectedHost: "bit101.cn",
                initialHost: "open.aihelpme.dev"
            )
        }
        _ = await probe(.galleryNewest, area: .bit101, scope: scope) {
            try await NetworkSmokePaging.posterPage(
                order: .newest, currentIdentity: self.dependencies.communityIdentity
            ) { try await gallery.fetchFeed(kind: .newest, page: $0 == 0 ? nil : $0) }.items
        }
        let validatedFixtures = fixtures.flatMap { $0.isValid ? $0 : nil }
        var gallerySearchText = ""
        if let fixture = validatedFixtures {
            await runInParallel([
                {
                    let detail = await self.probe(
                        .galleryDetail, area: .bit101, scope: scope,
                        expectedParameters: ["path": "/posters/\(fixture.posterID)"]
                    ) {
                        let detail = try await gallery.fetchPoster(id: fixture.posterID)
                        try NetworkSmokePaging.validateEntityIdentity(
                            expected: fixture.posterID, actual: detail.id)
                        return detail
                    }
                    if let detail {
                        gallerySearchText = (detail.title.isEmpty ? detail.text : detail.title)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let images = NetworkSmokePaging.imageURLs(in: detail.images)
                        _ = await self.probe(
                            .galleryImage, area: .bit101, scope: scope,
                            expectedParameters: NetworkSmokePaging.imageResourceParameters(
                                images)
                        ) {
                            try await self.verifyGalleryImages(images)
                        }
                    } else {
                        self.recordSkip(
                            "gallery.image", "维护帖子详情读取失败", area: .bit101, scope: scope)
                    }
                },
                {
                    let objectID = "poster\(fixture.posterID)"
                    _ = await self.probe(
                        .galleryComments, area: .bit101, scope: scope,
                        expectedParameters: ["obj": objectID]
                    ) {
                        try await self.fetchAllComments(gallery: gallery, objectID: objectID)
                    }
                },
            ])
            _ = await probe(
                .galleryWeb, area: .bit101, scope: scope,
                expectedParameters: ["path": "/gallery/\(fixture.posterID)"]
            ) {
                try await self.fetchHTMLCount(
                    urlString: "https://open.aihelpme.dev/gallery/\(fixture.posterID)",
                    expectedHost: "open.aihelpme.dev")
            }
        } else {
            let reason = "社区详情验收需要有效的维护对象配置 BIT101_NETWORK_SMOKE_FIXTURES"
            recordSkip("gallery.detail", reason, area: .bit101, scope: scope)
            recordSkip("gallery.comments", reason, area: .bit101, scope: scope)
            recordSkip("gallery.web", reason, area: .bit101, scope: scope)
            recordSkip("gallery.image", reason, area: .bit101, scope: scope)
        }
        var galleryOperations: [@MainActor () async -> Void] = [
            {
                _ = await self.probe(.galleryFollowing, area: .bit101, scope: scope) {
                    try await NetworkSmokePaging.posterPage(
                        order: .newest, currentIdentity: self.dependencies.communityIdentity
                    ) { try await gallery.fetchFeed(kind: .follow, page: $0 == 0 ? nil : $0) }
                }
            },
            {
                _ = await self.probe(.galleryHot, area: .bit101, scope: scope) {
                    try await NetworkSmokePaging.batch(
                        currentIdentity: self.dependencies.communityIdentity
                    ) { try await gallery.fetchFeed(kind: .hot, page: $0 == 0 ? nil : $0) }
                }
            },
            {
                _ = await self.probe(.galleryRecommend, area: .bit101, scope: scope) {
                    try await NetworkSmokePaging.batch(
                        currentIdentity: self.dependencies.communityIdentity
                    ) { try await gallery.fetchRecommendPage(sourcePage: $0) }
                }
            },
            {
                _ = await self.probe(.galleryBots, area: .bit101, scope: scope) {
                    let sampled = try await NetworkSmokePaging.batch(
                        requiresContent: true,
                        currentIdentity: self.dependencies.communityIdentity
                    ) {
                        let batch = try await gallery.fetchBotFeed(startPage: $0)
                        try NetworkSmokePaging.checkBotPosters(batch.items)
                        return batch
                    }
                    guard !sampled.items.isEmpty else {
                        throw NetworkSmokePaging.SamplingError.insufficientSample(
                            "机器人验收需要有效的分类样本。")
                    }
                    return sampled
                }
            },
            {
                _ = await self.probe(.reportTypes, area: .bit101, scope: scope) {
                    try NetworkSmokePaging.checkedReportTypes(
                        try await gallery.fetchReportTypes())
                }
            },
            {
                _ = await self.probe(.galleryClaims, area: .bit101, scope: scope) {
                    try await gallery.fetchClaims()
                }
            },
            {
                _ = await self.probe(.gallerySubscriptions, area: .bit101, scope: scope) {
                    try await NetworkSmokePaging.arrayPage(
                        currentIdentity: self.dependencies.communityIdentity
                    ) { try await gallery.fetchSubscriptions(page: $0) }
                }
            },
            {
                _ = await self.probe(
                    .gallerySearch, area: .bit101, scope: scope,
                    expectedParameters: [
                        "search": gallerySearchText,
                        "excludedSearch": NetworkSmokePaging.excludedSearchText,
                    ]
                ) {
                    try await NetworkSmokePaging.posterSearch(
                        matching: validatedFixtures?.posterID ?? 0, keyword: gallerySearchText,
                        currentIdentity: self.dependencies.communityIdentity
                    ) { order, text, page in
                        try await gallery.searchPosters(
                            query: GallerySearchQuery(text: text, order: order), page: page)
                    }
                }
            },
            {
                _ = await self.probe(.messageUnread, area: .bit101, scope: scope) {
                    try await gallery.fetchMessageUnreadCounts()
                }
            },
        ]
        for messageType in GalleryMessageType.allCases {
            galleryOperations.append { [messageType] in
                _ = await self.probe(.message(messageType), area: .bit101, scope: scope) {
                    guard let communityExpectedAccount, communityExpectedAccount > 0,
                        myInfo?.user.id == communityExpectedAccount,
                        messageOwner == self.dependencies.communityIdentity()
                    else {
                        throw NSError(
                            domain: "BIT101.NetworkSmoke", code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey: "消息验收需要与指定的专用账号一致。读取消息会更新服务端未读状态。"
                            ])
                    }
                    return try await NetworkSmokePaging.messages(
                        currentIdentity: self.dependencies.communityIdentity
                    ) { try await gallery.fetchMessages(type: messageType, lastID: $0) }
                }
            }
        }
        await runInParallel(galleryOperations)

        _ = await probe(.courseList, area: .bit101, scope: scope) {
            try await NetworkSmokePaging.arrayPage(
                requiresContent: validatedFixtures != nil,
                currentIdentity: self.dependencies.communityIdentity
            ) { try await courses.fetchCourses(search: "", page: $0) }
        }
        if let fixture = validatedFixtures {
            await runInParallel([
                {
                    _ = await self.probe(
                        .courseSearch, area: .bit101, scope: scope,
                        expectedParameters: [
                            "search": fixture.courseNumber,
                            "excludedSearch": NetworkSmokePaging.excludedSearchText,
                        ]
                    ) {
                        try await NetworkSmokePaging.searchPage(
                            matching: fixture.courseID, keyword: fixture.courseNumber,
                            currentIdentity: self.dependencies.communityIdentity
                        ) { try await courses.fetchCourses(search: $0, page: $1) }
                    }
                },
                {
                    _ = await self.probe(
                        .courseDetail, area: .bit101, scope: scope,
                        expectedParameters: ["path": "/courses/\(fixture.courseID)"]
                    ) {
                        let detail = try await courses.fetchCourse(id: fixture.courseID)
                        try NetworkSmokePaging.validateEntityIdentity(
                            expected: fixture.courseID, actual: detail.id)
                        guard detail.number == fixture.courseNumber else {
                            throw URLError(.badServerResponse)
                        }
                        return detail
                    }
                },
                {
                    let objectID = "course\(fixture.courseID)"
                    _ = await self.probe(
                        .courseComments, area: .bit101, scope: scope,
                        expectedParameters: ["obj": objectID]
                    ) {
                        try await self.fetchCourseComments(
                            courses: courses, courseID: fixture.courseID, objectID: objectID
                        )
                    }
                },
                {
                    _ = await self.probe(
                        .courseHistory, area: .bit101, scope: scope,
                        expectedParameters: [
                            "path": "/courses/histories/\(fixture.courseNumber)"
                        ]
                    ) {
                        let grades = try await courses.fetchCourseHistories(
                            number: fixture.courseNumber)
                        try NetworkSmokePaging.checkCourseHistories(grades)
                        return grades
                    }
                },
                {
                    _ = await self.probe(
                        .courseWeb, area: .bit101, scope: scope,
                        expectedParameters: ["path": "/course/\(fixture.courseID)"]
                    ) {
                        try await self.fetchHTMLCount(
                            urlString: "https://open.aihelpme.dev/course/\(fixture.courseID)",
                            expectedHost: "open.aihelpme.dev")
                    }
                },
            ])
        } else {
            let reason = "社区详情验收需要有效的维护对象配置 BIT101_NETWORK_SMOKE_FIXTURES"
            recordSkip("course.search", reason, area: .bit101, scope: scope)
            recordSkip("course.detail", reason, area: .bit101, scope: scope)
            recordSkip("course.comments", reason, area: .bit101, scope: scope)
            recordSkip("course.history", reason, area: .bit101, scope: scope)
            recordSkip("course.web", reason, area: .bit101, scope: scope)
        }

        let papers = dependencies.makePapers()
        _ = await probe(.paperList, area: .bit101, scope: scope) {
            try await NetworkSmokePaging.paperPage(
                order: .newest, requiresContent: validatedFixtures != nil,
                currentIdentity: self.dependencies.communityIdentity
            ) { try await papers.fetchPapers(search: nil, order: .newest, page: $0) }
        }
        if let fixture = validatedFixtures {
            await runInParallel([
                {
                    let detail = await self.probe(
                        .paperDetail, area: .bit101, scope: scope,
                        expectedParameters: ["path": "/papers/\(fixture.paperID)"]
                    ) {
                        _ = try await papers.fetchPreviewMetadata(id: fixture.paperID)
                        let detail = try await papers.fetchPaper(id: fixture.paperID)
                        try NetworkSmokePaging.validateEntityIdentity(
                            expected: fixture.paperID, actual: detail.id)
                        return (
                            images: try NetworkSmokePaging.checkPaperContent(detail.content),
                            title: detail.title
                        )
                    }
                    if let detail {
                        let keyword = detail.title.trimmingCharacters(
                            in: .whitespacesAndNewlines)
                        _ = await self.probe(
                            .paperSearch, area: .bit101, scope: scope,
                            expectedParameters: [
                                "search": keyword,
                                "excludedSearch": NetworkSmokePaging.excludedSearchText,
                            ]
                        ) {
                            try await self.searchPaperPage(
                                papers: papers, paperID: fixture.paperID, keyword: keyword
                            )
                        }
                        _ = await self.probe(
                            .paperImage, area: .bit101, scope: scope,
                            expectedParameters: NetworkSmokePaging.imageResourceParameters(
                                detail.images)
                        ) {
                            try await self.fetchAllImages(urls: detail.images)
                        }
                    } else {
                        self.recordSkip(
                            "paper.search", "文章搜索采样需要维护对象的标题", area: .bit101, scope: scope)
                        self.recordSkip(
                            "paper.image", "文章正文采样需要可渲染的维护对象", area: .bit101, scope: scope)
                    }
                },
                {
                    let objectID = "paper\(fixture.paperID)"
                    _ = await self.probe(
                        .paperComments, area: .bit101, scope: scope,
                        expectedParameters: ["obj": objectID]
                    ) {
                        try await self.fetchAllPaperComments(
                            papers: papers, paperID: fixture.paperID, objectID: objectID
                        )
                    }
                },
                {
                    _ = await self.probe(
                        .paperWeb, area: .bit101, scope: scope,
                        expectedParameters: ["path": "/paper/\(fixture.paperID)"]
                    ) {
                        try await self.fetchHTMLCount(
                            urlString: "https://open.aihelpme.dev/paper/\(fixture.paperID)",
                            expectedHost: "open.aihelpme.dev")
                    }
                },
            ])
        } else {
            let reason = "社区详情验收需要有效的维护对象配置 BIT101_NETWORK_SMOKE_FIXTURES"
            recordSkip("paper.search", reason, area: .bit101, scope: scope)
            recordSkip("paper.detail", reason, area: .bit101, scope: scope)
            recordSkip("paper.image", reason, area: .bit101, scope: scope)
            recordSkip("paper.comments", reason, area: .bit101, scope: scope)
            recordSkip("paper.web", reason, area: .bit101, scope: scope)
        }
        await runInParallel(
            PaperSortOrder.allCases.map { order in
                {
                    _ = await self.probe(.paperSort(order), area: .bit101, scope: scope) {
                        try await NetworkSmokePaging.paperPage(
                            order: order, requiresOrderingEvidence: true,
                            currentIdentity: self.dependencies.communityIdentity
                        ) {
                            try await papers.fetchPapers(search: nil, order: order, page: $0)
                        }
                    }
                }
            })

        productionSessionEvidence =
            await probe(.productionSession, area: .bit101, scope: scope) {
                try await self.dependencies.productionSessionProbe()
            } ?? []
        await runInParallel([
            {
                _ = await self.probe(.myFollowing, area: .bit101, scope: scope) {
                    try await NetworkSmokePaging.arrayPage(
                        currentIdentity: self.dependencies.communityIdentity
                    ) { try await mine.fetchFollowings(page: $0) }
                }
            },
            {
                _ = await self.probe(.myFollowers, area: .bit101, scope: scope) {
                    try await NetworkSmokePaging.arrayPage(
                        currentIdentity: self.dependencies.communityIdentity
                    ) { try await mine.fetchFollowers(page: $0) }
                }
            },
        ])
        if let myInfo {
            await runInParallel([
                {
                    _ = await self.probe(
                        .myPosts, area: .bit101, scope: scope, expectedParameters: ["uid": "0"]
                    ) {
                        try await NetworkSmokePaging.arrayPage(
                            currentIdentity: self.dependencies.communityIdentity
                        ) {
                            let posters = try await mine.fetchMyPosters(page: $0)
                            try NetworkSmokePaging.checkPosters(posters, for: myInfo.user.id)
                            return posters
                        }
                    }
                },
                {
                    _ = await self.probe(
                        .userProfile, area: .bit101, scope: scope,
                        expectedParameters: ["path": "/user/info/\(myInfo.user.id)"]
                    ) {
                        let detail = try await mine.fetchUserInfo(id: myInfo.user.id)
                        try NetworkSmokePaging.validateEntityIdentity(
                            expected: myInfo.user.id, actual: detail.user.id)
                        return detail
                    }
                },
                {
                    _ = await self.probe(
                        .userPosts, area: .bit101, scope: scope,
                        expectedParameters: ["uid": String(myInfo.user.id)]
                    ) {
                        try await NetworkSmokePaging.arrayPage(
                            currentIdentity: self.dependencies.communityIdentity
                        ) {
                            let posters = try await mine.fetchUserPosters(
                                userID: myInfo.user.id, page: $0)
                            try NetworkSmokePaging.checkPosters(posters, for: myInfo.user.id)
                            return posters
                        }
                    }
                },
            ])
        } else {
            recordSkip("profile.posts", "资料采样没有可用数据", area: .bit101, scope: scope)
            recordSkip("user.profile", "资料采样没有可用数据", area: .bit101, scope: scope)
            recordSkip("user.posts", "资料采样没有可用数据", area: .bit101, scope: scope)
        }

        // 可信成绩单采样位于学校相关流程的首段，模拟用户手动点击“申请可信成绩单”的路径。
        let transcriptService = dependencies.makeScores()
        _ = await probe(.transcript, area: .transcript, scope: scope) {
            let result: TrustedTranscriptPages
            do {
                result = try await transcriptService.fetchTrustedPages(onPage: nil)
            } catch ScoreServiceError.secondFactorRequired(let challenge) {
                guard !challenge.isCaptcha, let handler = self.schoolSMSHandler else {
                    throw ScoreServiceError.secondFactorRequired(challenge)
                }
                let code = try await handler(
                    SchoolSMSCodeRequest(
                        maskedPhone: challenge.maskedPhone ?? "", purpose: "jwb_cjd"))
                let authenticated = try await transcriptService.submitTranscriptCode(
                    code, for: challenge)
                result = try await transcriptService.fetchTrustedPages(
                    authenticatedBy: authenticated, onPage: nil)
            }
            if let failure = result.failure { throw failure }
            if let report = result.report {
                let retry = try await report.loadPages(
                    excluding: Set(result.pages.dropFirst().map(\.number)),
                    maximumBytes: TrustedTranscriptResourceLimits().maximumEncodedBytes)
                if let failure = retry.failure { throw failure }
                guard retry.pages.map(\.number) == [1] else {
                    throw ScoreServiceError.invalidResponse
                }
                _ = try Self.validateTranscriptPages(retry.pages.map(\.data))
            }
            return try Self.validateTranscriptPages(result.pages.map(\.data))
        }

        var rawCourseResponseHandler: ((Data) -> Void)?
        if capture == .rawCourseResponse {
            rawCourseResponseHandler = { data in
                do { try self.dependencies.writeRawCourseResponse(data, runID) } catch {
                    self.recordFailure(
                        "原始课表采样写入", error.localizedDescription, area: .schedule, scope: scope)
                }
            }
        }
        let schedule = dependencies.makeSchedule(rawCourseResponseHandler)
        let productionSchedule = dependencies.makeProductionSchedule()
        schoolSMSSchedule = productionSchedule
        _ = await probe(.schoolSession, area: .schedule, scope: scope) {
            try await productionSchedule.fetchCurrentTermOnly()
        }
        schoolSMSSchedule = schedule
        _ = await probe(.teachingCenter, area: .schedule, scope: scope) {
            try await schedule.prepareTeachingAccess()
        }
        let currentTerm = await probe(.currentTerm, area: .schedule, scope: scope) {
            try await schedule.fetchCurrentTermOnly()
        }
        currentScheduleTerm = currentTerm
        _ = await probe(.termList, area: .schedule, scope: scope) {
            try await schedule.fetchAvailableTerms()
        }
        let term = requestedScheduleTerm ?? currentTerm
        if let term {
            let syncPayload = await probe(
                .scheduleSync, area: .schedule, scope: scope,
                expectedParameters: ["XNXQDM": term]
            ) {
                let payload = try await schedule.syncCourses(term: term)
                guard payload.term == term else { throw URLError(.badServerResponse) }
                try Self.validateCourseSyncPayload(payload)
                guard payload.courses.contains(where: { !$0.weeks.isEmpty }) else {
                    throw NetworkSmokePaging.SamplingError.insufficientSample(
                        "课表验收需要包含已排课程及实际周次的学期样本，请维护验收数据。")
                }
                return payload
            }
            validatedScheduleTerm = syncPayload?.term
            if capture == .scheduleCache, let syncPayload {
                scheduleCache = captureScheduleCache(from: syncPayload)
            }

            let campuses = await probe(.classroomCampuses, area: .schedule, scope: scope) {
                try await schedule.fetchCampuses()
            }
            if let campus = campuses?.sorted(by: { $0.code < $1.code }).first {
                let buildings = await probe(
                    .classroomBuildings, area: .schedule, scope: scope,
                    expectedParameters: ["XXXQDM": campus.code]
                ) {
                    let buildings = try await schedule.fetchBuildings(campusCode: campus.code)
                    try NetworkSmokePaging.checkBuildings(buildings, campusCode: campus.code)
                    return buildings
                }
                if let building = buildings?.sorted(by: { $0.id < $1.id }).first {
                    let termParts = term.split(separator: "-")
                    let queryDate = Date()
                    let selection = [
                        "XNXQDM": term, "JXLDM": building.id,
                        "RQ": ScheduleDateCodec.formatDate(queryDate),
                        "XQDM": termParts.last.map(String.init) ?? "",
                        "XNDM": termParts.dropLast().joined(separator: "-"),
                    ]
                    let classrooms = await probe(
                        .classroomOccupancy, area: .schedule, scope: scope,
                        expectedParameters: selection
                    ) {
                        try await self.fetchAndVerifyClassrooms(
                            schedule: schedule, buildingID: building.id,
                            term: term, queryDate: queryDate
                        )
                    }
                    if classrooms?.isEmpty == true {
                        coverageGaps.append("classroom.occupancy（所选教学楼返回空集合，空教室样本覆盖待补齐）")
                        print("NETWORK_SMOKE_GAP name=classroom.occupancy reason=empty_sample")
                    }
                } else {
                    let reason = buildings == nil ? "教学楼采样没有可用数据" : "教学楼列表为空"
                    recordSkip("classroom.occupancy", reason, area: .schedule, scope: scope)
                }
            } else {
                let reason = campuses == nil ? "校区采样没有可用数据" : "校区列表为空"
                recordSkip("classroom.buildings", reason, area: .schedule, scope: scope)
                recordSkip("classroom.occupancy", reason, area: .schedule, scope: scope)
            }
        } else {
            let reason = "当前学期采样缺少可用学期"
            recordSkip("schedule.sync", reason, area: .schedule, scope: scope)
            recordSkip("classroom.campuses", reason, area: .schedule, scope: scope)
            recordSkip("classroom.buildings", reason, area: .schedule, scope: scope)
            recordSkip("classroom.occupancy", reason, area: .schedule, scope: scope)
        }
        let nativeEclass = await probe(.eclassAuthentication, area: .ddl, scope: scope) {
            let service = try self.dependencies.makeEclassSchedule()
            let result: EclassDDLResult
            if let handler = self.schoolSMSHandler {
                result = try await service.fetchEclassDDLEvents(schoolSMSCodeHandler: handler)
            } else {
                result = try await service.probeEclassEvents()
            }
            if let failure = result.failure { throw failure }
            return result
        }
        if let eclass = await probe(
            .eclassDDL, area: .ddl, scope: scope,
            operation: {
                let result: EclassDDLResult
                if let handler = self.schoolSMSHandler {
                    result = try await schedule.fetchEclassDDLEvents(
                        schoolSMSCodeHandler: handler)
                } else {
                    result = try await schedule.probeEclassEvents()
                }
                if let failure = result.failure { throw failure }
                return result
            })
        {
            let now = Date()
            let cache = await dependencies.loadScheduleCache()
            let retentionDays = min(max(cache.ddlAfterDay, 0), 30)
            let threshold = now.addingTimeInterval(TimeInterval(-retentionDays * 24 * 3600))
            eclassDDL = EclassDDLAudit(
                nativeAuthenticationVerified: nativeEclass != nil,
                courseCount: eclass.courseCount, activityCount: eclass.activityCount,
                activityTypes: eclass.activityTypes, deadlineCount: eclass.events.count,
                upcomingDeadlineCount: eclass.events.filter { $0.dueAt >= now }.count,
                recentDeadlineCount: eclass.events.filter {
                    $0.dueAt >= now.addingTimeInterval(-7 * 24 * 3600)
                }.count,
                homeworkWithoutDeadlineCount: eclass.homeworkWithoutDeadlineCount,
                retentionDays: retentionDays,
                visibleDeadlineCount: eclass.events.filter { $0.dueAt >= threshold }.count,
                cachedEclassCount: cache.ddlEvents.filter { $0.group == "eclass" }.count,
                earliestDeadline: eclass.events.first?.dueAt,
                latestDeadline: eclass.events.last?.dueAt)
        }
        let calendarURL = await probe(.lexueCalendar, area: .ddl, scope: scope) {
            if let handler = self.schoolSMSHandler {
                return try await schedule.refreshLexueCalendarURL(schoolSMSCodeHandler: handler)
            }
            return try await schedule.probeLexueCalendarURL()
        }
        if let calendarURL {
            _ = await probe(.lexueDDL, area: .ddl, scope: scope) {
                try await schedule.syncDDLEventsForPreflight(
                    existingEvents: [],
                    storedURL: calendarURL
                )
            }
        } else {
            recordSkip("lexue.ddl", "日历订阅地址采样没有可用数据", area: .ddl, scope: scope)
        }

        // 成绩页与可信成绩单同属学校网络链路；短信二次验证时记录为 AUTH_BLOCKED，
        // 区分认证阻塞与网络故障。
        let scoreService = dependencies.makeScores()
        let scoreChallenge = await probe(.scoreAuthentication, area: .school, scope: scope) {
            do {
                return try await scoreService.startScoreChallenge()
            } catch ScoreServiceError.secondFactorRequired(let challenge) {
                guard !challenge.isCaptcha, let handler = self.schoolSMSHandler else {
                    throw ScoreServiceError.secondFactorRequired(challenge)
                }
                let code = try await handler(
                    SchoolSMSCodeRequest(
                        maskedPhone: challenge.maskedPhone ?? "", purpose: "jwb"))
                return try await scoreService.submitScoreCode(code, for: challenge)
            }
        }
        if let scoreChallenge {
            let briefScores = await probe(.scoreBrief, area: .school, scope: scope) {
                try await scoreService.fetchScores(
                    detail: false, authenticatedBy: scoreChallenge)
            }
            _ = await probe(.scoreDetail, area: .school, scope: scope) {
                let detailed = try await scoreService.fetchScores(
                    detail: true, authenticatedBy: scoreChallenge)
                guard let briefScores else { throw URLError(.cannotParseResponse) }
                try NetworkSmokePaging.checkScores(brief: briefScores, detailed: detailed)
                return detailed
            }
        }

        await runInParallel([
            {
                _ = await self.probe(.appStoreUpdate, area: .bit101, scope: scope) {
                    try await self.fetchAppStoreLookup()
                }
            },
            {
                _ = await self.probe(.emergencyUpdate, area: .bit101, scope: scope) {
                    try await self.fetchEmergencyUpdate()
                }
            },
            {
                _ = await self.probe(.feedbackRecovery, area: .bit101, scope: scope) {
                    try await self.dependencies.feedbackProbe(runID)
                }
            },
        ])

        return await finishReport(runID: runID, scope: scope, startedAt: startedAt)
    }

}

#endif
