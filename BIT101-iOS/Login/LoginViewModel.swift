//
//  LoginViewModel.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Combine
import Foundation

private func isLoginCancellation(_ error: Error) -> Bool {
    TaskCancellation.matches(error)
}

/// 登录页当前展示的顶层状态。
///
/// 登录模块用一个枚举表达“已登录 / 未登录”两种外层场景，根视图依据枚举切换页面。
enum LoginScreenState: Equatable {
    case signedOut
    case signedIn(studentID: String)
}

/// 管理本地登录态恢复、登录提交状态和退出后的界面回退。
final class LoginViewModel: ObservableObject {
    /// 学号输入框内容。
    @Published var studentID: String
    /// 密码输入框内容。
    @Published var password = ""
    /// 登录模块当前处于登录页还是主壳层。
    @Published private(set) var screenState: LoginScreenState
    /// 是否正在执行登录请求。
    @Published private(set) var isSubmitting = false
    /// 当前待展示的提示弹窗，登录模块通过 `AppAlert` 向视图层提供提示数据。
    @Published var alert: AppAlert?

    private let service: any LoginServicing
    /// 启动校验在视图重建期间保持单次触发。
    private var hasBootstrapped = false

    /// 用持久化的本地状态初始化登录表单与首屏。
    ///
    /// 如果本地已有 fake-cookie，先乐观进入主界面，远端校验放到后台完成。
    init(service: any LoginServicing = LoginService()) {
        self.service = service
        let savedStudentID = service.savedStudentID
        studentID = savedStudentID
        password = service.savedPassword
        screenState = service.hasCachedSession ? .signedIn(studentID: savedStudentID) : .signedOut
    }

    /// 当前输入是否满足提交条件。
    ///
    /// 当前属性校验输入的非空条件与提交状态；网络结果和密码正确性由提交流程处理。
    var canSubmit: Bool {
        !studentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !password.isEmpty &&
            !isSubmitting
    }

    /// 首次进入时检查登录态，视图重建期间沿用已完成的检查状态。
    ///
    /// 本地有会话时立即展示首屏；远端明确返回未登录时切到登录页。
    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        guard service.hasCachedSession else {
            screenState = .signedOut
            return
        }

        do {
            if let studentID = try await service.checkLogin() {
                self.studentID = studentID
                password = ""
                screenState = .signedIn(studentID: studentID)
            } else {
                self.studentID = service.savedStudentID
                password = service.savedPassword
                screenState = .signedOut
            }
        } catch {
            if isLoginCancellation(error) {
                hasBootstrapped = false
                return
            }
            studentID = service.savedStudentID
            password = service.savedPassword

            // 网络、超时或解析等临时错误静默保留主界面，登录态继续沿用本地会话。
            if service.hasCachedSession, !studentID.isEmpty {
                screenState = .signedIn(studentID: studentID)
            } else {
                screenState = .signedOut
            }
        }
    }

    /// 执行一次显式登录。
    ///
    /// 登录成功后清空内存中的密码文本；`LoginStorage` 保存凭据，供后续静默重登学校 SSO。
    func login() async {
        let trimmedStudentID = studentID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedStudentID.isEmpty else {
            alert = AppAlert(title: "学号不能为空", message: "请输入学校统一身份认证使用的学号。")
            return
        }

        guard !password.isEmpty else {
            alert = AppAlert(title: "密码不能为空", message: "请输入学校统一身份认证使用的密码。")
            return
        }

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let studentID = try await service.login(studentID: trimmedStudentID, password: password)
            self.studentID = studentID
            self.password = ""
            screenState = .signedIn(studentID: studentID)
        } catch {
            if isLoginCancellation(error) {
                return
            }
            alert = AppAlert(
                title: "登录失败",
                message: error.localizedDescription
            )
            screenState = .signedOut
        }
    }

    /// 退出当前账号，并回退到登录页。
    ///
    /// 退出动作清除会话并保留账号密码，登录页继续显示最近一次输入的学号。
    func logout() {
        service.logout()
        studentID = service.savedStudentID
        password = service.savedPassword
        screenState = .signedOut
    }
}
