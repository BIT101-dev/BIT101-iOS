import Foundation

/// Traverses wrapped errors with one identity check per error object.
public nonisolated enum ErrorChain {
    public static func contains(_ error: Error, matching predicate: (Error) -> Bool) -> Bool {
        var current: Error? = error
        var visited: [ObjectIdentifier: NSError] = [:]
        while let candidate = current {
            let nsError = candidate as NSError
            let identity = ObjectIdentifier(nsError)
            guard visited[identity] == nil else { return false }
            visited[identity] = nsError
            if predicate(candidate) { return true }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? Error
        }
        return false
    }
}

public nonisolated enum TaskCancellation {
    /// 同时识别 Swift Concurrency 和 URLSession 发出的取消信号。
    public static func matches(_ error: Error) -> Bool {
        ErrorChain.contains(error) { candidate in
            if candidate is CancellationError {
                return true
            }
            let nsError = candidate as NSError
            return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
        }
    }
}
