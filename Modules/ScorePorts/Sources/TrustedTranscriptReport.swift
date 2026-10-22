import Foundation
import TransportCore

/// 一次学校报告的分页来源，存续范围与申请页面一致。
@MainActor
public final class TrustedTranscriptReport {
    public enum Failure: Error { case invalidSource(any Error) }
    public let id = UUID()
    public let pageCount: Int
    public private(set) var isInvalid = false
    private let readPage: @MainActor (Int, Int) async throws -> Data

    public init(pageCount: Int, readPage: @escaping @MainActor (Int, Int) async throws -> Data) {
        self.pageCount = pageCount
        self.readPage = readPage
    }

    public func loadPages(excluding completed: Set<Int> = [], maximumBytes: Int,
                          onPage: TrustedTranscriptPageDelivery? = nil) async throws -> TrustedTranscriptPages {
        guard !isInvalid, pageCount > 0, maximumBytes >= 0 else { throw ScoreServiceError.invalidResponse }
        var pages: [TrustedTranscriptPages.Page] = []
        var remaining = maximumBytes
        var failure: (any Error)?
        for number in 1...pageCount where !completed.contains(number) {
            try Task.checkCancellation()
            guard remaining > 0 else {
                failure = failure ?? ScoreServiceError.queryFailed("成绩单图片已达到读取容量，请保留已加载页面。")
                break
            }
            do {
                let data = try await readPage(number, remaining)
                guard !data.isEmpty, data.count <= remaining else { throw ScoreServiceError.invalidResponse }
                let page = TrustedTranscriptPages.Page(number: number, data: data)
                pages.append(page)
                remaining -= data.count
                try await onPage?(.init(pages: [page], expectedPageCount: pageCount, report: self))
            } catch Failure.invalidSource(let error) {
                isInvalid = true
                failure = error
                break
            }
            catch {
                if Task.isCancelled || TaskCancellation.matches(error) { throw CancellationError() }
                if failure == nil { failure = error }
            }
        }
        if pages.isEmpty, completed.isEmpty, let failure { throw failure }
        return .init(pages: pages, expectedPageCount: pageCount, failure: failure, report: self)
    }
}
