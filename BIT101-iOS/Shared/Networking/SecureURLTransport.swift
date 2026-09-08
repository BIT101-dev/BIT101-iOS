import Foundation

/// 学校系统偶发将 HTTPS 重定向到 HTTP；所有学校网络链路统一在这里升级为 HTTPS。
enum HTTPSURLUpgrade {
    nonisolated static func upgradedURL(from url: URL) -> URL {
        guard url.scheme?.lowercased() == "http" else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url ?? url
    }

    nonisolated static func upgradedURLString(from string: String) -> String {
        guard let url = URL(string: string) else { return string }
        return upgradedURL(from: url).absoluteString
    }

    nonisolated static func resolvedURL(from location: String, relativeTo baseURL: URL) -> URL? {
        if let candidate = URL(string: location), candidate.scheme != nil {
            return upgradedURL(from: candidate)
        }
        guard let relative = URL(string: location, relativeTo: baseURL)?.absoluteURL else {
            return nil
        }
        return upgradedURL(from: relative)
    }
}

/// 认证请求手动检查 `Location`；这套 delegate 终止自动重定向。
final class NoRedirectURLSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// 正常跟随重定向；学校历史地址中的明文 HTTP 目标在这里升级为 HTTPS。
final class HTTPSUpgradingRedirectDelegate: NSObject, URLSessionTaskDelegate {
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
        let upgradedURL = HTTPSURLUpgrade.upgradedURL(from: url)
        guard upgradedURL != url else {
            completionHandler(request)
            return
        }
        var secureRequest = request
        secureRequest.url = upgradedURL
        completionHandler(secureRequest)
    }
}
