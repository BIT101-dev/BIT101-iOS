import ClientCore
import Foundation
import ScheduleInfrastructure
import SchedulePorts
import TransportCore
import UIKit
import SwiftUI
import DesignSystemKit

struct SchoolIdentityVerification {
    let studentID: String
    let activateSession: () -> Void
}

/// 学校功能共用本机 Cookie 容器、CAS 凭据和短信续接。
enum AppNativeSchoolAuthentication {
    static let shared = make()
#if RELEASE_NETWORK_SMOKE
    static var smokeSMSCodeHandler: SchoolSMSCodeHandler?
#endif

    static func make(state: TeachingCenterSessionState = AppSchoolSession.teachingCenter,
        productionPolicy: Bool = false) -> NativeSchoolAuthenticator {
        let manual = NetworkSessionPool.schoolCASTransport(state: state, followsRedirects: false, productionPolicy: productionPolicy)
        let api = BIT101APIClient(httpClient: HTTPClient(transport: NetworkSessionPool.schoolCASTransport(
            state: state, followsRedirects: true, productionPolicy: productionPolicy)), noRedirectHTTPClient: HTTPClient(transport: manual),
            schoolCookieStorage: state.cookieStorage)
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
        return authenticator(state: state, credentials: AppAccountSession.storage, restorer: restorer, api: api,
            client: HTTPClient(transport: manual), smsTransport: NetworkSessionPool.teachingCenter(state: state, productionPolicy: productionPolicy),
            acceptingServiceTicket: false, updateCredentials: { try await AppAccountSession.storage.updateSchoolCredentials() })
    }

    static func verifyIdentity(studentID: String, password: String) async throws -> SchoolIdentityVerification {
        let state = AppSchoolSession.isolatedState()
        return try await verifyIdentity(studentID: studentID, password: password, state: state,
            transport: NetworkSessionPool.schoolCASTransport(state: state, followsRedirects: false), activateSession: { cookies in
                for cookie in cookies { AppSchoolSession.teachingCenter.cookieStorage.setCookie(cookie) }
            })
    }

    static func verifyIdentity(studentID: String, password: String, state: TeachingCenterSessionState,
        transport: any HTTPTransport, activateSession: @escaping ([HTTPCookie]) -> Void) async throws -> SchoolIdentityVerification {
        let credentials = IdentityCredentials(currentStudentID: studentID, currentPassword: password)
        let client = HTTPClient(transport: transport)
        let api = BIT101APIClient(httpClient: client, noRedirectHTTPClient: client, schoolCookieStorage: state.cookieStorage)
        let restorer = AppScheduleSchoolSessionRestorer(restore: { throw NativeSchoolAuthenticationError.additionalVerification })
        let authentication = authenticator(state: state, credentials: credentials, restorer: restorer, api: api,
            client: client, smsTransport: transport, acceptingServiceTicket: true,
            updateCredentials: { throw LoginServiceError.schoolPasswordRejected })
        try await authentication.verifyIdentity()
        let cookies = state.cookieStorage.cookies(for: AppURL.required("https://sso.bit.edu.cn")) ?? []
        return SchoolIdentityVerification(studentID: studentID, activateSession: { activateSession(cookies) })
    }

    private struct IdentityCredentials: SchoolCredentialsProviding {
        let currentStudentID: String
        let currentPassword: String
        var schoolSessionIdentity: SchoolSessionIdentity { .init(accountIdentifier: currentStudentID, generation: 0) }
    }

    private static func authenticator(state: TeachingCenterSessionState, credentials: any SchoolCredentialsProviding,
        restorer: AppScheduleSchoolSessionRestorer, api: BIT101APIClient, client: HTTPClient,
        smsTransport: any HTTPTransport, acceptingServiceTicket: Bool,
        updateCredentials: @escaping () async throws -> Void) -> NativeSchoolAuthenticator {
        let smsService = ScheduleService(credentials: credentials, crypto: AppScheduleServiceCrypto(),
            schoolSessionRestorer: restorer, teachingCenterState: state,
            transport: smsTransport, observer: HTTPClient.appObserver)
        let secondFactor: (SchoolSecondFactorContext) async throws -> Void = { context in
#if RELEASE_NETWORK_SMOKE
            guard let handler = Self.smokeSMSCodeHandler else { throw ScheduleServiceError.schoolSecondFactorRequired }
#else
            let handler: SchoolSMSCodeHandler = { try await SchoolSMSPrompt.shared.requestCode($0) }
#endif
            try await smsService.completeSchoolAuthentication(context, acceptingServiceTicket: acceptingServiceTicket, handler: handler)
        }
        return NativeSchoolAuthenticator(credentials: credentials, restorer: restorer,
            client: client, cookies: { state.cookieStorage }, secondFactor: secondFactor,
            serviceLogin: { url, html in
                do {
                    return try await api.submitSchoolServiceLogin(url: url, html: html, credentials: credentials,
                        cookieStorage: state.cookieStorage, updateCredentials: updateCredentials)
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
    private let presenter: @MainActor () -> UIViewController?
    private var active: (id: UUID, controller: UIViewController, continuation: CheckedContinuation<String, Error>)?

    init(presenter: @escaping @MainActor () -> UIViewController? = AppErrorPresenter.topViewController) {
        self.presenter = presenter
    }

    func requestCode(_ request: SchoolSMSCodeRequest) async throws -> String {
        try Task.checkCancellation()
        let controller = try await AppErrorPresenter.availableViewController(using: presenter)
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard active == nil, let controller else {
                    continuation.resume(throwing: NativeSchoolAuthenticationError.additionalVerification)
                    return
                }
                let sheet = UIHostingController(rootView: AppSchoolSMSVerificationSheet(
                    maskedPhone: request.maskedPhone,
                    onCancel: { [weak self] in self?.finish(id, .failure(CancellationError())) },
                    onSubmit: { [weak self] code in self?.finish(id, .success(code)) }
                ).appReadableContent().appWindowLayout())
                sheet.isModalInPresentation = true
                active = (id, sheet, continuation)
                controller.present(sheet, animated: true)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, .failure(CancellationError())) }
        }
    }

    private func finish(_ id: UUID, _ result: Result<String, Error>) {
        guard let current = active, current.id == id else { return }
        active = nil
        current.controller.view.endEditing(true)
        current.controller.dismiss(animated: true) { current.continuation.resume(with: result) }
    }
}
