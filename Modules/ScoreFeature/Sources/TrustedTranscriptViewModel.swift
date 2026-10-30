import ScoreDomain
import ScorePorts
import DesignSystemKit
import MediaKit
#if os(iOS)
import TransportCore
import ClientCore
import Combine
import Foundation
import UIKit

/// 成绩单页面持有报告来源与可用分页，认证和图片恢复各自推进。
@MainActor
final class TrustedTranscriptViewModel: ObservableObject {
    enum State: Equatable { case idle, loading, loaded, failed(String) }
    @Published private(set) var state: State = .idle
    @Published private(set) var images: [UIImage] = []
    @Published private(set) var pageNumbers: [Int] = []
    @Published private(set) var expectedPageCount = 0
    @Published private(set) var deliveryWarning: String?
    @Published private(set) var verificationChallenge: BITLoginAuthenticationChallenge?
    @Published private(set) var verificationError: String?
    @Published private(set) var isSubmittingVerificationCode = false
    @Published private(set) var isLoadingPages = false
    @Published private(set) var allowsDiagnostics = true
    @Published private(set) var failureCause: (any Error)?

    private let service: any TrustedTranscriptServicing
    private let limits: TrustedTranscriptResourceLimits
    private var authenticatedChallenge: BITLoginAuthenticationChallenge?
    private var report: TrustedTranscriptReport?
    private var encodedBytesByPage: [Int: Int] = [:]
    private var stagedImages: [Int: UIImage] = [:]
    private var stagedBytes: [Int: Int] = [:]
    private var stagedReport: TrustedTranscriptReport?
    private var retryRequested = false
    private var verificationContinuation: Task<Void, Never>?

    init(service: any TrustedTranscriptServicing, limits: TrustedTranscriptResourceLimits = .init()) {
        self.service = service
        self.limits = limits
    }

    deinit { verificationContinuation?.cancel() }

    func cancelVerificationContinuation() { verificationContinuation?.cancel() }

    var decodedImageBytes: Int {
        BoundedStillImageDecoder.decodedBytes(in: images + Array(stagedImages.values))
    }

    func applyIfNeeded() async {
        guard state == .idle || retryRequested else { return }
        retryRequested = false
        await apply()
    }

    func prepareRetry() {
        guard !isLoadingPages, !isSubmittingVerificationCode else { return }
        if case .failed = state { retryRequested = true; state = .idle }
        else if deliveryWarning != nil { retryRequested = true }
    }

    func prepareReapplication() {
        guard !isLoadingPages, !isSubmittingVerificationCode else { return }
        report = nil
        stagedReport = nil; stagedImages = [:]; stagedBytes = [:]
        retryRequested = true
        if case .failed = state { state = .idle }
    }

    func apply() async {
        guard !Task.isCancelled, state != .loading, !isLoadingPages, !isSubmittingVerificationCode, verificationChallenge == nil else { return }
        isLoadingPages = true
        defer {
            isLoadingPages = false
            if stagedReport == nil { stagedImages = [:]; stagedBytes = [:] }
        }
        verificationError = nil
        allowsDiagnostics = true
        failureCause = nil
        if images.isEmpty { state = .loading }
        do { try await loadImages(from: fetchPages()) }
        catch ScoreServiceError.secondFactorRequired(let challenge) {
            guard !Task.isCancelled else { finishCancellation(); return }
            verificationChallenge = challenge
            state = images.isEmpty ? .idle : .loaded
        } catch ScoreServiceError.challengeInvalid(let message) {
            guard !Task.isCancelled else { finishCancellation(); return }
            authenticatedChallenge = nil; report = nil; verificationChallenge = nil
            allowsDiagnostics = false
            presentDeliveryFailure(ScoreServiceError.challengeInvalid(message))
        } catch {
            if TaskCancellation.matches(error) || Task.isCancelled { finishCancellation() }
            else { presentDeliveryFailure(error) }
        }
    }

    private func fetchPages() async throws -> TrustedTranscriptPages {
        let onPage: TrustedTranscriptPageDelivery = { [self] result in
            try await loadImages(from: result, isPartial: true)
        }
        if report?.isInvalid == true { report = nil }
        if stagedReport?.isInvalid == true { stagedReport = nil; stagedImages = [:]; stagedBytes = [:] }
        if let source = stagedReport ?? report {
            let completed = stagedReport == nil ? Set(pageNumbers) : Set(stagedImages.keys)
            let sizes = stagedReport == nil ? encodedBytesByPage : stagedBytes
            let remaining = limits.maximumEncodedBytes - sizes.values.reduce(0, +)
            let result = try await source.loadPages(excluding: completed, maximumBytes: max(0, remaining), onPage: onPage)
            if result.pages.isEmpty, let error = result.failure,
               case let HTTPClientError.unacceptableStatus(code, _) = error, [401, 403, 404].contains(code) {
                self.report = nil
                stagedReport = nil; stagedImages = [:]; stagedBytes = [:]
            } else { return result }
        }
        stagedImages = [:]; stagedBytes = [:]
        if let challenge = authenticatedChallenge, !challenge.isExpired {
            return try await service.fetchTrustedTranscriptPages(authenticatedBy: challenge, onPage: onPage)
        }
        authenticatedChallenge = nil
        return try await service.fetchTrustedTranscriptPages(onPage: onPage)
    }

    func submitVerificationCode(_ code: String) async {
        guard !Task.isCancelled, let challenge = verificationChallenge, !isSubmittingVerificationCode else { return }
        let normalized = AppVerificationCode.normalize(code, isCaptcha: challenge.isCaptcha)
        guard AppVerificationCode.isValid(normalized, isCaptcha: challenge.isCaptcha) else { verificationError = AppVerificationCode.validationMessage(isCaptcha: challenge.isCaptcha); return }
        isSubmittingVerificationCode = true
        verificationError = nil
        let task = Task { [weak self] in
            guard let self else { return }
            await self.continueAfterVerificationCode(normalized, challenge: challenge)
        }
        verificationContinuation = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    private func continueAfterVerificationCode(_ normalized: String, challenge: BITLoginAuthenticationChallenge) async {
        defer {
            isSubmittingVerificationCode = false; isLoadingPages = false
            if stagedReport == nil { stagedImages = [:]; stagedBytes = [:] }
            verificationContinuation = nil
        }
        do {
            authenticatedChallenge = try await service.submitTranscriptVerificationCode(normalized, for: challenge)
            verificationChallenge = nil
            report = nil
            try Task.checkCancellation()
            isLoadingPages = true
            if images.isEmpty { state = .loading }
            try await loadImages(from: fetchPages())
        } catch ScoreServiceError.challengeInvalid(let message) {
            guard !Task.isCancelled else { finishCancellation(); return }
            verificationChallenge = nil; authenticatedChallenge = nil; report = nil
            allowsDiagnostics = false
            presentDeliveryFailure(ScoreServiceError.challengeInvalid(message))
        } catch ScoreServiceError.secondFactorRequired(let challenge) {
            guard !Task.isCancelled else { finishCancellation(); return }
            verificationChallenge = challenge
            state = images.isEmpty ? .idle : .loaded
            verificationError = nil
        } catch {
            if TaskCancellation.matches(error) || Task.isCancelled { finishCancellation() }
            else if verificationChallenge != nil, SchoolServiceFailure.from(error) == nil { verificationError = error.localizedDescription }
            else {
                verificationChallenge = nil
                presentDeliveryFailure(error)
            }
        }
    }

    func dismissVerificationChallenge() {
        guard verificationChallenge != nil, !isSubmittingVerificationCode else { return }
        verificationChallenge = nil
        verificationError = nil
        allowsDiagnostics = false
        failureCause = nil
        if images.isEmpty { state = .failed("已取消学校验证，未申请可信成绩单。") }
        else { state = .loaded; deliveryWarning = "本次验证已取消，已加载的成绩单继续保留。" }
    }

    private func finishCancellation() {
        state = images.isEmpty ? .idle : .loaded
        if let stagedReport, !stagedImages.isEmpty {
            deliveryWarning = "新成绩单已加载 \(stagedImages.count) / \(stagedReport.pageCount) 页，可继续补全。当前成绩单继续保留。"
            return
        }
        if !images.isEmpty, images.count < expectedPageCount {
            deliveryWarning = "已加载 \(images.count) / \(expectedPageCount) 页，可继续补全。"
        }
    }
    private func presentDeliveryFailure(_ error: any Error) {
        failureCause = error
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
        var remainingEncoded = max(0, limits.maximumEncodedBytes - sizes.values.reduce(0, +))
        for page in pending {
            guard page.data.count <= remainingEncoded else { throw HTTPClientError.responseTooLarge }
            remainingEncoded -= page.data.count
        }
        for page in pending {
            do {
                try Task.checkCancellation()
                guard BoundedStillImageDecoder.hasCompleteImage(in: page.data) else { throw ScoreServiceError.invalidResponse }
                let remaining = max(0, limits.maximumEncodedBytes - sizes.values.reduce(0, +))
                let prepared = try await Self.prepareImages(.init(pages: [page], expectedPageCount: result.expectedPageCount),
                    limits: .init(maximumPageCount: limits.maximumPageCount, maximumEncodedBytes: remaining,
                                  maximumDecodedBytes: limits.maximumDecodedBytes))
                try Task.checkCancellation()
                for (number, image) in zip(prepared.numbers, prepared.images) { retained[number] = image }
                sizes.merge(prepared.bytes) { _, new in new }
                failure = failure ?? prepared.failure
            } catch {
                if TaskCancellation.matches(error) { throw error }
                failure = failure ?? error
            }
        }
        try Task.checkCancellation()
        if !sameReport { stagedImages = retained; stagedBytes = sizes; stagedReport = result.report }
        if retained.isEmpty {
            if let failure { throw failure }
            throw ScoreServiceError.invalidResponse
        }
        if !sameReport, !images.isEmpty, retained.count <= images.count, retained.count < result.expectedPageCount {
            if !isPartial { deliveryWarning = failure?.localizedDescription ?? "部分页面待恢复。" }
            state = .loaded
            return
        }
        publishImages(retained, sizes: sizes, result: result, isPartial: isPartial, failure: failure)
    }

    private func publishImages(_ retained: [Int: UIImage], sizes: [Int: Int], result: TrustedTranscriptPages,
                               isPartial: Bool, failure: (any Error)? = nil) {
        encodedBytesByPage = sizes
        pageNumbers = retained.keys.sorted()
        images = pageNumbers.compactMap { retained[$0] }
        expectedPageCount = result.expectedPageCount
        report = result.report
        stagedReport = nil; stagedImages = [:]; stagedBytes = [:]
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
        let perPageBudget = limits.maximumDecodedBytes / 2 / result.expectedPageCount
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
