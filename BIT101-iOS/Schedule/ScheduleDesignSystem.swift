import DesignSystemKit
import SwiftUI

extension AppDesignSystem {
    enum Schedule {
        static let tabAccent = Color.indigo

        static func refreshStatusRowHeight(contentHeight: CGFloat) -> CGFloat {
            max(contentHeight, AppDesignSystem.Size.Control.touchTarget)
                + 2 * AppDesignSystem.Spacing.tiny
        }

        static let ddlNumericPickerHeight: CGFloat = 240
        static let reminderDisabledOpacity = AppDesignSystem.Opacity.overlay
        enum GridPalette {
            static let majorLine = AppDesignSystem.Foreground.secondaryColor.opacity(AppDesignSystem.Opacity.surface)
            static let minorLine = AppDesignSystem.Foreground.secondaryColor.opacity(AppDesignSystem.Opacity.subtle)
            static let courseBorder = AppDesignSystem.Foreground.secondaryColor.opacity(AppDesignSystem.Opacity.softOverlay)
            static let weekBar = AppDesignSystem.Foreground.secondaryColor.opacity(AppDesignSystem.Opacity.controlOverlay)
            static let todayHighlight = AppDesignSystem.Palette.Accent.primary.opacity(AppDesignSystem.Opacity.subtle)
        }

        enum CoursePalette {
            static let examSurface = AppDesignSystem.Palette.Highlight.primary.opacity(AppDesignSystem.Opacity.surface)
            static let customSurface = AppDesignSystem.Palette.Status.info.opacity(AppDesignSystem.Opacity.surface)
            static let examBorder = AppDesignSystem.Palette.Highlight.primary.opacity(AppDesignSystem.Opacity.softOverlay)
            static let customBorder = AppDesignSystem.Palette.Status.info.opacity(AppDesignSystem.Opacity.softOverlay)
            static let secondaryLayerOpacity = AppDesignSystem.Opacity.controlOverlay
        }

        enum Grid {
            static let lineWidth: CGFloat = 0.5
            static let cellSpacing: CGFloat = 1
            static let currentTimeLineHeight: CGFloat = 1.5
            static let minimumScaleFactor: CGFloat = 0.8
            static let previewTriggerSize: CGFloat = 1
            static let lineOffset: CGFloat = 0.25
            static let courseCardTotalInset: CGFloat = 1
            static let courseBorderWidth: CGFloat = 1
        }
        enum WeekSlider {
            static let itemSpacing: CGFloat = 5
            static let itemWidth: CGFloat = 24
            static let itemHeight: CGFloat = 34
            static let labelHeight: CGFloat = 13
            static let barHeight: CGFloat = 20
            static let minorBarHeight: CGFloat = 16
            static let selectedBarWidth: CGFloat = 4
            static let barWidth: CGFloat = 3
            static let sliderHeight: CGFloat = AppDesignSystem.Size.Control.touchTarget
            static let dateHeaderHeight: CGFloat = 26
            static let compactHeaderHeight: CGFloat = 42
        }
        static let timelineDefaultScale: CGFloat = CGFloat(24) / CGFloat(13)
        static let timelineMinimumScale: CGFloat = 1
        static let timelineMaximumScale: CGFloat = 3
        static let settingsPanelMinimumHeight: CGFloat = 220
    }
}
