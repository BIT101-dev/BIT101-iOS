import Foundation
import ClientCore
import CommunityTransport
import CommunityCore
import CourseFeature
import GalleryFeature
import MineFeature
import PaperFeature
import ScheduleInfrastructure
import TransportCore

#if DEBUG || RELEASE_NETWORK_SMOKE
@MainActor
enum NetworkSmokeProductionSession {
    static func prepareReport(runID: String, dependencies: ReleaseNetworkSmokeDependencies) async -> ReleaseNetworkSmokeReport {
        let started = Date()
        var configuration: NetworkSmokeCommunityConfiguration?
        var failures: [String] = []
        do {
            let owner = dependencies.communityIdentity()
            let mine = dependencies.makeMine()
            let account = try await mine.fetchMyInfo()
            guard account.own, account.user.id > 0 else { throw URLError(.userAuthenticationRequired) }
            let following = try await mine.fetchFollowings(page: 0)
            guard let target = following.first(where: { $0.id > 0 && $0.id != account.user.id })
            else { throw configurationError("关注验收需要一个已关注的用户") }
            let gallery = dependencies.makeGallery()
            var selectedPoster: CommunityPoster?
            var checkedPosters = Set<Int>()
            for kind in [GalleryFeedKind.hot, .newest] where selectedPoster == nil {
                let feed = try await gallery.fetchFeed(kind: kind, page: nil)
                for candidate in feed.items.sorted(by: { $0.commentNum > $1.commentNum })
                    where candidate.id > 0 && candidate.commentNum > 1 && checkedPosters.insert(candidate.id).inserted
                        && !NetworkSmokePaging.imageURLs(in: candidate.images).isEmpty {
                    do {
                        for order in CommunityCommentOrder.allCases {
                            _ = try await NetworkSmokePaging.commentBatch(for: "poster\(candidate.id)", order: order,
                                currentIdentity: dependencies.communityIdentity) {
                                try await gallery.fetchComments(objectID: "poster\(candidate.id)", order: order, page: $0 == 0 ? nil : $0)
                            }
                        }
                        selectedPoster = candidate
                        break
                    } catch is NetworkSmokePaging.SamplingError { continue }
                }
            }
            guard let poster = selectedPoster else { throw configurationError("帖子验收需要带图片和评论排序差异的对象") }
            let courses = dependencies.makeCourses()
            let courseRows = try await courses.fetchCourses(search: "", page: 0)
            var selectedCourse: (id: Int, number: String)?
            for row in courseRows.sorted(by: { $0.commentNum > $1.commentNum }) where row.id > 0 && !row.number.isEmpty {
                if try await courses.fetchCourseHistories(number: row.number).isEmpty { continue }
                selectedCourse = (row.id, row.number)
                break
            }
            guard let course = selectedCourse else { throw configurationError("课程验收需要带历史成绩的对象") }
            let papers = dependencies.makePapers()
            let paperRows = try await papers.fetchPapers(search: nil, order: .newest, page: 0)
            var selectedPaper: Int?
            for row in paperRows where row.id > 0 {
                let detail = try await papers.fetchPaper(id: row.id)
                if (try? NetworkSmokePaging.checkPaperContent(detail.content)) != nil {
                    selectedPaper = row.id
                    break
                }
            }
            guard let paper = selectedPaper else { throw configurationError("文章验收需要带可读正文及图片的对象") }
            guard dependencies.communityIdentity() == owner else { throw CancellationError() }
            configuration = .init(accountID: account.user.id, followTarget: target.id,
                fixtures: .init(posterID: poster.id, courseID: course.id, courseNumber: course.number, paperID: paper))
        } catch { failures.append(error.localizedDescription) }
        let report = ReleaseNetworkSmokeReport(runID: runID, scope: .bit101, startedAt: started, finishedAt: Date(),
            passed: configuration != nil, failures: failures, authenticationBlockers: [], scheduleCache: nil,
            executedProbes: [], skippedProbes: [], coverageGaps: [], schoolSMSCoverage: "not_run",
            communityConfiguration: configuration)
        return ReleaseNetworkSmokeReportStore.complete(report, writer: dependencies.writeReport)
    }

    private static func configurationError(_ message: String) -> NSError {
        NSError(domain: "BIT101.NetworkSmoke.Configuration", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func run() async throws -> [String] {
        let original = AppAccountSession.storage.communityCredentials
        var selected = original
        let client = HTTPClient(transport: NetworkSessionPool.productionCommunity)
        let session = CommunitySession(httpClient: client, baseURL: AppURL.required("https://bit101.flwfdd.xyz"),
            credentials: { selected }, refresh: { _ in throw MineServiceError.notLoggedIn })
        let mine = MineService(session: session, preferences: { AppCommunityDependencies.preferenceSnapshot })
        let first = try await mine.fetchMyInfo()
        guard first.own, first.user.id > 0 else { throw URLError(.cannotParseResponse) }
        var evidence = ["初始账号资料 ID：\(first.user.id)"]
        selected = CommunityCredentials(identity: .init(accountIdentifier: "community-smoke-invalid", generation: 1),
            cookie: "bit101-smoke-invalid-session")
        do {
            _ = try await mine.fetchMyInfo()
            throw URLError(.userAuthenticationRequired)
        } catch MineServiceError.notLoggedIn { evidence.append("无效凭据切换：认证拒绝") }
        selected = CommunityCredentials(identity: .init(accountIdentifier: original.identity.accountIdentifier, generation: 2),
            cookie: original.cookie)
        let restored = try await MineService(session: session, preferences: { AppCommunityDependencies.preferenceSnapshot }).fetchMyInfo()
        guard restored.own, first.user.id == restored.user.id,
              original.identity == AppAccountSession.storage.communityCredentials.identity else { throw URLError(.cannotParseResponse) }
        evidence.append("恢复账号资料 ID：\(restored.user.id)")
        return evidence
    }

    static func school() -> ScheduleService {
        let state = AppSchoolSession.teachingCenter
        let api = BIT101APIClient(
            httpClient: HTTPClient(transport: NetworkSessionPool.productionSchoolCAS),
            noRedirectHTTPClient: HTTPClient(transport: NetworkSessionPool.productionSchoolCASManualRedirects))
        return ScheduleService(credentials: AppAccountSession.storage, crypto: AppScheduleServiceCrypto(),
            schoolSessionRestorer: AppScheduleSchoolSessionRestorer { try await LoginService(storage: AppAccountSession.storage, apiClient: api).restoreSchoolSessionIfNeeded() },
            teachingCenterState: state, rawCourseResponseHandler: nil,
            transport: NetworkSessionPool.productionTeachingCenter, observer: HTTPClient.appObserver,
            nativeAuthenticator: AppNativeSchoolAuthentication.make(state: state, productionPolicy: true))
    }
}
#endif
