import Foundation

enum TaskCancellation {
    /// 同时识别 Swift Concurrency 和 URLSession 发出的取消信号。
    static func matches(_ error: Error) -> Bool {
        var current: Error? = error
        var visitedErrors = Set<ObjectIdentifier>()

        while let current {
            if current is CancellationError {
                return true
            }

            if let urlError = current as? URLError, urlError.code == .cancelled {
                return true
            }

            let nsError = current as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                return true
            }

            guard visitedErrors.insert(ObjectIdentifier(nsError)).inserted else {
                return false
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? Error
        }

        return false
    }
}
