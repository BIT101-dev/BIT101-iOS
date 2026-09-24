import Foundation
import SwiftUI

extension AppDesignSystem {
    /// 主 App、Widget、Watch 和 Live Activity 共用的 SwiftUI 字体角色。
    enum Typography {
        static let title = Font.headline
        static let titleEmphasis = Font.headline.weight(.bold)
        /// 主体可读内容；跟随当前平台的系统正文基线和动态字体设置。
        static let body = Font.body
        /// 主体内容中的强调文字。
        static let bodyEmphasis = Font.body.weight(.semibold)
        static let subheadline = Font.subheadline
        static let subheadlineEmphasis = Font.subheadline.weight(.semibold)
        static let footnote = Font.footnote
        static let footnoteEmphasis = Font.footnote.weight(.semibold)
        static let caption = Font.caption
        static let captionEmphasis = Font.caption.weight(.semibold)
        static let floatingLabel = Font.system(.body, design: .rounded).weight(.bold)
        static let webBodyCSS = "-apple-system-body"
    }

    /// 主 App、Widget、Watch 和 Live Activity 共用的系统前景层级。
    enum Foreground {
        static let primary = HierarchicalShapeStyle.primary
        static let secondary = HierarchicalShapeStyle.secondary
        static let tertiary = HierarchicalShapeStyle.tertiary
        static let quaternary = HierarchicalShapeStyle.quaternary
        static let quinary = HierarchicalShapeStyle.quinary
    }

    enum External {
        enum Size {
            static let liveActivityTimerWidth: CGFloat = 40
            static let watchEmptyMinimumHeight: CGFloat = 120
        }

        enum Scale {
            static let widgetSmallTitle: CGFloat = 0.75
            static let widgetTitle: CGFloat = 0.82
            static let widgetCircularCount: CGFloat = 0.6
            static let watchCircularBuilding: CGFloat = 0.55
            static let watchCircularRoom: CGFloat = 0.45
            static let watchCornerStatus: CGFloat = 0.5
            static let watchRectangular: CGFloat = 0.7
        }
    }
}
