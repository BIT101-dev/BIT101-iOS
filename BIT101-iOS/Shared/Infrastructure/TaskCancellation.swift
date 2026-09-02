import Foundation

enum TaskCancellation {
    /// 同时识别 Swift Concurrency 和 URLSession 发出的取消信号。
    static func matches(_ error: Error) -> Bool {
        matches(error, depth: 0)
    }

    private static func matches(_ error: Error, depth: Int) -> Bool {
        if error is CancellationError {
            return true
        }

        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }

        guard depth < 4, let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error else {
            return false
        }
        return matches(underlying, depth: depth + 1)
    }
}
