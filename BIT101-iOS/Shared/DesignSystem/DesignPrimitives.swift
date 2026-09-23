import Foundation

/// AppDesignSystem 的跨 target 令牌层。
///
/// 该层保持 Foundation 依赖，让 iOS Widget、watch App 和 watch Widget 共享数值。
nonisolated enum AppDesignSystem {
    enum Primitives {
        enum FontSize {
            static let compact: CGFloat = 10
            static let emphasis: CGFloat = 14
            static let prominent: CGFloat = 16
        }
    }

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
}
