/// Coordinates request generations and timeouts for explicit free-classroom requests.
/// `ScheduleClassroomViewModel` owns UI state, and this type owns request lifecycle rules.
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
    private let waitForDeadline: @Sendable (UInt64) async throws -> Void

    init(timeoutNanoseconds: UInt64 = 15 * 1_000_000_000,
         waitForDeadline: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.timeoutNanoseconds = timeoutNanoseconds
        self.waitForDeadline = waitForDeadline
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
        operation: @escaping @MainActor @Sendable () async throws -> T
    ) async throws -> T where T: Sendable {
        try Task.checkCancellation()

        // The task-group scope waits for its losing child to finish after cancellation.
        // Keep operations cancellation-cooperative through cancellable awaits or polling.
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask { [timeoutNanoseconds, waitForDeadline] in
                try await waitForDeadline(timeoutNanoseconds)
                throw ClassroomRequestTimeoutError()
            }

            guard let value = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            try Task.checkCancellation()
            return value
        }
    }

    func withAuthenticationThenTimeout<T>(
        authentication: @escaping @MainActor @Sendable () async throws -> Void,
        operation: @escaping @MainActor @Sendable () async throws -> T
    ) async throws -> T where T: Sendable {
        try Task.checkCancellation()
        try await authentication()
        try Task.checkCancellation()
        return try await withTimeout(operation: operation)
    }
}
