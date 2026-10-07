import ClientCore
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

/// 学校请求、短信续接及取消由同一阶段维护。
@MainActor
final class ScheduleCourseSyncCoordinator: ObservableObject, ScheduleStateConsumer {
    enum Phase {
        case idle
        case syncing(term: String?)
        case loadingTerms
        case awaitingSMS(ScheduleAuthenticationContinuation, BITLoginAuthenticationChallenge)
        case submittingSMS(ScheduleAuthenticationContinuation, BITLoginAuthenticationChallenge)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var smsVerificationError: String?
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
    var isSubmittingSMSCode: Bool { if case .submittingSMS = phase { true } else { false } }
    var syncingTerm: String? { if case let .syncing(term) = phase { term } else { nil } }
    var smsChallenge: BITLoginAuthenticationChallenge? {
        switch phase {
        case let .awaitingSMS(_, challenge), let .submittingSMS(_, challenge): challenge
        default: nil
        }
    }
    var continuation: ScheduleAuthenticationContinuation? {
        switch phase {
        case let .awaitingSMS(continuation, _), let .submittingSMS(continuation, _): continuation
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
        smsVerificationError = nil
        availableTerms = []
        hasLoadedAvailableTerms = false
        notice = nil
    }

    func waitForClassroomAuthentication(_ challenge: BITLoginAuthenticationChallenge) {
        guard case .idle = phase else { return }
        phase = .awaitingSMS(.classroomRefresh, challenge)
        smsVerificationError = nil
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

    func submitSMSCode(_ code: String, applyPayload: @escaping (CourseSyncPayload) async -> Void,
                       refreshClassrooms: @escaping () async -> Void) async {
        guard case let .awaitingSMS(continuation, challenge) = phase else { return }
        let code = code.filter(\.isNumber)
        guard (4 ... 8).contains(code.count) else {
            smsVerificationError = "请输入短信中的 4 至 8 位验证码。"
            return
        }
        smsVerificationError = nil
        await perform(phase: .submittingSMS(continuation, challenge)) { [self] request, account in
            do {
                switch continuation {
                case .availableTerms, .classroomRefresh:
                    try await service.submitSMSCodeForTeachingCenterAuthentication(code, for: challenge)
                    guard accepts(request, account: account) else { return }
                    phase = .idle
                    if continuation == .classroomRefresh {
                        await refreshClassrooms()
                    } else {
                        await loadAvailableTerms()
                    }
                case let .courseSync(term):
                    let payload = try await service.submitSMSCode(code, for: challenge, term: term)
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

    func dismissSMSChallenge() {
        guard case .awaitingSMS = phase else { return }
        revision &+= 1
        phase = .idle
        smsVerificationError = nil
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
        case let .submittingSMS(continuation, challenge): self.phase = .awaitingSMS(continuation, challenge)
        case .idle, .awaitingSMS: break
        }
    }

    private func handle(_ error: Error, continuing continuation: ScheduleAuthenticationContinuation) {
        guard !TaskCancellation.matches(error) else { return }
        switch error {
        case ScheduleServiceError.secondFactorRequired(let challenge):
            let submitting = isSubmittingSMSCode
            phase = .awaitingSMS(continuation, challenge)
            smsVerificationError = submitting ? "请输入最新收到的短信验证码。" : nil
        case let error as ScheduleServiceError where error.isSchoolTransportFailure:
            phase = .idle
            smsVerificationError = nil
            notice = schoolFailureNotice(title: "学校服务连接失败", message: error.schoolTransportFailureMessage, networkFailure: true)
        case ScheduleServiceError.challengeInvalid(let message):
            phase = .idle
            smsVerificationError = nil
            notice = .userInput(title: "验证已失效", message: message)
        case ScheduleServiceError.authenticationFailed(let message) where isSubmittingSMSCode:
            smsVerificationError = "认证服务处理失败，请点击取消后重新同步课表。\n\(message)"
        case let error as ScheduleServiceError where error.isUnpublishedCourseSchedule:
            notice = .userInput(title: "课表暂未发布", message: error.localizedDescription)
        default:
            if isSubmittingSMSCode {
                smsVerificationError = error.localizedDescription
            } else {
                notice = schoolFailureNotice(title: continuation == .availableTerms ? "学期列表加载失败" : "课表同步失败",
                    message: error.localizedDescription, networkFailure: Self.isLikelySchoolTransportError(error))
            }
        }
    }
}
