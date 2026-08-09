//
//  LoginSessionState.swift
//  BIT101-iOS
//

import Foundation
import Security

/// 本地保存的登录凭据。
///
/// 这里只保存“足以静默重登学校 SSO”的最小信息组合，不额外混入 fake-cookie 等会话态。
struct StoredCredentials {
    let studentID: String
    let password: String
}

/// 教学中心 WebVPN 会话的进程内状态。
///
/// 这里不再使用“成功一次后永久为 true”的静态布尔值，而是把状态绑定到具体学号，
/// 并且每次使用前同时检查对应 Cookie 是否仍然存在。网络层发现会话失效时可以显式
/// 调用 `invalidate`，下一次请求就会重新经过 bit-login。
final class TeachingCenterSessionState {
    static let shared = TeachingCenterSessionState()

    private let lock = NSLock()
    private let cookieStorage = HTTPCookieStorage.shared
    private var authenticatedStudentID: String?
    private var preparedStudentID: String?

    private init() {}

    func hasUsableSession(for studentID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !studentID.isEmpty else { return false }
        guard hasWebVPNCookie else {
            authenticatedStudentID = nil
            preparedStudentID = nil
            return false
        }

        // App 重启后内存标记会消失，但系统 Cookie 仍可能有效。登录流程在切换账号前会
        // 清掉学校 Cookie，因此这里可以把现存 Cookie 重新绑定到当前保存的学号。
        if authenticatedStudentID == nil {
            authenticatedStudentID = studentID
        }
        return authenticatedStudentID == studentID
    }

    func markAuthenticated(for studentID: String) {
        lock.lock()
        authenticatedStudentID = studentID
        preparedStudentID = nil
        lock.unlock()
    }

    func isPrepared(for studentID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return authenticatedStudentID == studentID && preparedStudentID == studentID && hasWebVPNCookie
    }

    func markPrepared(for studentID: String) {
        lock.lock()
        if authenticatedStudentID == studentID, hasWebVPNCookie {
            preparedStudentID = studentID
        }
        lock.unlock()
    }

    /// 使内存状态失效，并按需只删除教学中心/WebVPN 域的 Cookie。
    func invalidate(clearCookies: Bool = true) {
        lock.lock()
        authenticatedStudentID = nil
        preparedStudentID = nil
        lock.unlock()

        guard clearCookies else { return }
        deleteCookies(matching: [
            "webvpn.bit.edu.cn",
            "jxzxehall.bit.edu.cn",
            "jxzxehallapp.bit.edu.cn",
        ])
    }

    /// 退出、重新登录或切换账号时清理学校身份相关 Cookie，但不影响其他网站 Cookie。
    func clearSchoolAuthenticationCookies() {
        invalidate(clearCookies: false)
        deleteCookies(matching: [
            "webvpn.bit.edu.cn",
            "sso.bit.edu.cn",
            "jxzxehall.bit.edu.cn",
            "jxzxehallapp.bit.edu.cn",
            "jwms.bit.edu.cn",
            "lexue.bit.edu.cn",
        ])
    }

    private var hasWebVPNCookie: Bool {
        let now = Date()
        return cookieStorage.cookies?.contains { cookie in
            normalizedDomain(cookie.domain) == "webvpn.bit.edu.cn"
                && (cookie.expiresDate == nil || cookie.expiresDate! > now)
        } ?? false
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

/// 从学校登录页里解析出来的必要上下文。
///
/// 学校 CAS 登录页并不是一个稳定 JSON 接口，而是一段 HTML，所以这里先把后续登录真正
/// 需要的字段提炼成一个小结构体，供业务层继续往下传。
struct SchoolLoginContext {
    let salt: String?
    let execution: String?
    let isLoggedIn: Bool
}

/// 登录链路中的统一错误定义。
enum LoginServiceError: LocalizedError {
    case invalidSchoolLoginPage
    case schoolLoginFailed
    case unableToRestoreSchoolSession
    case invalidServerResponse
    case keychainWriteFailed(OSStatus)
    case keychainReadFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidSchoolLoginPage:
            return "学校登录页结构发生变化，暂时无法完成登录。"
        case .schoolLoginFailed:
            return "学校统一身份认证登录失败，请检查学号和密码。"
        case .unableToRestoreSchoolSession:
            return "学校登录状态已过期，且缺少可用于静默恢复的本地凭据。"
        case .invalidServerResponse:
            return "服务器返回了无法识别的数据。"
        case let .keychainWriteFailed(status):
            return "无法保存登录信息（Keychain 状态码: \(status)）。"
        case let .keychainReadFailed(status):
            return "无法读取登录信息（Keychain 状态码: \(status)）。"
        }
    }
}
