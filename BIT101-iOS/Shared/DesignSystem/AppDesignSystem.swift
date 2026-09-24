import SwiftUI
import UIKit

/// App 内部 UI 的唯一基础样式来源。
///
/// 业务页面选择语义化的间距、圆角、颜色和卡片变体，公共值由本系统统一定义。
extension AppDesignSystem {

    enum Size {
        enum FloatingAction {
            static let badgeMinimum: CGFloat = 18
        }
        enum Layout {
            static let floatingActionBottomInset: CGFloat = 20
            static let floatingActionContentInset: CGFloat = 84
        }
        enum Control {
            static let detailActionButton: CGFloat = 34
            static let navigationIcon: CGFloat = 24
            static let compact: CGFloat = 28
            static let touchTarget: CGFloat = 44
            static let halfTouchTarget = touchTarget / 2
        }
        enum Editor {
            static let multilineMinimumHeight: CGFloat = 180
        }
        enum Media {
            static let draft: CGFloat = 96
        }
        enum Effect {
            static let blurRadius = Radius.small
        }
        enum CompactRow {
            static let primaryHeight: CGFloat = 22
            static let secondaryHeight: CGFloat = 20
        }
        enum Avatar {
            static let standard: CGFloat = 40
            static let profile: CGFloat = 80
            static let largeIconThreshold: CGFloat = 64
        }
    }

    enum Comment {
        static let replyInset = Size.Avatar.standard + Spacing.regular
        static let bodyLineSpacing: CGFloat = 3
    }

    enum Palette {
        enum Accent {
            static let primary = Color.accentColor
            static let surface = Color.accentColor.opacity(Opacity.surface)
            static let subtleSurface = Color.accentColor.opacity(Opacity.subtle)
        }
        enum Highlight {
            static let primary = Color.orange
            static let surface = Color.orange.opacity(Opacity.subtle)
            static let foreground = Color.white
        }
        enum Status {
            static let danger = Color.red
            static let info = Color.blue
            static let success = Color.green
            static let neutral = Color.gray
        }
        enum Background {
            static let system = Color(uiColor: .systemBackground)
            static let grouped = Color(uiColor: .systemGroupedBackground)
            static let secondary = Color(uiColor: .secondarySystemBackground)
            static let secondaryGrouped = Color(uiColor: .secondarySystemGroupedBackground)
            static let inputPlaceholder = Color(uiColor: .placeholderText)
        }
        enum Border {
            static let subtle = Color(uiColor: .separator)
        }
        enum Media {
            static let overlay = Color.black.opacity(Opacity.overlay)
            static let overlaySoft = Color.black.opacity(Opacity.softOverlay)
            static let foreground = Color.white
            static let controlOverlay = Color.black.opacity(Opacity.controlOverlay)
        }
    }

    @MainActor
    static func roundedRectangle(
        _ radius: CGFloat = Radius.card,
        style: RoundedCornerStyle = .continuous
    ) -> RoundedRectangle {
        return RoundedRectangle(cornerRadius: radius, style: style)
    }
}

/// UIKit 富文本和 UILabel 桥接使用的动态字体样式。
extension AppDesignSystem.Typography {
    static let uiBody = UIFont.TextStyle.body
    static let uiCaption = UIFont.TextStyle.caption1
    static let uiTitle = UIFont.TextStyle.headline
    static let uiSubheadline = UIFont.TextStyle.subheadline
    static let uiFootnote = UIFont.TextStyle.footnote
}

/// UIKit 文字颜色桥接；复杂条件表达式使用这些 Color 值，普通前景通过系统层级样式表达。
extension AppDesignSystem.Foreground {
    static let primaryColor = Color(uiColor: .label)
    static let secondaryColor = Color(uiColor: .secondaryLabel)
}
