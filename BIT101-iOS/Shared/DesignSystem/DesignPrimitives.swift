import Foundation

/// AppDesignSystem 的跨 target 令牌层。
///
/// 该层保持 Foundation 依赖，让 iOS Widget、watch App 和 watch Widget 共享数值。
nonisolated enum AppDesignSystem {
    enum Spacing {
        static let none: CGFloat = 0
        static let micro: CGFloat = 2
        static let tiny: CGFloat = 4
        static let regular: CGFloat = 8
        static let content: CGFloat = 12
        static let section: CGFloat = 16
    }

    enum Radius {
        static let small: CGFloat = 8
        static let card: CGFloat = 12
        static let grouped: CGFloat = 16
    }

    /// 跨模块共享的透明度基础刻度；语义颜色和模块令牌从这里派生。
    enum Opacity {
        static let full: CGFloat = 1
        static let subtle: CGFloat = 0.12
        static let surface: CGFloat = 0.18
        static let softOverlay: CGFloat = 0.35
        static let overlay: CGFloat = 0.45
        static let controlOverlay: CGFloat = 0.55
        static let emphasis: CGFloat = 0.90
    }
}
