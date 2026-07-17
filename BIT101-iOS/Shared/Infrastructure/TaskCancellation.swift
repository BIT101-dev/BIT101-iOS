import Foundation

enum TaskCancellation {
    /// 同时识别 Swift Concurrency 和 URLSession 发出的取消信号。
    static func matches(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}
