import ScoreDomain
import ScorePorts
import MediaKit
#if os(iOS)
import TransportCore
import ClientCore
import Combine
import Foundation
import UIKit

/// 成绩单页面持有报告来源与可用分页，短信认证和图片恢复各自推进。
@MainActor
final class TrustedTranscriptViewModel: ObservableObject {
    enum State: Equatable { case idle, loading, loaded, failed(String) }
    @Published private(set) var state: State = .idle
    @Published private(set) var images: [UIImage] = []
    @Published private(set) var pageNumbers: [Int] = []
    @Published private(set) var expectedPageCount = 0
    @Published private(set) var deliveryWarning: String?
    @Published private(set) var smsChallenge: BITLoginAuthenticationChallenge?
    @Published private(set) var smsVerificationError: String?
    @Published private(set) var isSubmittingSMSCode = false
    @Published private(set) var isLoadingPages = false
    @Published private(set) var allowsDiagnostics = true

    private let service: any TrustedTranscriptServicing
    private let limits: TrustedTranscriptResourceLimits
    private var authenticatedChallenge: BITLoginAuthenticationChallenge?
    private var report: TrustedTranscriptReport?
    private var encodedBytesByPage: [Int: Int] = [:]
    private var retryRequested = false

    init(service: any TrustedTranscriptServicing, limits: TrustedTranscriptResourceLimits = .init()) {
        self.service = service
        self.limits = limits
    }

    func applyIfNeeded() async {
        guard state == .idle || retryRequested else { return }
        retryRequested = false
        await apply()
    }

    func prepareRetry() {
        guard !isLoadingPages, !isSubmittingSMSCode else { return }
        if case .failed = state { retryRequested = true; state = .idle }
        else if deliveryWarning != nil { retryRequested = true }
    }

    func apply() async {
        guard !Task.isCancelled, state != .loading, !isLoadingPages, !isSubmittingSMSCode, smsChallenge == nil else { return }
        isLoadingPages = true
        defer { isLoadingPages = false }
        smsVerificationError = nil
        allowsDiagnostics = true
        if images.isEmpty { state = .loading }
        do { try await loadImages(from: fetchPages()) }
        catch ScoreServiceError.secondFactorRequired(let challenge) {
            guard !Task.isCancelled else { finishCancellation(); return }
            smsChallenge = challenge
            state = images.isEmpty ? .idle : .loaded
        } catch ScoreServiceError.challengeInvalid(let message) {
            guard !Task.isCancelled else { finishCancellation(); return }
            authenticatedChallenge = nil; report = nil; smsChallenge = nil
            allowsDiagnostics = false
            presentDeliveryFailure(ScoreServiceError.challengeInvalid(message))
        } catch {
            if TaskCancellation.matches(error) || Task.isCancelled { finishCancellation() }
            else { presentDeliveryFailure(error) }
        }
    }

    private func fetchPages() async throws -> TrustedTranscriptPages {
        if report?.isInvalid == true { report = nil }
        if let report {
            let remaining = limits.maximumEncodedBytes - encodedBytesByPage.values.reduce(0, +)
            let result = try await report.loadPages(excluding: Set(pageNumbers), maximumBytes: max(0, remaining))
            if result.pages.isEmpty, let error = result.failure,
               case let HTTPClientError.unacceptableStatus(code, _) = error, [401, 403, 404].contains(code) {
                self.report = nil
            } else { return result }
        }
        if let challenge = authenticatedChallenge, !challenge.isExpired {
            return try await service.fetchTrustedTranscriptPages(authenticatedBy: challenge)
        }
        authenticatedChallenge = nil
        return try await service.fetchTrustedTranscriptPages()
    }

    func submitSMSCode(_ code: String) async {
        guard !Task.isCancelled, let challenge = smsChallenge, !isSubmittingSMSCode else { return }
        let normalized = code.filter(\.isNumber)
        guard (4...8).contains(normalized.count) else { smsVerificationError = "请输入短信中的 4 至 8 位验证码。"; return }
        isSubmittingSMSCode = true
        smsVerificationError = nil
        defer { isSubmittingSMSCode = false; isLoadingPages = false }
        do {
            authenticatedChallenge = try await service.submitTranscriptSMSCode(normalized, for: challenge)
            smsChallenge = nil
            report = nil
            isLoadingPages = true
            if images.isEmpty { state = .loading }
            try await loadImages(from: fetchPages())
        } catch ScoreServiceError.challengeInvalid(let message) {
            guard !Task.isCancelled else { finishCancellation(); return }
            smsChallenge = nil; authenticatedChallenge = nil; report = nil
            allowsDiagnostics = false
            presentDeliveryFailure(ScoreServiceError.challengeInvalid(message))
        } catch ScoreServiceError.secondFactorRequired(let challenge) {
            guard !Task.isCancelled else { finishCancellation(); return }
            smsChallenge = challenge
            state = images.isEmpty ? .idle : .loaded
            smsVerificationError = "请输入最新收到的短信验证码。"
        } catch {
            if TaskCancellation.matches(error) || Task.isCancelled { finishCancellation() }
            else if smsChallenge != nil { smsVerificationError = error.localizedDescription }
            else { presentDeliveryFailure(error) }
        }
    }

    func dismissSMSChallenge() {
        guard smsChallenge != nil, !isSubmittingSMSCode else { return }
        smsChallenge = nil
        smsVerificationError = nil
        allowsDiagnostics = false
        if images.isEmpty { state = .failed("已取消短信验证，未申请可信成绩单。") }
        else { state = .loaded; deliveryWarning = "本次验证已取消，已加载的成绩单继续保留。" }
    }

    private func finishCancellation() { state = images.isEmpty ? .idle : .loaded }
    private func presentDeliveryFailure(_ error: any Error) {
        if images.isEmpty { state = .failed(error.localizedDescription) }
        else { deliveryWarning = error.localizedDescription; state = .loaded }
    }

    private func loadImages(from result: TrustedTranscriptPages) async throws {
        if result.pages.isEmpty {
            if let failure = result.failure { presentDeliveryFailure(failure); return }
            guard images.count == result.expectedPageCount else { throw ScoreServiceError.invalidResponse }
            deliveryWarning = nil; state = .loaded; return
        }
        let prepared = try await Self.prepareImages(result, limits: limits)
        try Task.checkCancellation()
        let sameReport = report != nil && report === result.report
        if !sameReport, prepared.failure != nil, !images.isEmpty, prepared.images.count <= images.count {
            deliveryWarning = prepared.failure?.localizedDescription
            state = .loaded
            return
        }
        var retained = sameReport ? Dictionary(uniqueKeysWithValues: zip(pageNumbers, images)) : [:]
        if !sameReport { encodedBytesByPage = [:] }
        for (number, image) in zip(prepared.numbers, prepared.images) { retained[number] = image }
        encodedBytesByPage.merge(prepared.bytes) { _, new in new }
        pageNumbers = retained.keys.sorted()
        images = pageNumbers.compactMap { retained[$0] }
        expectedPageCount = result.expectedPageCount
        report = result.report
        deliveryWarning = images.count == expectedPageCount ? nil
            : "已加载 \(images.count) / \(expectedPageCount) 页。\n" + (prepared.failure?.localizedDescription ?? "部分页面待恢复。")
        state = .loaded
    }

    @concurrent
    private nonisolated static func prepareImages(_ result: TrustedTranscriptPages, limits: TrustedTranscriptResourceLimits) async throws
        -> (images: [UIImage], numbers: [Int], bytes: [Int: Int], failure: (any Error)?) {
        guard result.expectedPageCount > 0, result.expectedPageCount <= limits.maximumPageCount,
              !result.pages.isEmpty, result.pages.count <= result.expectedPageCount else { throw ScoreServiceError.invalidResponse }
        var remainingBytes = limits.maximumEncodedBytes
        for page in result.pages {
            guard page.data.count <= remainingBytes else { throw HTTPClientError.responseTooLarge }
            remainingBytes -= page.data.count
        }
        let perPageBudget = limits.maximumDecodedBytes / result.expectedPageCount
        var images: [UIImage] = [], numbers: [Int] = [], sizes: [Int: Int] = [:]
        var failure = result.failure
        for page in result.pages {
            try Task.checkCancellation()
            if let image = BoundedStillImageDecoder.image(from: page.data, maximumDecodedBytes: perPageBudget) {
                images.append(image); numbers.append(page.number); sizes[page.number] = page.data.count
            } else if failure == nil { failure = ScoreServiceError.queryFailed("部分成绩单图片读取失败，请重试。") }
        }
        guard !images.isEmpty else { throw failure ?? ScoreServiceError.invalidResponse }
        return (images, numbers, sizes, failure)
    }
}
#endif
