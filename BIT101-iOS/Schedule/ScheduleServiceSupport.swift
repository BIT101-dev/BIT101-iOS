import Foundation

// MARK: - Redirect Helpers

/// 学校接口偶发回跳 HTTP，这里统一升级为 HTTPS，避免 ATS 拦截。
final class HTTPSUpgradingRedirectDelegate: NSObject, URLSessionTaskDelegate {
    /// 截获学校侧的 HTTP 降级跳转，并在继续请求前强制升级回 HTTPS。
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url else {
            completionHandler(request)
            return
        }

        if let upgradedURL = ScheduleURLUpgrade.upgradedURL(from: url), upgradedURL != url {
            var secureRequest = request
            secureRequest.url = upgradedURL
            completionHandler(secureRequest)
            return
        }

        completionHandler(request)
    }
}

/// 统一识别 Swift Concurrency 与 URLSession 的取消错误。
func isCancellationError(_ error: Error) -> Bool {
    TaskCancellation.matches(error)
}


/// 日程同步链路里所有 URL 的升级工具。
enum ScheduleURLUpgrade {
    /// 尝试把单个 URL 升级成 HTTPS。
    nonisolated static func upgradedURL(from url: URL) -> URL? {
        guard url.scheme?.lowercased() == "http" else {
            return url
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url
    }

    /// 把 URL 字符串升级成 HTTPS 文本。
    nonisolated static func upgradedURLString(from string: String) -> String {
        guard
            let url = URL(string: string),
            let upgraded = upgradedURL(from: url)
        else {
            return string
        }

        return upgraded.absoluteString
    }

    /// 把重定向里的下一跳地址解析成绝对 URL，并顺手补 HTTPS。
    nonisolated static func resolvedURL(from location: String, relativeTo baseURL: URL) -> URL? {
        if let absolute = URL(string: location) {
            return upgradedURL(from: absolute)
        }

        return URL(string: location, relativeTo: baseURL).flatMap(upgradedURL(from:))
    }
}

