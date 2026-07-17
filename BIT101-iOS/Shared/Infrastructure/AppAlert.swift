import Foundation

/// 业务模块共享的轻量页面提示模型。
struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
