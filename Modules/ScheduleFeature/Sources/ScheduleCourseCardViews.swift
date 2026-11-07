#if os(iOS)
import ScheduleDomain
import DesignSystemKit
import SwiftUI
import UIKit

/// 课表卡片为名称和地点分配独立文字区域。
final class ScheduleCardTextView: UIView {
    private let titleLabel = UILabel()
    private let locationLabel = UILabel()
    private var title = ""
    private var location = ""
    private var scheduleContentMode = ScheduleCardContentMode.nameAndLocation
    private var baseFont = UIFont.preferredFont(
        forTextStyle: AppDesignSystem.Typography.uiCaption)
    private var laidOutSize: CGSize?
    private var laidOutScale: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isOpaque = false
        isAccessibilityElement = false
        [titleLabel, locationLabel].forEach { label in
            label.textAlignment = .center
            label.adjustsFontForContentSizeCategory = true
            label.adjustsFontSizeToFitWidth = false
            label.allowsDefaultTighteningForTruncation = true
            label.clipsToBounds = true
            addSubview(label)
        }
        titleLabel.lineBreakMode = .byTruncatingTail
        locationLabel.lineBreakMode = .byTruncatingTail
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
        if titleLabel.textColor != textColor {
            titleLabel.textColor = textColor
            locationLabel.textColor = textColor
        }
        guard self.title != title || self.location != location
            || scheduleContentMode != contentMode || baseFont != font
        else { return }
        self.title = title
        self.location = location
        scheduleContentMode = contentMode
        baseFont = font
        accessibilityLabel = title.isEmpty ? location : title
        accessibilityValue = title.isEmpty || location.isEmpty ? nil : "地点：\(location)"
        laidOutSize = nil
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard laidOutSize != bounds.size || laidOutScale != contentScaleFactor else { return }
        laidOutSize = bounds.size
        laidOutScale = contentScaleFactor

        switch scheduleContentMode {
        case .name:
            layoutTitle(text: title, in: bounds)
            hideLocation()
        case .location:
            hideTitle()
            layoutLocation(
                text: location.isEmpty ? title : location,
                in: bounds,
                verticallyCentered: true
            )
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

        let gap = AppDesignSystem.Schedule.Grid.cellSpacing
        let locationHeight = min(
            measuredHeight(text: location, font: baseFont, width: bounds.width),
            bounds.height
        )
        let titleAvailableHeight = max(bounds.height - locationHeight - gap, 0)
        if titleAvailableHeight >= baseFont.lineHeight {
            layoutTitle(
                text: title,
                in: CGRect(x: 0, y: 0, width: bounds.width, height: titleAvailableHeight))
        } else {
            hideTitle()
        }
        layoutLocation(
            text: location,
            in: CGRect(
                x: 0, y: bounds.height - locationHeight, width: bounds.width,
                height: locationHeight))
    }

    @discardableResult
    private func layoutTitle(text: String, in rect: CGRect) -> CGFloat {
        guard !text.isEmpty, rect.height > 0 else {
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

    private func layoutLocation(
        text: String,
        in rect: CGRect,
        verticallyCentered: Bool = false
    ) {
        guard !text.isEmpty, rect.height > 0 else {
            hideLocation()
            return
        }
        locationLabel.textAlignment = .center
        let naturalHeight = measuredHeight(text: text, font: baseFont, width: rect.width)
        var font = baseFont
        if naturalHeight > rect.height {
            var lower = baseFont.pointSize * rect.height / naturalHeight
            var upper = baseFont.pointSize
            while upper - lower > 1 / contentScaleFactor {
                let size = (lower + upper) / 2
                if measuredHeight(text: text, font: baseFont.withSize(size), width: rect.width)
                    <= rect.height {
                    lower = size
                } else {
                    upper = size
                }
            }
            font = baseFont.withSize(lower)
        }
        let height = min(measuredHeight(text: text, font: font, width: rect.width), rect.height)
        configureLocationLabel(text: text, height: height, font: font)
        locationLabel.frame = CGRect(
            x: rect.minX,
            y: verticallyCentered
                ? rect.minY + max((rect.height - height) / 2, 0)
                : rect.maxY - height,
            width: rect.width,
            height: height
        )
    }

    private func configureLocationLabel(text: String, height: CGFloat, font: UIFont) {
        locationLabel.isHidden = false
        locationLabel.text = text
        locationLabel.font = font
        locationLabel.numberOfLines = max(Int(floor(height / font.lineHeight)), 1)
        locationLabel.preferredMaxLayoutWidth = bounds.width
    }

    private func measuredHeight(text: String, font: UIFont, width: CGFloat) -> CGFloat {
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font], context: nil)
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

struct ScheduleCalendarCard {
    let entry: ScheduleCalendarEntry
    let frame: CGRect
    let backgrounds: [CGRect]
    var zIndex: Double = 1
}

/// 整个日历只使用一个 UIKit 桥接，按条目身份复用文字和交互控件。
struct ScheduleCalendarCardsView: UIViewRepresentable {
    @Environment(\.appInteractionEvidence) private var interactionEvidence
    let cards: [ScheduleCalendarCard]
    let contentMode: ScheduleCardContentMode
    let onSelect: (ScheduleCalendarEntry) -> Void
    let onMenuWillPresent: (ScheduleCalendarEntry) -> Void
    let onShare: (ScheduleCalendarEntry) -> Void

    func makeUIView(context: Context) -> ScheduleCalendarCardsControl {
        ScheduleCalendarCardsControl()
    }

    func updateUIView(_ view: ScheduleCalendarCardsControl, context: Context) {
        let onSelect = onSelect
        let onMenuWillPresent = onMenuWillPresent
        let onShare = onShare
        let interactionEvidence = interactionEvidence
        view.update(cards: cards) { control, card in
            let entry = card.entry
            control.configure(
                entry: entry, contentMode: contentMode, onTap: { onSelect(entry) },
                onMenuWillPresent: entry.kind == .course ? { onMenuWillPresent(entry) } : nil,
                onShare: entry.kind == .course ? { onShare(entry) } : nil,
                interactionEvidence: interactionEvidence)
            control.configureBackgrounds(card.backgrounds, entry: entry)
        }
    }
}

final class ScheduleCalendarCardsControl: UIView {
    private var controls: [String: ScheduleBlankContextMenuControl] = [:]
    private var orderedIDs: [String] = []

    func update(
        cards: [ScheduleCalendarCard],
        configure: (ScheduleBlankContextMenuControl, ScheduleCalendarCard) -> Void
    ) {
        let ids = Set(cards.map { $0.entry.id })
        for id in controls.keys where !ids.contains(id) {
            controls.removeValue(forKey: id)?.removeFromSuperview()
        }
        let ordered = cards.indices.sorted {
            cards[$0].zIndex == cards[$1].zIndex
                ? $0 < $1 : cards[$0].zIndex < cards[$1].zIndex
        }
        let nextIDs = ordered.map { cards[$0].entry.id }
        let orderChanged = nextIDs != orderedIDs
        for index in ordered {
            let card = cards[index]
            let control: ScheduleBlankContextMenuControl
            if let retained = controls[card.entry.id] {
                control = retained
            } else {
                control = ScheduleBlankContextMenuControl()
                controls[card.entry.id] = control
                addSubview(control)
            }
            if control.frame != card.frame { control.frame = card.frame }
            configure(control, card)
            if orderChanged { bringSubviewToFront(control) }
        }
        orderedIDs = nextIDs
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

#endif
