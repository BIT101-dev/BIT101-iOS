import Foundation

/// AppAlert 为业务模块提供页面提示数据。
struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let allowsDiagnostics: Bool
    let showsRecoveryLinks: Bool

    init(
        title: String,
        message: String,
        allowsDiagnostics: Bool = true,
        showsRecoveryLinks: Bool = true
    ) {
        self.title = title
        self.message = message
        self.allowsDiagnostics = allowsDiagnostics
        self.showsRecoveryLinks = allowsDiagnostics && showsRecoveryLinks
    }

    static func userInput(title: String, message: String) -> AppAlert {
        AppAlert(
            title: title,
            message: message,
            allowsDiagnostics: false,
            showsRecoveryLinks: false
        )
    }

    static func informational(title: String, message: String) -> AppAlert {
        AppAlert(
            title: title,
            message: message,
            allowsDiagnostics: false,
            showsRecoveryLinks: false
        )
    }
}
