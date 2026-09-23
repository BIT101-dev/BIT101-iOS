import SwiftUI

extension AppDesignSystem {
    enum Schedule {
        static func refreshStatusRowHeight(contentHeight: CGFloat) -> CGFloat {
            max(contentHeight, AppDesignSystem.Size.Control.touchTarget)
                + 2 * AppDesignSystem.Spacing.tiny
        }

        static let ddlNumericPickerHeight: CGFloat = 240
        enum GridPalette {
            static let majorLine = Color.secondary.opacity(0.18)
            static let minorLine = Color.secondary.opacity(0.12)
            static let courseBorder = Color.secondary.opacity(0.25)
            static let weekBar = Color.secondary.opacity(0.55)
            static let todayHighlight = AppDesignSystem.Palette.accent.opacity(0.10)
        }

        enum CoursePalette {
            static let examSurface = AppDesignSystem.Palette.highlight.opacity(0.22)
            static let customSurface = AppDesignSystem.Palette.info.opacity(0.18)
            static let examBorder = AppDesignSystem.Palette.highlight.opacity(0.35)
            static let customBorder = AppDesignSystem.Palette.info.opacity(0.30)
        }

        enum Grid {
            static let lineWidth: CGFloat = 0.5
            static let cellSpacing: CGFloat = 1
            static let currentTimeLineHeight: CGFloat = 1.5
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
            static let sliderHeight: CGFloat = 36
            static let dateHeaderHeight: CGFloat = 26
            static let compactHeaderHeight: CGFloat = 42
        }
        static let timelineDefaultScale: CGFloat = CGFloat(24) / CGFloat(13)
        static let timelineMinimumScale: CGFloat = 1
        static let timelineMaximumScale: CGFloat = 3
        static let settingsPanelMinimumHeight: CGFloat = 220
    }
}
