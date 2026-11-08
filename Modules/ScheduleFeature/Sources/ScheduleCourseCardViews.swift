#if os(iOS)
import ScheduleDomain
import DesignSystemKit
import SwiftUI
import UIKit

/// 复用原生 UILabel 和排版结果，文字始终由 UIKit 显示。
@MainActor
final class ScheduleCardTextView: UIView {
    let titleLabel = UILabel()
    let locationLabel = UILabel()
    private var title = ""
    private var location = ""
    private var scheduleContentMode = ScheduleCardContentMode.nameAndLocation
    private var baseFont = UIFont.preferredFont(
        forTextStyle: AppDesignSystem.Typography.uiCaption)
    private var laidOutSize: CGSize?
    private var laidOutScale: CGFloat = 0
    private var layoutScale: CGFloat = 0
    private var textColor = UIColor.label

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        [titleLabel, locationLabel].forEach { label in
            addSubview(label)
            label.textColor = textColor
            label.textAlignment = .center
            label.adjustsFontForContentSizeCategory = false
            label.adjustsFontSizeToFitWidth = false
            label.allowsDefaultTighteningForTruncation = true
            label.clipsToBounds = true
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
        if self.textColor != textColor {
            self.textColor = textColor
            titleLabel.textColor = textColor
            locationLabel.textColor = textColor
        }
        guard
            self.title != title || self.location != location
                || scheduleContentMode != contentMode || baseFont != font
        else { return }
        self.title = title
        self.location = location
        scheduleContentMode = contentMode
        baseFont = font
        laidOutSize = nil
    }

    func layout(size: CGSize, scale: CGFloat) {
        guard size.width > 0, size.height > 0 else { return }
        guard laidOutSize != size || laidOutScale != scale else { return }
        bounds = CGRect(origin: .zero, size: size)
        layoutScale = scale
        laidOutSize = size
        laidOutScale = scale

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
            while upper - lower > 1 / layoutScale {
                let size = (lower + upper) / 2
                if measuredHeight(text: text, font: baseFont.withSize(size), width: rect.width)
                    <= rect.height
                {
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
    @Environment(\.appPageIsVisible) private var isVisible
    let cards: [ScheduleCalendarCard]
    let contentMode: ScheduleCardContentMode
    let onSelect: (ScheduleCalendarEntry) -> Void
    let onMenuWillPresent: (ScheduleCalendarEntry) -> Void
    let onShare: (ScheduleCalendarEntry) -> Void

    func makeUIView(context: Context) -> ScheduleCalendarCardsControl {
        ScheduleCalendarCardsControl()
    }

    func updateUIView(_ view: ScheduleCalendarCardsControl, context: Context) {
        view.isContentVisible = isVisible
        guard isVisible else { return }
        view.interactionEvidence = interactionEvidence
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

final class ScheduleCalendarCardsControl: UIView, UIContextMenuInteractionDelegate {
    var interactionEvidence: ((String, String) -> Void)?
    var isContentVisible = true {
        didSet {
            guard isContentVisible != oldValue else { return }
            controls.values.forEach { $0.isContentVisible = isContentVisible }
        }
    }
    private var controls: [String: ScheduleBlankContextMenuControl] = [:]
    private var orderedIDs: [String] = []
    private weak var menuCard: ScheduleBlankContextMenuControl?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let tap = UITapGestureRecognizer(target: self, action: #selector(openCard(_:)))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func openCard(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        guard let card = hitTest(point, with: nil) as? ScheduleBlankContextMenuControl else {
            return
        }
        interactionEvidence?("interaction.ScheduleCalendarCardsControl.tap", "tap")
        card.onTap?()
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        menuCard = hitTest(location, with: nil) as? ScheduleBlankContextMenuControl
        guard let card = menuCard, card.onShare != nil else { return nil }
        return card.contextMenuInteraction(
            interaction, configurationForMenuAtLocation: card.convert(location, from: self))
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        menuCard.map { UITargetedPreview(view: $0) }
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        menuCard.map { UITargetedPreview(view: $0) }
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willDisplayMenuFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        menuCard?.onMenuWillPresent?()
    }

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
                control.isContentVisible = isContentVisible
                control.useSharedInteractionHandling()
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
