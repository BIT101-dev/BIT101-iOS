import Foundation
#if os(iOS)
import SwiftUI
#endif

public nonisolated protocol DiagnosticAlertPresentable: Identifiable {
    var title: String { get }
    var message: String { get }
    var allowsDiagnostics: Bool { get }
    var showsRecoveryLinks: Bool { get }
    var recoveryAction: AppRecoveryAction? { get }
    var underlyingError: (any Error)? { get }
}

public extension DiagnosticAlertPresentable {
    var underlyingError: (any Error)? { nil }
}

public nonisolated enum AppRecoveryAction: Equatable, Sendable {
    case openAppSettings

    public var title: String {
        switch self {
        case .openAppSettings: "打开系统设置"
        }
    }
}

/// AppAlert 为业务模块提供页面提示数据。
public nonisolated struct AppAlert: DiagnosticAlertPresentable {
    public let id = UUID()
    public let title: String
    public let message: String
    public let allowsDiagnostics: Bool
    public let showsRecoveryLinks: Bool
    public let recoveryAction: AppRecoveryAction?
    public let underlyingError: (any Error)?

    public init(
        title: String,
        message: String,
        recoveryAction: AppRecoveryAction? = nil,
        allowsDiagnostics: Bool = true,
        showsRecoveryLinks: Bool = true,
        underlyingError: (any Error)? = nil
    ) {
        self.title = title
        self.message = message
        self.recoveryAction = recoveryAction
        self.underlyingError = underlyingError
        self.allowsDiagnostics = allowsDiagnostics
        self.showsRecoveryLinks = allowsDiagnostics && showsRecoveryLinks
    }

    public init(title: String, error: any Error) {
        self.init(title: title, message: error.localizedDescription, underlyingError: error)
    }

    public static func userInput(title: String, message: String, recoveryAction: AppRecoveryAction? = nil,
        underlyingError: (any Error)? = nil) -> AppAlert {
        AppAlert(
            title: title,
            message: message,
            recoveryAction: recoveryAction,
            allowsDiagnostics: false,
            showsRecoveryLinks: false,
            underlyingError: underlyingError
        )
    }

    public static func informational(title: String, message: String) -> AppAlert {
        AppAlert(
            title: title,
            message: message,
            allowsDiagnostics: false,
            showsRecoveryLinks: false
        )
    }
}

#if os(iOS)
public typealias AppDiagnosticAlertHandler = @MainActor (any DiagnosticAlertPresentable) -> Void

private struct AppDiagnosticAlertKey: EnvironmentKey {
    static let defaultValue: AppDiagnosticAlertHandler? = nil
}

extension EnvironmentValues {
    public var appDiagnosticAlert: AppDiagnosticAlertHandler? {
        get { self[AppDiagnosticAlertKey.self] }
        set { self[AppDiagnosticAlertKey.self] = newValue }
    }
}

private struct DiagnosticAlertModifier<Item: DiagnosticAlertPresentable>: ViewModifier {
    @Binding var item: Item?
    @Environment(\.appDiagnosticAlert) private var present

    func body(content: Content) -> some View {
        content
            .onAppear(perform: forwardIfNeeded)
            .onChange(of: item?.id) { _, _ in forwardIfNeeded() }
    }

    private func forwardIfNeeded() {
        guard let alert = item, let present else { return }
        item = nil
        present(alert)
    }
}

extension View {
    public func diagnosticAlert<Item: DiagnosticAlertPresentable>(item: Binding<Item?>) -> some View {
        modifier(DiagnosticAlertModifier(item: item))
    }
}
#endif
