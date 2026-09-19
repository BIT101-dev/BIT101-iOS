import SwiftUI
import UIKit

/// 课表中的单个课程 / 考试 / 自定义日程块。
struct CourseScheduleBlockView: View {
    let entry: ScheduleCalendarEntry
    let contentMode: ScheduleCardContentMode

    var body: some View {
        ScheduleCardTextView(
            title: entry.title,
            location: entry.subtitle,
            contentMode: contentMode,
            textStyle: AppDesignSystem.Schedule.courseText.style,
            textColor: uiTextColor
        )
        .padding(AppDesignSystem.Spacing.micro)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("双击打开详情")
    }

    private var uiTextColor: UIColor {
        switch entry.kind {
        case .course:
            return .label
        case .exam:
            return UIColor(AppDesignSystem.Palette.highlight)
        case .custom:
            return UIColor(AppDesignSystem.Palette.info)
        }
    }

    private var accessibilityLabel: String {
        let title = entry.title.isEmpty ? "未命名日程" : entry.title
        switch entry.kind {
        case .course:
            return title
        case .exam:
            return "考试，\(title)"
        case .custom:
            return "自定义日程，\(title)"
        }
    }

    private var accessibilityValue: String {
        entry.subtitle.isEmpty ? "" : "地点：\(entry.subtitle)"
    }

}

/// 课表卡片为名称和地点分配独立文字区域。
struct ScheduleCardTextView: UIViewRepresentable {
    let title: String
    let location: String
    let contentMode: ScheduleCardContentMode
    let textStyle: UIFont.TextStyle
    let textColor: UIColor

    func makeUIView(context: Context) -> AdaptiveCardTextView {
        AdaptiveCardTextView()
    }

    func updateUIView(_ uiView: AdaptiveCardTextView, context: Context) {
        uiView.configure(
            title: title,
            location: location,
            contentMode: contentMode,
            font: UIFont.preferredFont(forTextStyle: textStyle),
            textColor: textColor
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: AdaptiveCardTextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    final class AdaptiveCardTextView: UIView {
        private let titleLabel = UILabel()
        private let locationLabel = UILabel()
        private var title = ""
        private var location = ""
        private var scheduleContentMode = ScheduleCardContentMode.nameAndLocation
        private var baseFont = UIFont.preferredFont(forTextStyle: AppDesignSystem.Typography.uiCaption2)

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            isAccessibilityElement = true
            [titleLabel, locationLabel].forEach { label in
                label.textAlignment = .center
                label.adjustsFontForContentSizeCategory = true
                label.adjustsFontSizeToFitWidth = false
                label.allowsDefaultTighteningForTruncation = true
                label.clipsToBounds = true
                addSubview(label)
            }
            titleLabel.lineBreakMode = .byTruncatingTail
            locationLabel.lineBreakMode = .byCharWrapping
            locationLabel.numberOfLines = 0
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(
            title: String,
            location: String,
            contentMode: ScheduleCardContentMode,
            font: UIFont,
            textColor: UIColor
        ) {
            self.title = title
            self.location = location
            scheduleContentMode = contentMode
            baseFont = font
            titleLabel.textColor = textColor
            locationLabel.textColor = textColor
            accessibilityLabel = title.isEmpty ? location : title
            accessibilityValue = title.isEmpty || location.isEmpty ? nil : "地点：\(location)"
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.width > 0, bounds.height > 0 else { return }

            switch scheduleContentMode {
            case .name:
                layoutTitle(text: title, in: bounds)
                hideLocation()
            case .location:
                hideTitle()
                layoutLocation(text: location.isEmpty ? title : location, in: bounds)
            case .nameAndLocation:
                layoutCombined()
            }
        }

        private func layoutCombined() {
            guard !location.isEmpty else {
                layoutTitle(text: title, in: bounds)
                hideLocation()
                return
            }
            guard !title.isEmpty else {
                hideTitle()
                layoutLocation(text: location, in: bounds)
                return
            }

            let gap = AppDesignSystem.Schedule.grid.cellSpacing
            let preferredLocationHeight = measuredHeight(
                text: location,
                font: baseFont,
                width: bounds.width
            )
            let preferredTitleLineHeight = baseFont.lineHeight
            let roomForTitle = bounds.height - preferredLocationHeight - gap
            let locationMaximumHeight = roomForTitle >= preferredTitleLineHeight
                ? preferredLocationHeight
                : bounds.height
            let locationFont = fittingFont(
                text: location,
                width: bounds.width,
                maximumHeight: locationMaximumHeight
            )
            let locationHeight = min(
                measuredHeight(text: location, font: locationFont, width: bounds.width),
                bounds.height
            )
            let titleAvailableHeight = max(bounds.height - locationHeight - gap, 0)
            let titleHeight = layoutTitle(
                text: title,
                in: CGRect(x: 0, y: 0, width: bounds.width, height: titleAvailableHeight)
            )
            let actualGap = titleHeight > 0 ? gap : 0
            let contentHeight = titleHeight + actualGap + locationHeight
            let originY = max((bounds.height - contentHeight) / 2, 0)
            titleLabel.frame.origin.y = originY
            configureLocationLabel(text: location, font: locationFont)
            locationLabel.frame = CGRect(
                x: 0,
                y: originY + titleHeight + actualGap,
                width: bounds.width,
                height: locationHeight
            )
        }

        @discardableResult
        private func layoutTitle(text: String, in rect: CGRect) -> CGFloat {
            guard !text.isEmpty, rect.height >= baseFont.lineHeight else {
                hideTitle()
                return 0
            }
            titleLabel.isHidden = false
            titleLabel.text = text
            titleLabel.font = baseFont
            titleLabel.preferredMaxLayoutWidth = rect.width
            titleLabel.numberOfLines = max(Int(floor(rect.height / baseFont.lineHeight)), 1)
            let measured = titleLabel.sizeThatFits(rect.size)
            let height = min(ceil(measured.height), rect.height)
            titleLabel.frame = CGRect(
                x: rect.minX,
                y: rect.minY + max((rect.height - height) / 2, 0),
                width: rect.width,
                height: height
            )
            return height
        }

        private func layoutLocation(text: String, in rect: CGRect) {
            guard !text.isEmpty else {
                hideLocation()
                return
            }
            let font = fittingFont(text: text, width: rect.width, maximumHeight: rect.height)
            configureLocationLabel(text: text, font: font)
            let height = min(measuredHeight(text: text, font: font, width: rect.width), rect.height)
            locationLabel.frame = CGRect(
                x: rect.minX,
                y: rect.minY + max((rect.height - height) / 2, 0),
                width: rect.width,
                height: height
            )
        }

        private func configureLocationLabel(text: String, font: UIFont) {
            locationLabel.isHidden = false
            locationLabel.text = text
            locationLabel.font = font
            locationLabel.preferredMaxLayoutWidth = bounds.width
        }

        private func fittingFont(text: String, width: CGFloat, maximumHeight: CGFloat) -> UIFont {
            guard maximumHeight > 0 else { return baseFont }
            if measuredHeight(text: text, font: baseFont, width: width) <= maximumHeight {
                return baseFont
            }

            var lowerBound: CGFloat = 1
            var upperBound = baseFont.pointSize
            for _ in 0 ..< 10 {
                let candidateSize = (lowerBound + upperBound) / 2
                let candidate = baseFont.withSize(candidateSize)
                if measuredHeight(text: text, font: candidate, width: width) <= maximumHeight {
                    lowerBound = candidateSize
                } else {
                    upperBound = candidateSize
                }
            }
            return baseFont.withSize(lowerBound)
        }

        private func measuredHeight(text: String, font: UIFont, width: CGFloat) -> CGFloat {
            let rect = (text as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            )
            return ceil(rect.height)
        }

        private func hideTitle() {
            titleLabel.isHidden = true
            titleLabel.frame = .zero
        }

        private func hideLocation() {
            locationLabel.isHidden = true
            locationLabel.frame = .zero
        }
    }
}

struct CourseScheduleBackgroundView: View {
    let entry: ScheduleCalendarEntry
    let showBorder: Bool

    var body: some View {
        AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.badge)
            .fill(backgroundColor)
            .opacity(entry.kind == .course || entry.backgroundLayers.count <= 1 ? 1 : 0.5)
            .overlay {
                if showBorder, entry.kind != .course {
                    AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.badge)
                        .strokeBorder(borderColor, lineWidth: AppDesignSystem.Schedule.grid.courseBorderWidth)
                }
            }
    }

    private var backgroundColor: Color {
        switch entry.kind {
        case .course:
            return AppDesignSystem.Palette.secondaryBackground
        case .exam:
            return AppDesignSystem.Schedule.CoursePalette.examSurface
        case .custom:
            return AppDesignSystem.Schedule.CoursePalette.customSurface
        }
    }

    private var borderColor: Color {
        switch entry.kind {
        case .course:
            return AppDesignSystem.Schedule.GridPalette.courseBorder
        case .exam:
            return AppDesignSystem.Schedule.CoursePalette.examBorder
        case .custom:
            return AppDesignSystem.Schedule.CoursePalette.customBorder
        }
    }
}
