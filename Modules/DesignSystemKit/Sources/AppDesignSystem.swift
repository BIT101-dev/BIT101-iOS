#if os(iOS)
import SwiftUI
import UIKit

/// App 内部 UI 的唯一基础样式来源。
///
/// 业务页面选择语义化的间距、圆角、颜色和卡片变体，公共值由本系统统一定义。
extension AppDesignSystem {
    public enum Motion {
        public static func selection(reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : .snappy
        }

        public static func transition(reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : .easeInOut
        }
    }

    public enum Course {
        public static let historyChartHeight: CGFloat = 240
        public static let metricSurfaceOpacity = AppDesignSystem.Opacity.subtle
        public static let historyWarningOpacity = AppDesignSystem.Opacity.emphasis
        public static let accent = Color.pink
        public static let accentSurface = accent.opacity(AppDesignSystem.Opacity.subtle)
    }

    public enum Size {
        public enum FloatingAction {
            public static let badgeMinimum: CGFloat = 18
        }
        public enum Layout {
            public static let floatingActionBottomInset: CGFloat = 20
            public static let floatingActionContentInset: CGFloat = 84
        }
        public enum Control {
            public static let detailActionButton: CGFloat = 34
            public static let navigationIcon: CGFloat = 24
            public static let compact: CGFloat = 28
            public static let touchTarget: CGFloat = 44
            public static let halfTouchTarget = touchTarget / 2
        }
        public enum Editor {
            public static let multilineMinimumHeight: CGFloat = 180
        }
        public enum Media {
            public static let draft: CGFloat = 96
        }
        public enum Effect {
            public static let blurRadius = Radius.small
        }
        public enum CompactRow {
            public static let primaryHeight: CGFloat = 22
            public static let secondaryHeight: CGFloat = 20
        }
        public enum Avatar {
            public static let standard: CGFloat = 40
            public static let profile: CGFloat = 80
            public static let largeIconThreshold: CGFloat = 64
        }
    }

    public enum Comment {
        public static let replyInset = Size.Avatar.standard + Spacing.regular
        public static let bodyLineSpacing: CGFloat = 3
    }

    public enum Palette {
        public enum Accent {
            public static let primary = Color.accentColor
            public static let surface = Color.accentColor.opacity(Opacity.surface)
            public static let subtleSurface = Color.accentColor.opacity(Opacity.subtle)
        }
        public enum Highlight {
            public static let primary = Color.orange
            public static let surface = Color.orange.opacity(Opacity.subtle)
            public static let foreground = Color.white
        }
        public enum Status {
            public static let danger = Color.red
            public static let info = Color.blue
            public static let success = Color.green
            public static let neutral = Color.gray
        }
        public enum Background {
            public static let system = Color(uiColor: .systemBackground)
            public static let grouped = Color(uiColor: .systemGroupedBackground)
            public static let secondary = Color(uiColor: .secondarySystemBackground)
            public static let secondaryGrouped = Color(uiColor: .secondarySystemGroupedBackground)
            public static let inputPlaceholder = Color(uiColor: .placeholderText)
        }
        public enum Border {
            public static let subtle = Color(uiColor: .separator)
        }
        public enum Media {
            public static let overlay = Color.black.opacity(Opacity.overlay)
            public static let overlaySoft = Color.black.opacity(Opacity.softOverlay)
            public static let foreground = Color.white
            public static let controlOverlay = Color.black.opacity(Opacity.controlOverlay)
        }
    }

    @MainActor
    public static func roundedRectangle(
        _ radius: CGFloat = Radius.card,
        style: RoundedCornerStyle = .continuous
    ) -> RoundedRectangle {
        return RoundedRectangle(cornerRadius: radius, style: style)
    }
}

/// UIKit 富文本和 UILabel 桥接使用的动态字体样式。
extension AppDesignSystem.Typography {
    public static let uiBody = UIFont.TextStyle.body
    public static let uiCaption = UIFont.TextStyle.caption1
    public static let uiTitle = UIFont.TextStyle.headline
    public static let uiSubheadline = UIFont.TextStyle.subheadline
    public static let uiFootnote = UIFont.TextStyle.footnote
}

/// UIKit 文字颜色桥接；复杂条件表达式使用这些 Color 值，普通前景通过系统层级样式表达。
extension AppDesignSystem.Foreground {
    public static let primaryColor = Color(uiColor: .label)
    public static let secondaryColor = Color(uiColor: .secondaryLabel)
}
#endif
