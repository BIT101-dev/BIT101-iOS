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
            let resolved = upgradedURL(from: candidate)
            return isHTTPURL(resolved) ? resolved : nil
        }
        guard let relative = URL(string: location, relativeTo: baseURL)?.absoluteURL else {
            return nil
        }
        let resolved = upgradedURL(from: relative)
        return isHTTPURL(resolved) ? resolved : nil
    }

    nonisolated private static func isHTTPURL(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https":
            return true
        default:
            return false
        }
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

/// 正常跟随重定向；学校链接中的 HTTP 目标在此升级为 HTTPS。
final class HTTPSUpgradingRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url else {
            completionHandler(nil)
            return
        }
        let upgradedURL = HTTPSURLUpgrade.upgradedURL(from: url)
        guard let scheme = upgradedURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            completionHandler(nil)
            return
        }
        var secureRequest = request
        secureRequest.url = upgradedURL

        let remainsSameOrigin = response.url.map { sameOrigin($0, upgradedURL) } ?? false
        if !remainsSameOrigin {
            let method = request.httpMethod?.uppercased() ?? "GET"
            guard method == "GET" || method == "HEAD" else {
                completionHandler(nil)
                return
            }
            secureRequest.setValue(nil, forHTTPHeaderField: "Authorization")
            secureRequest.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
            secureRequest.setValue(nil, forHTTPHeaderField: "Cookie")
            secureRequest.setValue(nil, forHTTPHeaderField: "fake-cookie")
            secureRequest.httpBody = nil
            secureRequest.httpBodyStream = nil
        }

        completionHandler(secureRequest)
    }

    private func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard
            let lhsScheme = lhs.scheme?.lowercased(),
            let rhsScheme = rhs.scheme?.lowercased(),
            let lhsHost = lhs.host?.lowercased(),
            let rhsHost = rhs.host?.lowercased()
        else {
            return false
        }

        let lhsPort = lhs.port ?? (lhsScheme == "https" ? 443 : 80)
        let rhsPort = rhs.port ?? (rhsScheme == "https" ? 443 : 80)
        return lhsScheme == rhsScheme && lhsHost == rhsHost && lhsPort == rhsPort
    }
}
