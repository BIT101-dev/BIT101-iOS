import Foundation

private func containsUnderlyingError(
    _ error: Error,
    matching predicate: (NSError) -> Bool
) -> Bool {
    var current: NSError? = error as NSError
    var visited = Set<ObjectIdentifier>()

    while let candidate = current {
        let identifier = ObjectIdentifier(candidate)
        guard visited.insert(identifier).inserted else { break }

        if predicate(candidate) {
            return true
        }
        current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return false
}

/// 判断请求是否因为 DNS 无法解析主机而失败。
///
/// `URLSession` 有时会把真正的 `URLError` 包在底层错误里；错误判断需要沿错误链检查。
func isHostResolutionError(_ error: Error) -> Bool {
    containsUnderlyingError(error) { candidate in
        candidate.domain == NSURLErrorDomain &&
        (candidate.code == NSURLErrorCannotFindHost || candidate.code == NSURLErrorDNSLookupFailed)
    }
}

/// 判断 URLSession 是否因 TLS 证书校验失败而拒绝连接。
func isCertificateValidationError(_ error: Error) -> Bool {
    containsUnderlyingError(error) { candidate in
        candidate.domain == NSURLErrorDomain && [
            NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateUntrusted,
            NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateNotYetValid
        ].contains(candidate.code)
    }
}

/// 判断网络路线是否适合切换后重试。
func isScheduleTransientNetworkError(_ error: Error) -> Bool {
    if isHostResolutionError(error) || isCertificateValidationError(error) { return true }
    return containsUnderlyingError(error) { candidate in
        candidate.domain == NSURLErrorDomain && [
            NSURLErrorCannotFindHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorSecureConnectionFailed,
        ].contains(candidate.code)
    }
}

func isSchoolTransportFailure(_ error: Error) -> Bool {
    if let scheduleError = error as? ScheduleServiceError {
        return scheduleError.isSchoolTransportFailure
    }

    guard let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error else {
        return false
    }
    return isSchoolTransportFailure(underlying)
}
