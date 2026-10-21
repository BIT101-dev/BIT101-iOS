import ScoreDomain
import ScorePorts
import MediaKit
#if os(iOS)
import TransportCore
import ClientCore
import Combine
import Foundation
import UIKit

/// 可信成绩单申请使用独立于普通成绩查询的状态机。
///
/// 学校返回的图片地址属于短期地址，成绩单图片保存范围为当前申请页面的内存状态。
/// 成绩缓存独立于成绩单图片的页面内存状态。
@MainActor
final class TrustedTranscriptViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var images: [UIImage] = []
    @Published private(set) var pageNumbers: [Int] = []
    @Published private(set) var expectedPageCount = 0
    @Published private(set) var deliveryWarning: String?
    @Published private(set) var smsChallenge: BITLoginAuthenticationChallenge?
    @Published private(set) var smsVerificationError: String?
    @Published private(set) var isSubmittingSMSCode = false
    @Published private(set) var allowsDiagnostics = true

    private let service: any TrustedTranscriptServicing
    private let limits: TrustedTranscriptResourceLimits
    private var authenticatedChallenge: BITLoginAuthenticationChallenge?

    init(service: any TrustedTranscriptServicing, limits: TrustedTranscriptResourceLimits = .init()) {
        self.service = service
        self.limits = limits
    }


    /// 页面首次出现时申请；返回已加载的页面时保留成绩单。
    func applyIfNeeded() async {
        guard state == .idle else { return }
        await apply()
    }

    func prepareRetry() {
        if case .failed = state { state = .idle }
        else if deliveryWarning != nil { state = .idle }
    }

    /// 发起一次新的学校可信成绩单申请。
    func apply() async {
        guard !Task.isCancelled else { return }
        guard state != .loading, !isSubmittingSMSCode, smsChallenge == nil else { return }
        smsVerificationError = nil
        allowsDiagnostics = true
        state = .loading

        do {
            let pages: TrustedTranscriptPages
            if let challenge = authenticatedChallenge, !challenge.isExpired {
                pages = try await service.fetchTrustedTranscriptPages(authenticatedBy: challenge)
            } else {
                authenticatedChallenge = nil
                pages = try await service.fetchTrustedTranscriptPages()
            }
            try await loadImages(from: pages)
        } catch ScoreServiceError.secondFactorRequired(let challenge) {
            guard !Task.isCancelled else { state = .idle; return }
            smsChallenge = challenge
            state = .idle
        } catch ScoreServiceError.challengeInvalid(let message) {
            guard !Task.isCancelled else { state = .idle; return }
            smsChallenge = nil
            authenticatedChallenge = nil
            allowsDiagnostics = false
            state = .failed(message)
        } catch {
            if Task.isCancelled || TaskCancellation.matches(error) {
                state = images.isEmpty ? .idle : .loaded
                return
            }
            presentDeliveryFailure(error)
        }
    }

    /// 提交 `jwb_cjd` 独立 challenge 的验证码，并继续下载成绩单图片。
    func submitSMSCode(_ code: String) async {
        guard !Task.isCancelled else { return }
        guard let challenge = smsChallenge, !isSubmittingSMSCode else { return }
        let normalizedCode = code.filter(\.isNumber)
        guard (4 ... 8).contains(normalizedCode.count) else {
            smsVerificationError = "请输入短信中的 4 至 8 位验证码。"
            return
        }

        isSubmittingSMSCode = true
        smsVerificationError = nil
        defer { isSubmittingSMSCode = false }

        do {
            authenticatedChallenge = try await service.submitTranscriptSMSCode(normalizedCode, for: challenge)
            smsChallenge = nil
            state = .loading
            guard let authenticatedChallenge else { return }
            let pages = try await service.fetchTrustedTranscriptPages(authenticatedBy: authenticatedChallenge)
            try await loadImages(from: pages)
        } catch ScoreServiceError.challengeInvalid(let message) {
            guard !Task.isCancelled else { state = .idle; return }
            smsChallenge = nil
            authenticatedChallenge = nil
            allowsDiagnostics = false
            state = .failed(message)
        } catch ScoreServiceError.secondFactorRequired(let challenge) {
            guard !Task.isCancelled else { state = .idle; return }
            smsChallenge = challenge
            state = .idle
            smsVerificationError = "请输入最新收到的短信验证码。"
        } catch {
            if Task.isCancelled || TaskCancellation.matches(error) {
                state = .idle
                return
            }
            if smsChallenge != nil {
                // 普通错误（尤其是错误验证码）继续显示在输入面板，用户可以修改验证码后重试。
                smsVerificationError = error.localizedDescription
            } else {
                presentDeliveryFailure(error)
            }
        }
    }

    private func presentDeliveryFailure(_ error: any Error) {
        if images.isEmpty { state = .failed(error.localizedDescription) }
        else { deliveryWarning = error.localizedDescription; state = .loaded }
    }

    /// 关闭短信验证面板并将申请状态更新为失败。
    func dismissSMSChallenge() {
        guard smsChallenge != nil, !isSubmittingSMSCode else { return }
        smsChallenge = nil
        smsVerificationError = nil
        allowsDiagnostics = false
        state = .failed("已取消短信验证，未申请可信成绩单。")
    }

    private func loadImages(from result: TrustedTranscriptPages) async throws {
        let prepared = try await Self.prepareImages(result, limits: limits)
        try Task.checkCancellation()
        images = prepared.images
        pageNumbers = prepared.numbers
        expectedPageCount = result.expectedPageCount
        deliveryWarning = prepared.failure.map { "已加载 \(images.count) / \(expectedPageCount) 页。\n" + $0.localizedDescription }
        state = .loaded
    }

    @concurrent
    private nonisolated static func prepareImages(_ result: TrustedTranscriptPages, limits: TrustedTranscriptResourceLimits) async throws
        -> (images: [UIImage], numbers: [Int], failure: (any Error)?) {
        guard result.expectedPageCount > 0, result.expectedPageCount <= limits.maximumPageCount,
              !result.pages.isEmpty, result.pages.count <= result.expectedPageCount else { throw ScoreServiceError.invalidResponse }
        var remainingBytes = limits.maximumEncodedBytes
        for page in result.pages {
            guard page.data.count <= remainingBytes else { throw HTTPClientError.responseTooLarge }
            remainingBytes -= page.data.count
        }
        let perPageBudget = limits.maximumDecodedBytes / result.expectedPageCount
        var images: [UIImage] = [], numbers: [Int] = []
        var failure = result.failure
        for page in result.pages {
            try Task.checkCancellation()
            if let image = BoundedStillImageDecoder.image(from: page.data, maximumDecodedBytes: perPageBudget) {
                images.append(image); numbers.append(page.number)
            } else if failure == nil {
                failure = ScoreServiceError.queryFailed("部分成绩单图片读取失败，请重试。")
            }
        }
        guard !images.isEmpty else { throw failure ?? ScoreServiceError.invalidResponse }
        return (images, numbers, failure)
    }
}

#endif
