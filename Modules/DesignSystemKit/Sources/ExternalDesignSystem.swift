import Foundation
import SwiftUI

extension AppDesignSystem {
    /// 主 App、Widget、Watch 和 Live Activity 共用的 SwiftUI 字体角色。
    public enum Typography {
        public static let title = Font.headline
        public static let titleEmphasis = Font.headline.weight(.bold)
        /// 主体可读内容；跟随当前平台的系统正文基线和动态字体设置。
        public static let body = Font.body
        /// 主体内容中的强调文字。
        public static let bodyEmphasis = Font.body.weight(.semibold)
        public static let subheadline = Font.subheadline
        public static let subheadlineEmphasis = Font.subheadline.weight(.semibold)
        public static let footnote = Font.footnote
        public static let footnoteEmphasis = Font.footnote.weight(.semibold)
        public static let caption = Font.caption
        public static let captionEmphasis = Font.caption.weight(.semibold)
        public static let floatingLabel = Font.system(.body, design: .rounded).weight(.bold)
        public static let webBodyCSS = "-apple-system-body"
    }

    /// 主 App、Widget、Watch 和 Live Activity 共用的系统前景层级。
    public enum Foreground {
        public static let primary = HierarchicalShapeStyle.primary
        public static let secondary = HierarchicalShapeStyle.secondary
        public static let tertiary = HierarchicalShapeStyle.tertiary
        public static let quaternary = HierarchicalShapeStyle.quaternary
        public static let quinary = HierarchicalShapeStyle.quinary
    }

    public enum External {
        public enum Size {
            public static let liveActivityTimerWidth: CGFloat = 40
            public static let watchEmptyMinimumHeight: CGFloat = 120
        }

        public enum Scale {
            public static let widgetSmallTitle: CGFloat = 0.75
            public static let widgetTitle: CGFloat = 0.82
            public static let widgetCircularCount: CGFloat = 0.6
            public static let watchCircularBuilding: CGFloat = 0.55
            public static let watchCircularRoom: CGFloat = 0.45
            public static let watchCornerStatus: CGFloat = 0.5
            public static let watchRectangular: CGFloat = 0.7
        }
    }
}
