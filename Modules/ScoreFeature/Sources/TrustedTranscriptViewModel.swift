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
    private var stagedImages: [Int: UIImage] = [:]
    private var stagedBytes: [Int: Int] = [:]
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

    func prepareReapplication() {
        guard !isLoadingPages, !isSubmittingSMSCode else { return }
        report = nil
        retryRequested = true
        if case .failed = state { state = .idle }
    }

    func apply() async {
        guard !Task.isCancelled, state != .loading, !isLoadingPages, !isSubmittingSMSCode, smsChallenge == nil else { return }
        isLoadingPages = true
        defer { isLoadingPages = false; stagedImages = [:]; stagedBytes = [:] }
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
        stagedImages = [:]; stagedBytes = [:]
        let onPage: TrustedTranscriptPageDelivery = { [self] result in
            try await loadImages(from: result, isPartial: true)
        }
        if report?.isInvalid == true { report = nil }
        if let report {
            let remaining = limits.maximumEncodedBytes - encodedBytesByPage.values.reduce(0, +)
            let result = try await report.loadPages(excluding: Set(pageNumbers), maximumBytes: max(0, remaining), onPage: onPage)
            if result.pages.isEmpty, let error = result.failure,
               case let HTTPClientError.unacceptableStatus(code, _) = error, [401, 403, 404].contains(code) {
                self.report = nil
            } else { return result }
        }
        if let challenge = authenticatedChallenge, !challenge.isExpired {
            return try await service.fetchTrustedTranscriptPages(authenticatedBy: challenge, onPage: onPage)
        }
        authenticatedChallenge = nil
        return try await service.fetchTrustedTranscriptPages(onPage: onPage)
    }

    func submitSMSCode(_ code: String) async {
        guard !Task.isCancelled, let challenge = smsChallenge, !isSubmittingSMSCode else { return }
        let normalized = code.filter(\.isNumber)
        guard (4...8).contains(normalized.count) else { smsVerificationError = "请输入短信中的 4 至 8 位验证码。"; return }
        isSubmittingSMSCode = true
        smsVerificationError = nil
        defer { isSubmittingSMSCode = false; isLoadingPages = false; stagedImages = [:]; stagedBytes = [:] }
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

    private func finishCancellation() {
        state = images.isEmpty ? .idle : .loaded
        if !images.isEmpty, images.count < expectedPageCount {
            deliveryWarning = "已加载 \(images.count) / \(expectedPageCount) 页，可继续补全。"
        }
    }
    private func presentDeliveryFailure(_ error: any Error) {
        if images.isEmpty { state = .failed(error.localizedDescription) }
        else { deliveryWarning = error.localizedDescription; state = .loaded }
    }

    private func loadImages(from result: TrustedTranscriptPages, isPartial: Bool = false) async throws {
        guard result.expectedPageCount > 0, result.expectedPageCount <= limits.maximumPageCount,
              result.pages.count <= result.expectedPageCount,
              Set(result.pages.map(\.number)).count == result.pages.count,
              result.pages.allSatisfy({ (1...result.expectedPageCount).contains($0.number) }) else {
            throw ScoreServiceError.invalidResponse
        }
        let sameReport = report != nil && report === result.report
        var retained = sameReport ? Dictionary(uniqueKeysWithValues: zip(pageNumbers, images)) : stagedImages
        var sizes = sameReport ? encodedBytesByPage : stagedBytes
        var failure = result.failure
        let pending = result.pages.filter { retained[$0.number] == nil }
        if !pending.isEmpty {
            do {
                let remaining = max(0, limits.maximumEncodedBytes - sizes.values.reduce(0, +))
                let prepared = try await Self.prepareImages(.init(pages: pending, expectedPageCount: result.expectedPageCount),
                    limits: .init(maximumPageCount: limits.maximumPageCount, maximumEncodedBytes: remaining,
                                  maximumDecodedBytes: limits.maximumDecodedBytes))
                try Task.checkCancellation()
                for (number, image) in zip(prepared.numbers, prepared.images) { retained[number] = image }
                sizes.merge(prepared.bytes) { _, new in new }
                failure = failure ?? prepared.failure
            } catch {
                if TaskCancellation.matches(error) || retained.isEmpty { throw error }
                failure = failure ?? error
            }
        }
        try Task.checkCancellation()
        if !sameReport { stagedImages = retained; stagedBytes = sizes }
        if retained.isEmpty {
            if let failure { throw failure }
            throw ScoreServiceError.invalidResponse
        }
        if !sameReport, !images.isEmpty, retained.count <= images.count, retained.count < result.expectedPageCount {
            if !isPartial { deliveryWarning = failure?.localizedDescription ?? "部分页面待恢复。" }
            state = .loaded
            return
        }
        encodedBytesByPage = sizes
        pageNumbers = retained.keys.sorted()
        images = pageNumbers.compactMap { retained[$0] }
        expectedPageCount = result.expectedPageCount
        report = result.report
        deliveryWarning = isPartial || images.count == expectedPageCount ? nil
            : "已加载 \(images.count) / \(expectedPageCount) 页。\n" + (failure?.localizedDescription ?? "部分页面待恢复。")
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
