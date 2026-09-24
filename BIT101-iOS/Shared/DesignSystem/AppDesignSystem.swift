import SwiftUI
import UIKit

/// App 内部 UI 的唯一基础样式来源。
///
/// 业务页面选择语义化的间距、圆角、颜色和卡片变体，公共值由本系统统一定义。
extension AppDesignSystem {

    enum Size {
        enum FloatingAction {
            static let badgeMinimum: CGFloat = 18
            static let bottomInset: CGFloat = 20
            static let contentInset: CGFloat = 84
        }
        enum Control {
            static let detailActionButton: CGFloat = 34
            static let navigationIcon: CGFloat = 24
            static let compact: CGFloat = 28
            static let touchTarget: CGFloat = 44
            static let halfTouchTarget = touchTarget / 2
        }
        enum Content {
            static let multilineEditorMinimumHeight: CGFloat = 180
            static let imageDraft: CGFloat = 96
        }
        enum CompactRow {
            static let primaryHeight: CGFloat = 22
            static let secondaryHeight: CGFloat = 20
        }
        enum Avatar {
            static let standard: CGFloat = 40
            static let profile: CGFloat = 80
            static let placeholderOpacity: CGFloat = 0.15
            static let largeIconThreshold: CGFloat = 64
        }
    }

    enum Typography {
        static let title = Font.headline
        static let titleEmphasis = Font.headline.weight(.bold)
        static let titleMonospaced = Font.headline.monospacedDigit()
        /// 主体可读内容；跟随当前平台的系统正文基线和动态字体设置。
        static let body = Font.body
        /// 主体内容中的强调文字。
        static let bodyEmphasis = Font.body.weight(.semibold)
        static let bodyMonospaced = Font.system(.body, design: .monospaced)
        static let subheadline = Font.subheadline
        static let subheadlineEmphasis = Font.subheadline.weight(.semibold)
        static let footnote = Font.footnote
        static let footnoteEmphasis = Font.footnote.weight(.semibold)
        static let footnoteMonospaced = Font.system(.footnote, design: .monospaced)
        static let caption = Font.caption
        static let captionEmphasis = Font.caption.weight(.semibold)
        static let uiBody = UIFont.TextStyle.body
        static let uiCaption = UIFont.TextStyle.caption1
        static let uiTitle = UIFont.TextStyle.headline
        static let uiSubheadline = UIFont.TextStyle.subheadline
        static let uiFootnote = UIFont.TextStyle.footnote
        static let floatingIcon = Font.body.weight(.semibold)
        static let floatingLabel = Font.system(.body, design: .rounded).weight(.bold)
        static let webBodyCSS = "-apple-system-body"
    }

    enum Comment {
        static let replyInset = Size.Avatar.standard + Spacing.regular
    }

    enum Palette {
        static let accent = Color.accentColor
        static let accentSurface = Color.accentColor.opacity(0.14)
        static let accentSubtleSurface = Color.accentColor.opacity(0.08)
        static let highlight = Color.orange
        static let highlightSurface = Color.orange.opacity(0.12)
        static let highlightForeground = Color.white
        static let danger = Color.red
        static let info = Color.blue
        static let success = Color.green
        static let neutral = Color.gray
        static let scheduleTab = Color.indigo
        static let mapTab = Color.green
        static let scoreTab = Color.pink
        static let systemBackground = Color(uiColor: .systemBackground)
        static let groupedBackground = Color(uiColor: .systemGroupedBackground)
        static let secondaryBackground = Color(uiColor: .secondarySystemBackground)
        static let secondaryGroupedBackground = Color(uiColor: .secondarySystemGroupedBackground)
        static let inputPlaceholder = Color(uiColor: .placeholderText)
        static let subtleBorder = Color.primary.opacity(0.06)
        static let mediaOverlay = Color.black.opacity(0.45)
        static let mediaOverlayStrong = Color.black.opacity(0.35)
    }

    @MainActor
    static func roundedRectangle(
        _ radius: CGFloat = Radius.card,
        style: RoundedCornerStyle = .continuous
    ) -> RoundedRectangle {
        return RoundedRectangle(cornerRadius: radius, style: style)
    }
}
