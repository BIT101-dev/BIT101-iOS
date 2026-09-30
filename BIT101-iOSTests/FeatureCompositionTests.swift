import CommunityCore
import CommunityTransport
import CourseFeature
import Foundation
import SwiftUI
import Testing
import TransportCore
import UIKit

@MainActor
@Suite(.serialized)
struct FeatureCompositionTests {
    private final class CourseList: CourseListServicing {
        var requests: [String] = []
        private var waiter: CheckedContinuation<Void, Never>?

        func fetchCourses(search: String, page: Int) async throws -> [CourseSummary] {
            requests.append(search)
            if requests.count == 2 { waiter?.resume(); waiter = nil }
            return []
        }

        func waitForLookup() async {
            if requests.count == 2 { return }
            await withCheckedContinuation { waiter = $0 }
        }
    }

    private struct OfflineTransport: HTTPTransport {
        func data(for request: URLRequest) async throws -> (Data, URLResponse) { throw URLError(.notConnectedToInternet) }
    }

    private func dependencies(list: CourseList) -> CourseDependencies {
        let session = CommunitySession(httpClient: HTTPClient(transport: OfflineTransport(), observer: nil), baseURL: AppURL.required("https://example.invalid"), credentials: { CommunityCredentials(identity: CommunitySessionIdentity(accountIdentifier: "composition-test"), cookie: "fixture") }, refresh: { _ in })
        return CourseDependencies(list: list, detail: CourseService(session: session), preferences: CommunityPreferences(snapshot: CommunityPreferenceSnapshot(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false), saveMakeupFilter: { _ in }), loadCourseCredits: { [] })
    }

    @Test(.timeLimit(.minutes(1)))
    func courseEntryUsesItsConstructorDependenciesAcrossEnvironmentComposition() async throws {
        let selected = CourseList()
        let surrounding = CourseList()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: NavigationStack {
            CourseEvaluationDestination(dependencies: dependencies(list: selected), request: .lookup(courseName: "课程", courseNumber: "COURSE-1"))
        }.environment(dependencies(list: surrounding)))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        await selected.waitForLookup()
        #expect(Set(selected.requests) == ["课程", "COURSE-1"])
        #expect(surrounding.requests.isEmpty)
    }
}
