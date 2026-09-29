import Foundation

/// AppDesignSystem 的跨 target 令牌层。
///
/// 该层保持 Foundation 依赖，让 iOS Widget、watch App 和 watch Widget 共享数值。
public nonisolated enum AppDesignSystem {
    public enum Spacing {
        public static let none: CGFloat = 0
        public static let micro: CGFloat = 2
        public static let tiny: CGFloat = 4
        public static let regular: CGFloat = 8
        public static let content: CGFloat = 12
        public static let section: CGFloat = 16
    }

    public enum Radius {
        public static let small: CGFloat = 8
        public static let card: CGFloat = 12
        public static let grouped: CGFloat = 16
    }

    /// 跨模块共享的透明度基础刻度；语义颜色和模块令牌从这里派生。
    public enum Opacity {
        public static let full: CGFloat = 1
        public static let subtle: CGFloat = 0.12
        public static let surface: CGFloat = 0.18
        public static let softOverlay: CGFloat = 0.35
        public static let overlay: CGFloat = 0.45
        public static let controlOverlay: CGFloat = 0.55
        public static let emphasis: CGFloat = 0.90
    }
}
