import Foundation
import TransportCore

/// 学校系统请求短信验证码时交给应用层的交互上下文。
public struct SchoolSMSCodeRequest: Identifiable, Sendable {
    public let id: UUID
    public let maskedPhone: String
    public let purpose: String

    public init(id: UUID = UUID(), maskedPhone: String, purpose: String) {
        self.id = id
        self.maskedPhone = maskedPhone
        self.purpose = purpose
    }
}

public typealias SchoolSMSCodeHandler = @MainActor (SchoolSMSCodeRequest) async throws -> String

public nonisolated struct SchoolSecondFactorContext: Sendable {
    public let execution: String
    public let formAction: URL
    public let userObjectID: String

    public init(execution: String, formAction: URL, userObjectID: String) {
        self.execution = execution
        self.formAction = formAction
        self.userObjectID = userObjectID
    }
}

public nonisolated struct SchoolLoginContext: Sendable {
    public let salt: String?
    public let execution: String?
    public let isLoggedIn: Bool

    public init(salt: String?, execution: String?, isLoggedIn: Bool) {
        self.salt = salt
        self.execution = execution
        self.isLoggedIn = isLoggedIn
    }
}

/// 教学中心 WebVPN 会话的进程内状态。
///
/// 认证状态属于学校网络基础设施，页面层通过服务协议消费它。
@MainActor
public final class TeachingCenterSessionState {
    public let authenticationRecovery = SessionRefreshCoordinator<SchoolSessionIdentity>()
    public let preparationRecovery = SessionRefreshCoordinator<SchoolSessionIdentity>()
    public private(set) var sessionRevision: UInt64 = 0
    private var owner: SchoolSessionIdentity?
    private var selectedCookieStorage: HTTPCookieStorage
    public var cookieStorage: HTTPCookieStorage {
        return selectedCookieStorage
    }
    private var authenticatedStudentID: String?
    private var preparedStudentID: String?
    private var directStudentID: String?
    private var directPreferenceUntil: Date?

    public init(cookieStorage: HTTPCookieStorage) {
        selectedCookieStorage = cookieStorage
    }

    public func selectOwner(_ identity: SchoolSessionIdentity) {
        defer { owner = identity }
        guard let owner, owner != identity else { return }
        authenticationRecovery.cancel()
        preparationRecovery.cancel()
        invalidate()
    }

    public func replaceCookieStorage(with cookieStorage: HTTPCookieStorage) {
        authenticationRecovery.cancel()
        preparationRecovery.cancel()
        owner = nil
        sessionRevision &+= 1
        selectedCookieStorage = cookieStorage
        authenticatedStudentID = nil
        preparedStudentID = nil
        directStudentID = nil
        directPreferenceUntil = nil
    }

    public func hasUsableSession(for studentID: String) -> Bool {

        guard !studentID.isEmpty else { return false }
        if isDirectPreferred(for: studentID, now: Date()) {
            return false
        }
        guard hasWebVPNCookie else {
            authenticatedStudentID = nil
            preparedStudentID = nil
            return false
        }

        return authenticatedStudentID == studentID
    }

    public func markAuthenticated(for studentID: String) {
        sessionRevision &+= 1
        authenticatedStudentID = studentID
        preparedStudentID = nil
        directStudentID = nil
        directPreferenceUntil = nil
    }

    public func shouldPreferDirect(for studentID: String, now: Date = Date()) -> Bool {
        guard directStudentID == studentID,
              let directPreferenceUntil,
              directPreferenceUntil > now
        else {
            directStudentID = nil
            self.directPreferenceUntil = nil
            return false
        }
        return true
    }

    public func markDirectPreferred(for studentID: String, now: Date = Date()) {
        sessionRevision &+= 1
        authenticatedStudentID = nil
        preparedStudentID = nil
        directStudentID = studentID
        directPreferenceUntil = now.addingTimeInterval(10 * 60)
    }

    public func isPrepared(for studentID: String) -> Bool {
        return hasUsableRoute(for: studentID, now: Date())
            && preparedStudentID == studentID
    }

    public func markPrepared(for studentID: String) {
        if hasUsableRoute(for: studentID, now: Date()) {
            preparedStudentID = studentID
        }
    }

    public func invalidate(clearCookies: Bool = true) {
        sessionRevision &+= 1
        authenticatedStudentID = nil
        preparedStudentID = nil
        directStudentID = nil
        directPreferenceUntil = nil

        guard clearCookies else { return }
        deleteCookies(matching: [
            "webvpn.bit.edu.cn",
            "jxzxehall.bit.edu.cn",
            "jxzxehallapp.bit.edu.cn",
        ])
    }

    public func clearSchoolAuthenticationCookies() {
        invalidate(clearCookies: false)
        deleteCookies(matching: [
            "webvpn.bit.edu.cn",
            "sso.bit.edu.cn",
            "jxzxehall.bit.edu.cn",
            "jxzxehallapp.bit.edu.cn",
            "jwms.bit.edu.cn",
            "lexue.bit.edu.cn",
            "zy-eclass.bit.edu.cn",
            "zy-identity.bit.edu.cn",
        ])
    }

    private var hasWebVPNCookie: Bool {
        let now = Date()
        return selectedCookieStorage.cookies?.contains { cookie in
            normalizedDomain(cookie.domain) == "webvpn.bit.edu.cn"
                && (cookie.expiresDate.map { $0 > now } ?? true)
        } ?? false
    }

    private func isDirectPreferred(for studentID: String, now: Date) -> Bool {
        directStudentID == studentID && (directPreferenceUntil ?? .distantPast) > now
    }

    private func hasUsableRoute(for studentID: String, now: Date) -> Bool {
        (authenticatedStudentID == studentID && hasWebVPNCookie)
            || isDirectPreferred(for: studentID, now: now)
    }

    private func deleteCookies(matching domains: Set<String>) {
        cookieStorage.cookies?.forEach { cookie in
            let domain = normalizedDomain(cookie.domain)
            if domains.contains(where: { domain == $0 || domain.hasSuffix(".\($0)") }) {
                cookieStorage.deleteCookie(cookie)
            }
        }
    }

    private func normalizedDomain(_ domain: String) -> String {
        domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }
}
