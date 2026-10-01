import ClientCore
import StorageCore
import TransportCore
import MediaKit
import Foundation

/// 应用侧组装传输提示和诊断记录。
private struct AppHTTPClientObserver: HTTPClientObserving, Sendable {
    let warningCenter: NetworkMagicWarningCenter?

    func willSend(_ request: URLRequest) async throws {
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

    static var appObserver: any HTTPClientObserving & Sendable {
        AppHTTPClientObserver(warningCenter: defaultNetworkWarningCenter)
    }

    init(
        transport: any HTTPTransport,
        networkWarningCenter: NetworkMagicWarningCenter? = HTTPClient.defaultNetworkWarningCenter
    ) {
        self.init(transport: Self.appTransport(transport), observer: AppHTTPClientObserver(warningCenter: networkWarningCenter))
    }

    private static func appTransport(_ production: any HTTPTransport) -> any HTTPTransport {
#if BIT101_UI_TESTING
        if AppFileDirectories.isRunningUITest { return UITestHTTPTransport() }
#endif
        return production
    }

    static let community = HTTPClient(transport: NetworkSessionPool.community)
    static let shared = HTTPClient(transport: NetworkSessionPool.shared)
}

enum NetworkSessionPool {
    static let shared: any HTTPTransport = {
        let configuration = URLSessionConfiguration.default
        return URLSessionTransport.make(configuration: configuration)
    }()

    /// BIT101 社区接口共享连接池、Cookie 容器和 URLCache，供各 Service 复用 TLS 连接。
    static let community: any HTTPTransport = {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieAcceptPolicy = .always
        configuration.waitsForConnectivity = true
        return URLSessionTransport.make(configuration: configuration)
    }()

    static let scoreAuthentication: any HTTPTransport = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = true
        return URLSessionTransport.make(configuration: configuration)
    }()

    /// 可信成绩单图片使用内存态 ephemeral 会话，并与共享磁盘缓存隔离。
    static let sensitiveDownloads: any HTTPTransport = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = true
        return URLSessionTransport.make(configuration: configuration)
    }()

    static let schoolCAS = schoolCASTransport(followsRedirects: true)
    static let schoolCASManualRedirects = schoolCASTransport(followsRedirects: false)

    private static func schoolCASTransport(followsRedirects: Bool) -> any HTTPTransport {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieAcceptPolicy = .always
        return URLSessionTransport.make(configuration: configuration, followsRedirects: followsRedirects)
    }

    static func teachingCenter(cookieStorage: HTTPCookieStorage) -> any HTTPTransport {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpCookieStorage = cookieStorage
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSessionTransport.make(configuration: configuration)
    }
}

enum AppNetworkPath {
    static let state: NetworkPathState = {
#if BIT101_AUTOMATED_TESTING || BIT101_UI_TESTING
        return NetworkPathState(snapshot: NetworkPathSnapshot(status: .connected))
#else
        return NetworkPathState()
#endif
    }()
}

/// 媒体缓存与下载在应用入口共用同一配置。
enum AppMedia {
    static let environment = MediaEnvironment(
        files: AppFileDirectories.files,
        previewFiles: AppFileDirectories.files,
        defaults: AppFileDirectories.defaults,
        imageHTTPClient: .community,
        avatarHTTPClient: .shared
    )
}

/// 学校会话的生产实例在应用组装入口选择。
enum AppSchoolSession {
    static let teachingCenter = TeachingCenterSessionState(cookieStorage: .shared)
}
