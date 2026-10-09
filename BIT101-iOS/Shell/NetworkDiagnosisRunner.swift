import SchedulePorts
import CommunityTransport
import ClientCore
import ScoreDomain
import ScorePorts
import PaperFeature
import GalleryFeature
import TransportCore
import Combine
import Foundation

struct NetworkDiagnosisReport: Equatable, Sendable {
    let results: [String]

    var summary: String {
        results.joined(separator: "\n")
    }
}

@MainActor
struct NetworkDiagnosisSchool {
    let identity: () -> SchoolSessionIdentity
    let currentTerm: () async throws -> String
    let syncCourses: (String) async throws -> Void
    let ddl: () async throws -> Void
}

@MainActor
struct NetworkDiagnosisDependencies {
    let identity: () -> NetworkDiagnosisRunner.Identity
    let path: any NetworkPathProviding
    let httpClient: HTTPClient
    let gallery: any GalleryFeedServicing
    let paper: any PaperListServicing
    let school: NetworkDiagnosisSchool
    let transcript: any TrustedTranscriptServicing
}

@MainActor
final class NetworkDiagnosisRunner: ObservableObject {
    struct Identity: Equatable, Sendable {
        let community: CommunitySessionIdentity
        let school: SchoolSessionIdentity
    }
    enum Step: CaseIterable {
        case path
        case bit101Home
        case gallery
        case paper
        case currentTerm
        case schedule
        case ddl
        case transcript

        var title: String {
            switch self {
            case .path: return "网络路径"
            case .bit101Home: return "BIT101 首页"
            case .gallery: return "话廊接口"
            case .paper: return "文章接口"
            case .currentTerm: return "学校当前学期"
            case .schedule: return "课表与考试"
            case .ddl: return "DDL 接口"
            case .transcript: return "可信成绩单"
            }
        }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var completedCount = 0
    let totalCount = Step.allCases.count
    private var currentTermForDiagnosis: String?
    private let identity: () -> Identity
    private let diagnose: ((Step) async -> String)?

    private let dependencies: NetworkDiagnosisDependencies

    init(dependencies: NetworkDiagnosisDependencies, diagnose: ((Step) async -> String)? = nil) {
        self.dependencies = dependencies
        identity = dependencies.identity
        self.diagnose = diagnose
    }

    private func accepts(_ owner: Identity) -> Bool { !Task.isCancelled && identity() == owner }

    func run() async -> NetworkDiagnosisReport? {
        guard !isRunning, !Task.isCancelled else { return nil }
        let owner = identity()
        isRunning = true
        completedCount = 0
        currentTermForDiagnosis = nil
        defer { isRunning = false; currentTermForDiagnosis = nil }

        let independentSteps: [Step] = [.path, .bit101Home, .gallery, .paper, .currentTerm]
        var resultByStep: [String: String] = [:]
        await withTaskGroup(of: (String, String?).self) { group in
            for step in independentSteps {
                let title = step.title
                group.addTask { [self] in
                    let result = await run(step, owner: owner)
                    return (title, result)
                }
            }
            for await (title, result) in group {
                guard accepts(owner), let result else { group.cancelAll(); return }
                resultByStep[title] = result
                completedCount += 1
            }
        }

        guard accepts(owner) else { return nil }
        for step in [Step.schedule, .ddl, .transcript] {
            guard let result = await run(step, owner: owner) else { return nil }
            resultByStep[step.title] = result
            completedCount += 1
        }

        return NetworkDiagnosisReport(
            results: Step.allCases.compactMap { resultByStep[$0.title] }
        )
    }

    private func run(_ step: Step, owner: Identity) async -> String? {
        guard accepts(owner) else { return nil }
        let result = if let diagnose { await diagnose(step) } else { await runProduction(step) }
        guard accepts(owner) else { return nil }
        return result
    }

    private func runProduction(_ step: Step) async -> String {
        do {
            let detail: String
            switch step {
            case .path:
                let snapshot = dependencies.path.snapshot
                detail = snapshot.virtualNetworkLikely
                    ? "\(snapshot.summary)，可能经过虚拟网络或代理"
                    : snapshot.summary
            case .bit101Home:
                _ = try await fetch(AppURL.required("https://open.aihelpme.dev"))
                detail = "通过"
            case .gallery:
                _ = try await dependencies.gallery.fetchFeed(kind: .newest, page: nil)
                detail = "通过"
            case .paper:
                _ = try await dependencies.paper.fetchPapers(search: nil, order: .newest, page: 0)
                detail = "通过"
            case .currentTerm:
                currentTermForDiagnosis = try await dependencies.school.currentTerm()
                detail = "通过"
            case .schedule:
                let term: String
                if let currentTermForDiagnosis {
                    term = currentTermForDiagnosis
                } else {
                    term = try await dependencies.school.currentTerm()
                }
                try await dependencies.school.syncCourses(term)
                detail = "通过"
            case .ddl:
                try await dependencies.school.ddl()
                detail = "通过"
            case .transcript:
                _ = try await dependencies.transcript.fetchTrustedTranscriptPages()
                detail = "通过"
            }
            return "\(step.title)：\(detail)"
        } catch ScheduleServiceError.secondFactorRequired,
                  ScheduleServiceError.schoolSecondFactorRequired,
                  ScoreServiceError.secondFactorRequired {
            return "\(step.title)：需要短信验证"
        } catch {
            return "\(step.title)：失败，\(ErrorReportRedactor.sanitized(error.localizedDescription))"
        }
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("BIT101-iOS network diagnosis", forHTTPHeaderField: "User-Agent")
        let response = try await dependencies.httpClient.send(request, accepting: 200 ..< 400)
        guard !response.data.isEmpty else { throw URLError(.zeroByteResource) }
        return response.data
    }
}
