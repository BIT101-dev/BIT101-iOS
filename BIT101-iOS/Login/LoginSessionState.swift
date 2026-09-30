//
//  LoginSessionState.swift
//  BIT101-iOS
//

import Foundation
import Security
import ClientCore

/// 本地保存的登录凭据。
///
/// 这里保存足以静默重登学校 SSO 的最小信息组合；fake-cookie 等会话态保持在结构外。
struct StoredCredentials {
    let studentID: String
    let password: String
}

/// 登录链路中的统一错误定义。
enum LoginServiceError: LocalizedError {
    case invalidSchoolLoginPage
    case schoolLoginFailed
    case invalidCredentials
    case schoolSMSRequired(SchoolSecondFactorContext)
    case schoolSMSCodeInvalid(String)
    case schoolSMSUnavailable(String)
    case unableToRestoreSchoolSession
    case invalidServerResponse
    case keychainWriteFailed(OSStatus)
    case keychainReadFailed(OSStatus)

    var isCredentialFailure: Bool {
        switch self {
        case .invalidCredentials, .schoolLoginFailed:
            return true
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidSchoolLoginPage:
            return "学校登录页结构发生变化，暂时无法完成登录。"
        case .schoolLoginFailed:
            return "学校统一身份认证登录失败，请检查学号和密码。"
        case .invalidCredentials:
            return "学号或密码错误，请检查后重试。"
        case .schoolSMSRequired:
            return "学校统一身份认证需要短信验证。"
        case let .schoolSMSCodeInvalid(message):
            return message
        case let .schoolSMSUnavailable(message):
            return message
        case .unableToRestoreSchoolSession:
            return "学校登录状态已过期，且缺少可用于静默恢复的本地凭据。"
        case .invalidServerResponse:
            return "服务器返回了无法识别的数据。"
        case .keychainWriteFailed:
            return "无法保存登录信息，请稍后重试。"
        case .keychainReadFailed:
            return "无法读取登录信息，请稍后重试。"
        }
    }
}
