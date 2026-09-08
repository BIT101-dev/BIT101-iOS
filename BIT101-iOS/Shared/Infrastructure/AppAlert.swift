import Foundation

/// AppAlert 为业务模块提供页面提示数据。
struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
