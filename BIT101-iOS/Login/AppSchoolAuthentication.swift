import ClientCore
import Foundation
import ScheduleInfrastructure
import TransportCore
import UIKit

/// 学校功能共用本机 Cookie 容器、CAS 凭据和短信续接。
enum AppNativeSchoolAuthentication {
    static let shared = make()

    static func make(state: TeachingCenterSessionState = AppSchoolSession.teachingCenter,
        productionPolicy: Bool = false) -> NativeSchoolAuthenticator {
        let manual = NetworkSessionPool.schoolCASTransport(state: state, followsRedirects: false, productionPolicy: productionPolicy)
        let api = BIT101APIClient(httpClient: HTTPClient(transport: NetworkSessionPool.schoolCASTransport(
            state: state, followsRedirects: true, productionPolicy: productionPolicy)), noRedirectHTTPClient: HTTPClient(transport: manual))
        let restorer = AppScheduleSchoolSessionRestorer(restore: {
            do { return try await LoginService(storage: AppAccountSession.storage, apiClient: api).restoreSchoolSessionIfNeeded() }
            catch let error as LoginServiceError {
                switch error {
                case .schoolLoginFailed, .invalidSchoolLoginPage, .invalidServerResponse:
                    throw NativeSchoolAuthenticationError.invalidResponse
                default: throw error
                }
            }
        })
        let smsService = ScheduleService(credentials: AppAccountSession.storage, crypto: AppScheduleServiceCrypto(),
            schoolSessionRestorer: restorer, teachingCenterState: state,
            transport: NetworkSessionPool.teachingCenter(state: state, productionPolicy: productionPolicy), observer: HTTPClient.appObserver)
        let secondFactor: (SchoolSecondFactorContext) async throws -> Void = { context in
            try await smsService.completeSchoolAuthentication(context) {
                try await SchoolSMSPrompt.shared.requestCode($0)
            }
        }
        return NativeSchoolAuthenticator(credentials: AppAccountSession.storage, restorer: restorer,
            client: HTTPClient(transport: manual), cookies: { state.cookieStorage }, secondFactor: secondFactor,
            serviceLogin: { url, html in
                do {
                    return try await api.submitSchoolServiceLogin(url: url, html: html, storage: AppAccountSession.storage,
                        cookieStorage: state.cookieStorage)
                } catch LoginServiceError.schoolSMSRequired(let context) {
                    try await secondFactor(context)
                    return url
                }
            })
    }

}

@MainActor
final class SchoolSMSPrompt {
    static let shared = SchoolSMSPrompt()
    private var active: (id: UUID, alert: UIAlertController, continuation: CheckedContinuation<String, Error>)?

    func requestCode(_ request: SchoolSMSCodeRequest) async throws -> String {
        try Task.checkCancellation()
        let id = request.id
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard active == nil, let controller = AppErrorPresenter.topViewController() else {
                    continuation.resume(throwing: NativeSchoolAuthenticationError.additionalVerification)
                    return
                }
                let alert = UIAlertController(title: "学校短信验证", message: "验证码已发送至 \(request.maskedPhone)", preferredStyle: .alert)
                alert.addTextField { field in
                    field.placeholder = "短信验证码"
                    field.keyboardType = .numberPad
                    field.textContentType = .oneTimeCode
                    field.accessibilityIdentifier = "school.sms.code"
                }
                alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
                    self?.finish(id, .failure(CancellationError()))
                })
                let submit = UIAlertAction(title: "验证并继续", style: .default) { [weak self, weak alert] _ in
                    self?.finish(id, .success(alert?.textFields?.first?.text ?? ""))
                }
                submit.isEnabled = false
                alert.addAction(submit)
                alert.preferredAction = submit
                alert.textFields?.first?.addAction(UIAction { [weak alert, weak submit] _ in
                    submit?.isEnabled = alert?.textFields?.first?.text?.isEmpty == false
                }, for: .editingChanged)
                active = (id, alert, continuation)
                controller.present(alert, animated: true)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, .failure(CancellationError())) }
        }
    }

    private func finish(_ id: UUID, _ result: Result<String, Error>) {
        guard let current = active, current.id == id else { return }
        active = nil
        current.alert.textFields?.first?.text = ""
        current.alert.dismiss(animated: true) { current.continuation.resume(with: result) }
    }
}
