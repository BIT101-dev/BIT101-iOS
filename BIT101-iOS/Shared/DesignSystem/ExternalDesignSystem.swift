import Foundation
import SwiftUI

extension AppDesignSystem {
    enum External {
        enum Typography {
            static let title = Font.headline
            static let titleEmphasis = Font.headline.weight(.semibold)
            static let titleMonospaced = Font.headline.monospacedDigit()
            static let body = Font.body
            static let bodyEmphasis = Font.body.weight(.semibold)
            static let subheadline = Font.subheadline
            static let subheadlineEmphasis = Font.subheadline.weight(.semibold)
            static let footnote = Font.footnote
            static let footnoteEmphasis = Font.footnote.weight(.semibold)
            static let caption = Font.caption
            static let captionEmphasis = Font.caption.weight(.semibold)
        }

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
