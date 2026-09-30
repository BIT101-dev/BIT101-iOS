import ClientCore
import StorageCore
import TransportCore
import MediaKit
import Foundation

/// 应用侧组装传输提示和诊断记录。
private struct AppHTTPClientObserver: HTTPClientObserving {
    let warningCenter: NetworkMagicWarningCenter?

    func willSend(_ request: URLRequest) async throws {
#if BIT101_UI_TESTING
        if AppFileDirectories.isRunningUITest {
            throw URLError(.notConnectedToInternet)
        }
#endif
        if let url = request.url, let warningCenter {
            _ = await warningCenter.consider(url: url)
        }
    }

    func didFinish(
        request: URLRequest,
        data: Data?,
        response: URLResponse?,
        error: Error?,
        elapsed: TimeInterval
    ) async {
        await NetworkDiagnosticStore.shared.record(
            request: request, data: data, response: response, error: error, elapsed: elapsed
        )
    }
}

extension HTTPClient {
#if BIT101_AUTOMATED_TESTING
    private static let defaultNetworkWarningCenter: NetworkMagicWarningCenter? = nil
#else
    private static let defaultNetworkWarningCenter: NetworkMagicWarningCenter? = .shared
#endif

    init(
        transport: any HTTPTransport,
        networkWarningCenter: NetworkMagicWarningCenter? = HTTPClient.defaultNetworkWarningCenter
    ) {
        self.init(transport: transport, observer: AppHTTPClientObserver(warningCenter: networkWarningCenter))
    }

    static let community = HTTPClient(transport: NetworkSessionPool.community)
    static let shared = HTTPClient(transport: NetworkSessionPool.shared)
}

enum NetworkSessionPool {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.default
        return URLSession(
            configuration: configuration,
            delegate: HTTPSUpgradingRedirectDelegate(),
            delegateQueue: nil
        )
    }()

    /// BIT101 社区接口共享连接池、Cookie 容器和 URLCache，供各 Service 复用 TLS 连接。
    static let community: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieAcceptPolicy = .always
        configuration.waitsForConnectivity = true
        return URLSession(
            configuration: configuration,
            delegate: HTTPSUpgradingRedirectDelegate(),
            delegateQueue: nil
        )
    }()

    static let scoreAuthentication: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = true
        return URLSession(
            configuration: configuration,
            delegate: HTTPSUpgradingRedirectDelegate(),
            delegateQueue: nil
        )
    }()

    /// 可信成绩单图片使用内存态 ephemeral 会话，并与共享磁盘缓存隔离。
    static let sensitiveDownloads: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = true
        return URLSession(
            configuration: configuration,
            delegate: HTTPSUpgradingRedirectDelegate(),
            delegateQueue: nil
        )
    }()
}

/// 媒体缓存与下载在应用入口共用同一配置。
enum AppMedia {
    static let environment = MediaEnvironment(
        files: AppFileDirectories.files,
        defaults: AppFileDirectories.defaults,
        imageHTTPClient: .community,
        avatarHTTPClient: .shared
    )
}

/// 学校会话的生产实例在应用组装入口选择。
enum AppSchoolSession {
    static let teachingCenter = TeachingCenterSessionState(cookieStorage: .shared)
}
