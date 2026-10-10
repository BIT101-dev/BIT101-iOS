import ClientCore
import StorageCore
import TransportCore
import MediaKit
import Foundation

/// 应用侧组装传输提示和诊断记录。
private struct AppHTTPClientObserver: HTTPClientObserving, Sendable {
    let warningCenter: NetworkMagicWarningCenter?
    var identity: SchoolSessionIdentity? = nil

    func forRequest() -> any HTTPClientObserving {
        AppHTTPClientObserver(warningCenter: warningCenter, identity: AppAccountSession.storage.schoolSessionIdentity)
    }

    func willSend(_ request: URLRequest) async throws {
        if let url = request.url, let warningCenter {
            _ = await warningCenter.consider(url: url)
        }
        guard identity == AppAccountSession.storage.schoolSessionIdentity else { throw CancellationError() }
    }

    func didFinish(
        request: URLRequest,
        data: Data?,
        response: URLResponse?,
        error: Error?,
        elapsed: TimeInterval
    ) async {
        guard let identity else { return }
        await NetworkDiagnosticStore.shared.record(
            owner: identity, request: request, data: data, response: response, error: error, elapsed: elapsed
        )
    }
}

extension HTTPClient {
#if BIT101_UI_TESTING
    static let defaultNetworkWarningCenter: NetworkMagicWarningCenter? = AppUITestBootstrap.usesProductionComposition ? .shared : nil
#elseif BIT101_AUTOMATED_TESTING
    static let defaultNetworkWarningCenter: NetworkMagicWarningCenter? = nil
#else
    static let defaultNetworkWarningCenter: NetworkMagicWarningCenter? = .shared
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

final class SchoolCookieTransport: HTTPTransport {
    private let state: TeachingCenterSessionState
    private let make: (HTTPCookieStorage) -> any HTTPTransport
    private var selectedCookies: HTTPCookieStorage?
    private var selectedClient: HTTPClient?

    init(state: TeachingCenterSessionState, make: @escaping (HTTPCookieStorage) -> any HTTPTransport) {
        self.state = state
        self.make = make
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, maximumBytes: nil)
    }

    func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
        let cookies = state.cookieStorage
        if selectedCookies !== cookies {
            selectedCookies = cookies
            selectedClient = HTTPClient(transport: make(cookies), observer: nil)
        }
        guard let client = selectedClient else { throw HTTPClientError.invalidResponse }
        let response = try await client.send(request, accepting: 100 ..< 600, maximumBytes: maximumBytes)
        return (response.data, response.response)
    }
}

enum NetworkSessionPool {
    private static func make(configuration: URLSessionConfiguration, followsRedirects: Bool = true, productionPolicy: Bool = false) -> any HTTPTransport {
#if RELEASE_NETWORK_SMOKE
        if !productionPolicy {
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            return UncachedHTTPTransport(base: URLSessionTransport.make(configuration: configuration, followsRedirects: followsRedirects))
        }
#endif
        let transport = URLSessionTransport.make(configuration: configuration, followsRedirects: followsRedirects)
#if BIT101_AUTOMATED_TESTING && !BIT101_UI_TESTING
        return AutomatedTestHTTPTransport(base: transport)
#else
        return transport
#endif
    }

    static let productionCommunity = communityTransport(productionPolicy: true)
    static let productionSchoolCAS = schoolCASTransport(state: AppSchoolSession.teachingCenter, followsRedirects: true, productionPolicy: true)
    static let productionSchoolCASManualRedirects = schoolCASTransport(state: AppSchoolSession.teachingCenter, followsRedirects: false, productionPolicy: true)
    static let productionTeachingCenter = teachingCenter(state: AppSchoolSession.teachingCenter, productionPolicy: true)

    static let shared: any HTTPTransport = {
        let configuration = URLSessionConfiguration.default
        return make(configuration: configuration)
    }()

    static let appLinkAssociation = make(configuration: .ephemeral, followsRedirects: false)

    /// 社区服务共享连接池与公共 URLCache；认证请求由会话快照提供凭据。
    static let community = communityTransport(productionPolicy: false)

    private static func communityTransport(productionPolicy: Bool) -> any HTTPTransport {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieAcceptPolicy = .always
        return make(configuration: configuration, productionPolicy: productionPolicy)
    }

    static let scoreAuthentication: any HTTPTransport = SchoolCookieTransport(state: AppSchoolSession.teachingCenter) { cookies in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = cookies
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = true
        return make(configuration: configuration)
    }

    /// 可信成绩单图片使用内存态 ephemeral 会话，并与共享磁盘缓存隔离。
    static let sensitiveDownloads: any HTTPTransport = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = true
        return make(configuration: configuration)
    }()

    static let schoolCAS = schoolCASTransport(followsRedirects: true)
    static let schoolCASManualRedirects = schoolCASTransport(followsRedirects: false)

    private static func schoolCASTransport(followsRedirects: Bool) -> any HTTPTransport {
        schoolCASTransport(state: AppSchoolSession.teachingCenter, followsRedirects: followsRedirects)
    }

    static func schoolCASTransport(state: TeachingCenterSessionState, followsRedirects: Bool, productionPolicy: Bool = false) -> any HTTPTransport {
        SchoolCookieTransport(state: state) { cookies in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieAcceptPolicy = .always
            configuration.httpCookieStorage = cookies
            return make(configuration: configuration, followsRedirects: followsRedirects, productionPolicy: productionPolicy)
        }
    }

    static func teachingCenter(state: TeachingCenterSessionState, productionPolicy: Bool = false) -> any HTTPTransport {
        SchoolCookieTransport(state: state) { teachingCenter(cookieStorage: $0, productionPolicy: productionPolicy) }
    }

    static func teachingCenter(cookieStorage: HTTPCookieStorage, productionPolicy: Bool = false) -> any HTTPTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpCookieStorage = cookieStorage
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return make(configuration: configuration, productionPolicy: productionPolicy)
    }
}

#if BIT101_AUTOMATED_TESTING && !BIT101_UI_TESTING
private struct AutomatedTestHTTPTransport: HTTPTransport {
    let base: any HTTPTransport
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, maximumBytes: nil)
    }
    func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
        guard let host = request.url?.host?.lowercased(), ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        else { throw URLError(.notConnectedToInternet) }
        let result = try await HTTPClient(transport: base, observer: nil).send(
            request, accepting: 100 ..< 600, maximumBytes: maximumBytes)
        return (result.data, result.response)
    }
}
#endif

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
    static let environment = makeEnvironment()
    static func makeEnvironment(files: any AppFileService = AppFileDirectories.files,
                                defaults: UserDefaults = AppFileDirectories.defaults,
                                imageHTTPClient: HTTPClient = .community,
                                avatarHTTPClient: HTTPClient = .shared) -> MediaEnvironment {
        MediaEnvironment(files: files, previewStorage: MediaPreviewStorage(files: files), defaults: defaults,
                         imageHTTPClient: imageHTTPClient, avatarHTTPClient: avatarHTTPClient)
    }
}

/// 学校会话的生产实例在应用组装入口选择。
enum AppSchoolSession {
    static let teachingCenter = isolatedState()

    static func isolatedState() -> TeachingCenterSessionState {
        TeachingCenterSessionState(cookieStorage: makeCookieStorage())
    }

    static func clearSchoolAuthenticationCookies() {
        teachingCenter.clearSchoolAuthenticationCookies()
        teachingCenter.replaceCookieStorage(with: makeCookieStorage())
    }

    private static func makeCookieStorage() -> HTTPCookieStorage {
        guard let storage = URLSessionConfiguration.ephemeral.httpCookieStorage else {
            preconditionFailure("School sessions require an ephemeral cookie container")
        }
        return storage
    }
}
