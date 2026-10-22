@testable import ScoreFeature
import ScorePorts
import ClientCore
import MediaKit
import Foundation
import Testing
import UIKit

@MainActor
struct TrustedTranscriptRecoveryTests {
    private final class SMSService: TrustedTranscriptServicing {
        let challenge = BITLoginAuthenticationChallenge(challengeID: "transcript", accessToken: "fixture",
            status: "requires_sms", maskedPhone: nil, expiresIn: 60)
        var downloading = false, cancelled = false
        func fetchTrustedTranscriptPages(onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages {
            throw ScoreServiceError.secondFactorRequired(challenge)
        }
        func fetchTrustedTranscriptPages(authenticatedBy challenge: BITLoginAuthenticationChallenge, onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages {
            downloading = true
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancelled = Task.isCancelled; throw error }
            throw URLError(.timedOut)
        }
        func submitTranscriptSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> BITLoginAuthenticationChallenge { challenge }
    }

    @Test(.timeLimit(.minutes(1)))
    func leavingThePageCancelsTheAuthenticatedDownloadAndKeepsSMSClosed() async throws {
        let service = SMSService(), model = TrustedTranscriptViewModel(service: service)
        await model.applyIfNeeded()
        #expect(model.smsChallenge != nil)
        let submission = Task { await model.submitSMSCode("123456") }
        defer { submission.cancel(); model.cancelSMSContinuation() }
        try await waitForTestEvent { service.downloading }
        #expect(model.smsChallenge == nil && model.isLoadingPages)
        model.cancelSMSContinuation()
        await submission.value
        #expect(service.cancelled && model.smsChallenge == nil)
        #expect(!model.isLoadingPages && !model.isSubmittingSMSCode && model.state == .idle)
    }

    private final class StreamingService: TrustedTranscriptServicing {
        let data: Data
        let damage: String
        var applications = 0
        var reads: [(Int, Int)] = []
        var hold = true
        var holdPage = 2
        var pending: CheckedContinuation<Void, Never>?
        init(data: Data, damage: String) { self.data = data; self.damage = damage }
        func fetchTrustedTranscriptPages(onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages {
            applications += 1
            let application = applications
            let report = TrustedTranscriptReport(pageCount: 3) { [self] number, _ in
                reads.append((application, number))
                if number == holdPage, hold { hold = false; await withCheckedContinuation { pending = $0 } }
                if number == 2 {
                    try Task.checkCancellation()
                    if application == 1 {
                        if damage == "source" { throw TrustedTranscriptReport.Failure.invalidSource(URLError(.badServerResponse)) }
                        return Data("damaged".utf8)
                    }
                }
                return data
            }
            return try await report.loadPages(maximumBytes: data.count * 3, onPage: onPage)
        }
        func fetchTrustedTranscriptPages(authenticatedBy challenge: BITLoginAuthenticationChallenge, onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages {
            try await fetchTrustedTranscriptPages(onPage: onPage)
        }
        func submitTranscriptSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> BITLoginAuthenticationChallenge { challenge }
    }

    @Test(.timeLimit(.minutes(1)))
    func replacementReportsShareOneDecodedImageBudget() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
        let data = UIGraphicsImageRenderer(size: CGSize(width: 1_024, height: 1_024), format: format).pngData { _ in }
        let service = StreamingService(data: data, damage: "decode")
        service.hold = false
        let budget = 3 * 256 * 256 * 4
        let model = TrustedTranscriptViewModel(service: service, limits: .init(maximumDecodedBytes: budget))
        await model.applyIfNeeded()
        #expect(model.pageNumbers == [1, 3])
        service.hold = true; service.holdPage = 3
        model.prepareReapplication()
        let loading = Task { await model.applyIfNeeded() }
        defer { loading.cancel(); service.pending?.resume(); service.pending = nil }
        try await waitForTestEvent { service.pending != nil }
        #expect(model.decodedImageBytes <= budget)
        #expect(model.pageNumbers == [1, 2])
        #expect(model.state == .loaded)
        service.pending?.resume(); service.pending = nil
        await loading.value
        #expect(model.decodedImageBytes <= budget && model.pageNumbers == [1, 2, 3])
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["source", "decode"])
    func pagesAppearBeforeTheBatchFinishesAndFreshReportsRecoverDamage(damage: String) async throws {
        let data = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { _ in }
        let service = StreamingService(data: data, damage: damage)
        let model = TrustedTranscriptViewModel(service: service)
        let loading = Task { await model.applyIfNeeded() }
        defer { loading.cancel(); service.pending?.resume(); service.pending = nil }
        try await waitForTestEvent { service.pending != nil }
        #expect(model.state == .loaded && model.pageNumbers == [1] && model.isLoadingPages && model.deliveryWarning == nil)
        service.pending?.resume(); service.pending = nil
        await loading.value
        #expect(model.pageNumbers == (damage == "source" ? [1] : [1, 3]) && model.deliveryWarning != nil)
        let retained = model.images
        if damage == "decode" {
            model.prepareRetry()
            await model.applyIfNeeded()
            #expect(service.applications == 1 && model.images.elementsEqual(retained, by: { $0 === $1 }))
        }
        service.hold = true
        if damage == "source" { model.prepareRetry() }
        else { model.prepareReapplication() }
        let replacement = Task { await model.applyIfNeeded() }
        defer { replacement.cancel() }
        try await waitForTestEvent { service.pending != nil }
        #expect(service.applications == 2 && model.images.elementsEqual(retained, by: { $0 === $1 }))
        service.pending?.resume(); service.pending = nil
        await replacement.value
        #expect(model.pageNumbers == [1, 2, 3] && model.deliveryWarning == nil && model.state == .loaded)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingTheRemainingPagesKeepsTheFirstPublishedPage() async throws {
        let service = StreamingService(data: UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { _ in }, damage: "decode")
        let model = TrustedTranscriptViewModel(service: service)
        let loading = Task { await model.applyIfNeeded() }
        defer { loading.cancel(); service.pending?.resume(); service.pending = nil }
        try await waitForTestEvent { service.pending != nil }
        loading.cancel()
        service.pending?.resume(); service.pending = nil
        await loading.value
        #expect(model.pageNumbers == [1] && model.state == .loaded && !model.isLoadingPages && model.deliveryWarning != nil)
        #expect(service.reads.map(\.1) == [1, 2])
    }

    private final class Service: TrustedTranscriptServicing {
        let data: Data
        var failures = 2
        var reads: [(Int, Int)] = []
        var applications = 0
        var holdRetry = false
        var pending: CheckedContinuation<Void, Never>?
        lazy var report = TrustedTranscriptReport(pageCount: 3) { [unowned self] number, budget in
            reads.append((number, budget))
            if number == 2 {
                if holdRetry { holdRetry = false; await withCheckedContinuation { pending = $0 } }
                if failures > 0 { failures -= 1; throw URLError(.networkConnectionLost) }
            }
            return data
        }
        init(data: Data) { self.data = data }
        func fetchTrustedTranscriptPages(onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages {
            applications += 1
            return try await report.loadPages(maximumBytes: data.count * 3, onPage: onPage)
        }
        func fetchTrustedTranscriptPages(authenticatedBy challenge: BITLoginAuthenticationChallenge, onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages {
            try await fetchTrustedTranscriptPages(onPage: onPage)
        }
        func submitTranscriptSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> BITLoginAuthenticationChallenge { challenge }
    }

    @Test(.timeLimit(.minutes(1)))
    func retriesKeepVisiblePagesAndLoadTheMissingPageFromTheSameReport() async throws {
        let data = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { _ in }
        let service = Service(data: data)
        let model = TrustedTranscriptViewModel(service: service, limits: .init(maximumEncodedBytes: data.count * 3))
        await model.applyIfNeeded()
        #expect(model.state == .loaded && model.pageNumbers == [1, 3] && model.deliveryWarning != nil)
        let retained = model.images
        service.holdRetry = true
        model.prepareRetry()
        let retry = Task { await model.applyIfNeeded() }
        defer { retry.cancel(); service.pending?.resume(); service.pending = nil }
        try await waitForTestEvent { service.pending != nil }
        #expect(model.state == .loaded && model.images.count == 2 && model.isLoadingPages)
        service.pending?.resume(); service.pending = nil
        await retry.value
        #expect(model.images.elementsEqual(retained, by: { $0 === $1 }) && model.deliveryWarning != nil)
        model.prepareRetry()
        await model.applyIfNeeded()
        #expect(model.pageNumbers == [1, 2, 3] && model.deliveryWarning == nil && model.state == .loaded)
        #expect(service.applications == 1 && service.reads.map(\.0) == [1, 2, 3, 2, 2])
        #expect(service.reads.last?.1 == data.count)
    }

    private final class Reports: TrustedTranscriptServicing {
        let data: Data
        var requests = 0
        init(data: Data) { self.data = data }
        func fetchTrustedTranscriptPages(onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages {
            requests += 1
            let numbers = requests == 1 ? [1, 3] : requests == 2 ? [1] : [1, 2, 3]
            return .init(pages: numbers.map { .init(number: $0, data: data) }, expectedPageCount: 3,
                failure: requests < 3 ? URLError(.networkConnectionLost) : nil)
        }
        func fetchTrustedTranscriptPages(authenticatedBy challenge: BITLoginAuthenticationChallenge, onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages {
            try await fetchTrustedTranscriptPages()
        }
        func submitTranscriptSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> BITLoginAuthenticationChallenge { challenge }
    }

    @Test(.timeLimit(.minutes(1)))
    func aPartialReplacementKeepsTheFullerCoherentReport() async throws {
        let service = Reports(data: UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { _ in })
        let model = TrustedTranscriptViewModel(service: service)
        await model.applyIfNeeded()
        let retained = model.images
        model.prepareRetry()
        await model.applyIfNeeded()
        #expect(model.pageNumbers == [1, 3] && model.images.elementsEqual(retained, by: { $0 === $1 }))
        model.prepareRetry()
        await model.applyIfNeeded()
        #expect(model.pageNumbers == [1, 2, 3] && model.deliveryWarning == nil)
    }
}
