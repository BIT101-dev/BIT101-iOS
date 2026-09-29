import Foundation

@MainActor
private final class CommunitySessionRefreshCoordinator {
    static let shared = CommunitySessionRefreshCoordinator()

    private var refreshTask: Task<Void, Error>?

    private init() {}

    func refreshIfNeeded(observedCookie: String, storage: LoginStorage) async throws {
        guard storage.fakeCookie == observedCookie else { return }
        if let refreshTask {
            try await refreshTask.value
            return
        }

        let task = Task { @MainActor in
            guard let credentials = try storage.loadCredentials() else {
                throw LoginServiceError.unableToRestoreSchoolSession
            }
            _ = try await LoginService(storage: storage).login(
                studentID: credentials.studentID,
                password: credentials.password
            )
        }
        refreshTask = task
        do {
            try await task.value
            refreshTask = nil
        } catch {
            refreshTask = nil
            throw error
        }
    }
}

/// 应用认证适配：为社区传输注入当前会话及恢复动作。
extension CommunityAPIClient {
    init(
        storage: LoginStorage = .shared,
        httpClient: HTTPClient = .community,
        baseURL: URL = AppURL.required("https://bit101.flwfdd.xyz"),
        errorDomain: String
    ) {
        self.init(
            httpClient: httpClient,
            baseURL: baseURL,
            errorDomain: errorDomain,
            fakeCookieProvider: { storage.fakeCookie },
            refreshHandler: { observedCookie in
                try await CommunitySessionRefreshCoordinator.shared.refreshIfNeeded(
                    observedCookie: observedCookie,
                    storage: storage
                )
            }
        )
    }
}
