import Foundation

/// Coordinates request generations and timeouts for explicit free-classroom requests.
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
    private let timeoutNanoseconds: UInt64

    init(timeoutNanoseconds: UInt64 = 15 * 1_000_000_000) {
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    func reset() {
        generation &+= 1
        isRequestInFlight = false
        didFinishInitialRequest = false
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

            guard let value = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return value
        }
    }
}
