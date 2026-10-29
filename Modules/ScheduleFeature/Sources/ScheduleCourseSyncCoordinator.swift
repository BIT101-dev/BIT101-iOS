import ClientCore
import DesignSystemKit
import Combine
import Foundation
import ScheduleDomain
import SchedulePorts
import TransportCore

enum ScheduleAuthenticationContinuation: Equatable {
    case courseSync(term: String?)
    case availableTerms
    case classroomRefresh
}

/// 学校请求、图形与短信验证续接及取消由同一阶段维护。
@MainActor
final class ScheduleCourseSyncCoordinator: ObservableObject, ScheduleStateConsumer {
    enum Phase {
        case idle
        case syncing(term: String?)
        case loadingTerms
        case awaitingVerification(ScheduleAuthenticationContinuation, BITLoginAuthenticationChallenge)
        case submittingVerification(ScheduleAuthenticationContinuation, BITLoginAuthenticationChallenge)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var verificationError: String?
    @Published private(set) var availableTerms: [String] = []
    @Published private(set) var hasLoadedAvailableTerms = false
    @Published private(set) var notice: ScheduleNotice?
    let repository: ScheduleRepository
    let virtualNetworkLikely: @MainActor () -> Bool
    private let service: any ScheduleCourseServicing
    private var requestTask: Task<Void, Never>?
    private var revision = 0

    init(service: any ScheduleCourseServicing, repository: ScheduleRepository,
         virtualNetworkLikely: @escaping @MainActor () -> Bool) {
        self.service = service
        self.repository = repository
        self.virtualNetworkLikely = virtualNetworkLikely
    }

    deinit { requestTask?.cancel() }

    var isSyncingCourses: Bool { if case .syncing = phase { true } else { false } }
    var isLoadingTerms: Bool { if case .loadingTerms = phase { true } else { false } }
    var isSubmittingVerificationCode: Bool { if case .submittingVerification = phase { true } else { false } }
    var syncingTerm: String? { if case let .syncing(term) = phase { term } else { nil } }
    var verificationChallenge: BITLoginAuthenticationChallenge? {
        switch phase {
        case let .awaitingVerification(_, challenge), let .submittingVerification(_, challenge): challenge
        default: nil
        }
    }
    var continuation: ScheduleAuthenticationContinuation? {
        switch phase {
        case let .awaitingVerification(continuation, _), let .submittingVerification(continuation, _): continuation
        default: nil
        }
    }
    var courseSyncTerm: String? {
        guard case let .courseSync(term) = continuation else { return nil }
        return term
    }

    func reset() {
        revision &+= 1
        requestTask?.cancel()
        requestTask = nil
        phase = .idle
        verificationError = nil
        availableTerms = []
        hasLoadedAvailableTerms = false
        notice = nil
    }

    func waitForClassroomAuthentication(_ challenge: BITLoginAuthenticationChallenge) {
        guard case .idle = phase else { return }
        phase = .awaitingVerification(.classroomRefresh, challenge)
        verificationError = nil
    }

    func syncCourses(term: String?, selectTerm: (String) -> Void,
                     applyPayload: @escaping (CourseSyncPayload) async -> Void) async {
        guard case .idle = phase, !Task.isCancelled else { return }
        let requested = term?.trimmingCharacters(in: .whitespacesAndNewlines)
        let term = requested?.isEmpty == true ? nil : requested
        if let term { selectTerm(term) }
        await perform(phase: .syncing(term: term)) { [self] request, account in
            do {
                let payload = try await service.syncCourses(term: term)
                guard accepts(request, account: account) else { return }
                await applyPayload(payload)
                guard accepts(request, account: account) else { return }
                phase = .idle
            } catch {
                guard accepts(request, account: account) else { return }
                handle(error, continuing: .courseSync(term: term))
            }
        }
    }

    func loadAvailableTerms() async {
        guard case .idle = phase else { return }
        await perform(phase: .loadingTerms) { [self] request, account in
            do {
                let terms = try await service.fetchAvailableTerms()
                guard accepts(request, account: account) else { return }
                availableTerms = terms
                hasLoadedAvailableTerms = true
                phase = .idle
            } catch {
                guard accepts(request, account: account) else { return }
                handle(error, continuing: .availableTerms)
            }
        }
    }

    func submitVerificationCode(_ code: String, applyPayload: @escaping (CourseSyncPayload) async -> Void,
                       refreshClassrooms: @escaping () async -> Void) async {
        guard case let .awaitingVerification(continuation, challenge) = phase else { return }
        let code = AppVerificationCode.normalize(code, isCaptcha: challenge.isCaptcha)
        guard AppVerificationCode.isValid(code, isCaptcha: challenge.isCaptcha) else {
            verificationError = AppVerificationCode.validationMessage(isCaptcha: challenge.isCaptcha)
            return
        }
        verificationError = nil
        await perform(phase: .submittingVerification(continuation, challenge)) { [self] request, account in
            do {
                try await service.submitVerificationCodeForTeachingCenterAuthentication(code, for: challenge)
                guard accepts(request, account: account) else { return }
                phase = .idle
                switch continuation {
                case .availableTerms, .classroomRefresh:
                    if continuation == .classroomRefresh {
                        await refreshClassrooms()
                    } else {
                        await loadAvailableTerms()
                    }
                case let .courseSync(term):
                    phase = .syncing(term: term)
                    let payload = try await service.syncCourses(term: term)
                    guard accepts(request, account: account) else { return }
                    await applyPayload(payload)
                    guard accepts(request, account: account) else { return }
                    phase = .idle
                }
            } catch {
                guard accepts(request, account: account) else { return }
                handle(error, continuing: continuation)
            }
        }
    }

    func dismissVerificationChallenge() {
        guard case .awaitingVerification = phase else { return }
        revision &+= 1
        phase = .idle
        verificationError = nil
    }

    private func accepts(_ request: Int, account: Int) -> Bool {
        revision == request && accountGeneration == account && !Task.isCancelled
    }

    private func perform(phase: Phase, operation: @escaping (Int, Int) async -> Void) async {
        guard !Task.isCancelled else { return }
        revision &+= 1
        let request = revision
        let account = accountGeneration
        self.phase = phase
        let task = Task { await operation(request, account) }
        requestTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard revision == request, accountGeneration == account else { return }
        requestTask = nil
        switch self.phase {
        case .syncing, .loadingTerms: self.phase = .idle
        case let .submittingVerification(continuation, challenge): self.phase = .awaitingVerification(continuation, challenge)
        case .idle, .awaitingVerification: break
        }
    }

    private func handle(_ error: Error, continuing continuation: ScheduleAuthenticationContinuation) {
        guard !TaskCancellation.matches(error) else { return }
        switch error {
        case ScheduleServiceError.secondFactorRequired(let challenge):
            phase = .awaitingVerification(continuation, challenge)
            verificationError = nil
        case let error as ScheduleServiceError where error.isSchoolTransportFailure:
            phase = .idle
            verificationError = nil
            notice = schoolFailureNotice(title: "学校服务连接失败", message: error.schoolTransportFailureMessage,
                networkFailure: true, underlyingError: error)
        case let error where SchoolServiceFailure.from(error) != nil:
            phase = .idle
            verificationError = nil
            notice = schoolFailureNotice(title: "学校认证失败", message: error.localizedDescription, underlyingError: error)
        case ScheduleServiceError.challengeInvalid(let message):
            phase = .idle
            verificationError = nil
            notice = .userInput(title: "验证已失效", message: message, underlyingError: error)
        case ScheduleServiceError.authenticationFailed(let message) where isSubmittingVerificationCode:
            verificationError = "认证服务处理失败，请点击取消后重新同步课表。\n\(message)"
        case let error as ScheduleServiceError where error.isUnpublishedCourseSchedule:
            notice = .userInput(title: "课表暂未发布", message: error.localizedDescription)
        default:
            if isSubmittingVerificationCode {
                verificationError = error.localizedDescription
            } else {
                notice = schoolFailureNotice(title: continuation == .availableTerms ? "学期列表加载失败" : "课表同步失败",
                    message: error.localizedDescription, networkFailure: Self.isLikelySchoolTransportError(error), underlyingError: error)
            }
        }
    }
}
