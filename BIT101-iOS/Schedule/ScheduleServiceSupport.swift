import Foundation

/// 判断请求是否因为 DNS 无法解析主机而失败。
///
/// `URLSession` 有时会把真正的 `URLError` 包在底层错误里，因此不能只检查最外层。
func isHostResolutionError(_ error: Error) -> Bool {
    var current: NSError? = error as NSError
    var visited = Set<ObjectIdentifier>()

    while let candidate = current {
        let identifier = ObjectIdentifier(candidate)
        guard visited.insert(identifier).inserted else { break }

        if candidate.domain == NSURLErrorDomain,
           candidate.code == NSURLErrorCannotFindHost || candidate.code == NSURLErrorDNSLookupFailed
        {
            return true
        }
        current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return false
}
