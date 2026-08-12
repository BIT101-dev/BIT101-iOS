import Foundation

/// Coordinates request generations and one-time work for the free-classroom page.
/// UI state remains in `ScheduleViewModel`; this type only owns lifecycle rules.
@MainActor
final class ScheduleClassroomCoordinator {
    struct RequestStart: Equatable {
        let id: Int
        let shouldShowInitialSpinner: Bool
    }

    private var generation = 0
    private(set) var isRequestInFlight = false
    private var didFinishInitialRequest = false
    private var didAutoPrepare = false
    private var isRefreshingMetadata = false
    private var metadataGeneration = 0
    private let timeoutNanoseconds: UInt64

    init(timeoutNanoseconds: UInt64 = 15 * 1_000_000_000) {
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    func reset() {
        generation &+= 1
        isRequestInFlight = false
        didFinishInitialRequest = false
        didAutoPrepare = false
        isRefreshingMetadata = false
        metadataGeneration &+= 1
    }

    func claimAutomaticPreparation() -> Bool {
        guard !didAutoPrepare, !isRequestInFlight else { return false }
        didAutoPrepare = true
        return true
    }

    func beginRequest(hasVisibleResults: Bool) -> RequestStart {
        generation &+= 1
        isRequestInFlight = true
        return RequestStart(
            id: generation,
            shouldShowInitialSpinner: !didFinishInitialRequest && !hasVisibleResults
        )
    }

    func isCurrent(_ requestID: Int) -> Bool {
        requestID == generation
    }

    @discardableResult
    func finish(_ requestID: Int) -> Bool {
        guard isCurrent(requestID) else { return false }
        didFinishInitialRequest = true
        isRequestInFlight = false
        return true
    }

    func beginMetadataRefresh() -> Int? {
        guard !isRefreshingMetadata else { return nil }
        metadataGeneration &+= 1
        isRefreshingMetadata = true
        return metadataGeneration
    }

    func isCurrentMetadataRefresh(_ token: Int) -> Bool {
        token == metadataGeneration
    }

    func finishMetadataRefresh(_ token: Int) {
        guard isCurrentMetadataRefresh(token) else { return }
        isRefreshingMetadata = false
    }

    func withTimeout<T>(
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T where T: Sendable {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask { [timeoutNanoseconds] in
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw ClassroomRequestTimeoutError()
            }

            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }
}
