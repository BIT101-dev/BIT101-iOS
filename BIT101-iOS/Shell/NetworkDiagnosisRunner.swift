import SchedulePorts
import CommunityTransport
import ClientCore
import ScoreDomain
import ScoreInfrastructure
import ScheduleDomain
import PaperFeature
import GalleryFeature
import TransportCore
import ScoreFeature
import ScheduleInfrastructure
import Combine
import Foundation

struct NetworkDiagnosisReport: Equatable, Sendable {
    let results: [String]

    var summary: String {
        results.joined(separator: "\n")
    }
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

    init(identity: @escaping () -> Identity = {
        .init(community: AppAccountSession.storage.communityCredentials.identity,
            school: AppAccountSession.storage.schoolSessionIdentity)
    }, diagnose: ((Step) async -> String)? = nil) {
        self.identity = identity
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
                let snapshot = NetworkConnectionDescription.shared.snapshot
                detail = snapshot.virtualNetworkLikely
                    ? "\(snapshot.summary)，可能经过虚拟网络或代理"
                    : snapshot.summary
            case .bit101Home:
                _ = try await fetch(AppURL.required("https://open.aihelpme.dev"))
                detail = "通过"
            case .gallery:
                _ = try await GalleryService().fetchFeed(kind: .newest, page: nil)
                detail = "通过"
            case .paper:
                _ = try await PaperService().fetchPapers(search: nil, order: .newest, page: 0)
                detail = "通过"
            case .currentTerm:
                currentTermForDiagnosis = try await ScheduleServiceFactory.make().fetchCurrentTermOnly()
                detail = "通过"
            case .schedule:
                let service = ScheduleServiceFactory.make()
                let term: String
                if let currentTermForDiagnosis {
                    term = currentTermForDiagnosis
                } else {
                    term = try await service.fetchCurrentTermOnly()
                }
                _ = try await service.syncCourses(term: term)
                detail = "通过"
            case .ddl:
                _ = try await ScheduleServiceFactory.make().fetchEclassDDLEventsForPreflight()
                detail = "通过"
            case .transcript:
                _ = try await ScoreService().fetchTrustedTranscriptPages()
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
        let response = try await HTTPClient.shared.send(request, accepting: 200 ..< 400)
        guard !response.data.isEmpty else { throw URLError(.zeroByteResource) }
        return response.data
    }
}
