import Foundation
import os

/// 系统按块交付响应，接收期间执行容量与取消约束。
nonisolated final class HTTPBoundedTransfer: NSObject, URLSessionDataDelegate {
    private struct State {
        var data = Data()
        var response: URLResponse?
        var continuation: CheckedContinuation<(Data, URLResponse), any Error>?
        var outcome: Result<(Data, URLResponse), any Error>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let maximumBytes: Int
    private let metrics: HTTPTransmissionMetrics

    init(maximumBytes: Int, metrics: HTTPTransmissionMetrics) {
        self.maximumBytes = maximumBytes
        self.metrics = metrics
    }

    func receive(_ task: URLSessionDataTask) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completed = state.withLock { state -> Result<(Data, URLResponse), any Error>? in
                    if let outcome = state.outcome { return outcome }
                    state.continuation = continuation
                    return nil
                }
                if let completed { continuation.resume(with: completed) }
                else { task.resume() }
            }
        } onCancel: {
            self.complete(.failure(CancellationError()))
            task.cancel()
        }
    }

    private func complete(_ result: Result<(Data, URLResponse), any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<(Data, URLResponse), any Error>? in
            guard state.outcome == nil else { return nil }
            state.outcome = result
            let continuation = state.continuation
            state.continuation = nil
            state.data = Data()
            state.response = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            complete(.failure(HTTPClientError.responseTooLarge))
            completionHandler(.cancel)
            dataTask.cancel()
            return
        }
        let active = state.withLock { state in
            guard state.outcome == nil else { return false }
            state.response = response
            if response.expectedContentLength > 0 { state.data.reserveCapacity(Int(response.expectedContentLength)) }
            return true
        }
        completionHandler(active ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tooLarge = state.withLock { state in
            guard state.outcome == nil else { return false }
            guard data.count <= maximumBytes - state.data.count else { return true }
            state.data.append(data)
            return false
        }
        if tooLarge { complete(.failure(HTTPClientError.responseTooLarge)); dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            complete(.failure(metrics.confirmedUnsent && task.response == nil ? HTTPRequestNotSent(underlying: error) : error))
        } else {
            let result: Result<(Data, URLResponse), any Error> = state.withLock { state in
                guard let response = state.response ?? task.response else { return .failure(HTTPClientError.invalidResponse) }
                return .success((state.data, response))
            }
            complete(result)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        self.metrics.urlSession(session, task: task, didFinishCollecting: metrics)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        metrics.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
    }
}
