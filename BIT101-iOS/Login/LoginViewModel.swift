//
//  LoginViewModel.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Combine
import Foundation

/// 登录页当前展示的顶层状态。
///
/// 登录模块不直接暴露大量布尔值，而是收敛成“已登录 / 未登录”两种外层场景。
/// 这样根视图切换更直观，也避免多个布尔值组合出无意义状态。
enum LoginScreenState: Equatable {
    case signedOut
    case signedIn(studentID: String)
}

/// 登录页统一使用的警告模型。
///
/// 登录模块所有错误提示都经由这个模型统一上抛给视图层，避免 ViewModel 直接依赖
/// 某种具体 Alert 组件。
/// 登录流程状态机。
///
/// 负责：
/// 1. 启动时恢复本地登录态
/// 2. 驱动登录按钮的提交状态
/// 3. 管理退出登录后的界面回退
final class LoginViewModel: ObservableObject {
    /// 学号输入框内容。
    @Published var studentID: String
    /// 密码输入框内容。
    @Published var password = ""
    /// 登录模块当前处于登录页还是主壳层。
    @Published private(set) var screenState: LoginScreenState
    /// 是否正在执行登录请求。
    @Published private(set) var isSubmitting = false
    /// 当前待展示的提示弹窗。
    @Published var alert: AppAlert?

    private let service: any LoginServicing
    /// 避免启动校验在视图重建时重复触发。
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
    /// 这里只校验最基础的非空条件；真正的网络校验和密码正确性由提交时处理。
    var canSubmit: Bool {
        !studentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !password.isEmpty &&
            !isSubmitting
    }

    /// 只在首次进入时检查一次登录态，避免视图重建时重复发请求。
    ///
    /// 本地有会话时不阻塞首屏；只有远端明确返回未登录才切到登录页。
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
            studentID = service.savedStudentID
            password = service.savedPassword

            // 网络、超时或解析等临时错误必须静默保留主界面，避免断网被误判为退出登录。
            if service.hasCachedSession, !studentID.isEmpty {
                screenState = .signedIn(studentID: studentID)
            } else {
                screenState = .signedOut
            }
        }
    }

    /// 执行一次显式登录。
    ///
    /// 登录成功后会清空内存中的密码文本，但底层 `LoginStorage` 仍会保存凭据，
    /// 以便后续静默重登学校 SSO。
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
            alert = AppAlert(
                title: "登录失败",
                message: error.localizedDescription
            )
            screenState = .signedOut
        }
    }

    /// 退出当前账号，并回退到登录页。
    ///
    /// 退出动作只清会话，不清账号密码，因此登录页会保留最近一次输入的学号。
    func logout() {
        service.logout()
        studentID = service.savedStudentID
        password = service.savedPassword
        screenState = .signedOut
    }
}
