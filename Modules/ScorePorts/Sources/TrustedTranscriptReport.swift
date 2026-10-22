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
    private let timeout: Duration

    public init(pageCount: Int, timeout: Duration = TrustedTranscriptResourceLimits().maximumWait,
                readPage: @escaping @MainActor (Int, Int) async throws -> Data) {
        self.pageCount = pageCount
        self.timeout = timeout
        self.readPage = readPage
    }

    public func loadPages(excluding completed: Set<Int> = [], maximumBytes: Int,
                          onPage: TrustedTranscriptPageDelivery? = nil) async throws -> TrustedTranscriptPages {
        guard !isInvalid, pageCount > 0, maximumBytes >= 0 else { throw ScoreServiceError.invalidResponse }
        var pages: [TrustedTranscriptPages.Page] = []
        var remaining = maximumBytes
        var failure: (any Error)?
        let deadline = ContinuousClock.now.advanced(by: timeout)
        for number in 1...pageCount where !completed.contains(number) {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { failure = URLError(.timedOut); break }
            guard remaining > 0 else {
                failure = failure ?? ScoreServiceError.queryFailed("成绩单图片已达到读取容量，请保留已加载页面。")
                break
            }
            do {
                let data = try await readPage(number, maximumBytes: remaining, deadline: deadline)
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

    private func readPage(_ number: Int, maximumBytes: Int, deadline: ContinuousClock.Instant) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await self.readPage(number, maximumBytes) }
            group.addTask {
                try await ContinuousClock().sleep(until: deadline)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let data = try await group.next() else { throw CancellationError() }
            return data
        }
    }
}
