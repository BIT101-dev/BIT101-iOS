#if os(iOS)
import ScheduleDomain
import DesignSystemKit
import SwiftUI
import UIKit

/// 复用原生 UILabel 和排版结果，文字始终由 UIKit 显示。
@MainActor
final class ScheduleCardTextView: UIView {
    private struct MeasurementKey: Equatable {
        let text: String
        let font: UIFont
        let width: CGFloat
    }
    private struct LocationKey: Equatable {
        let measurement: MeasurementKey
        let height: CGFloat
        let scale: CGFloat
    }
    private static var lastMeasurement: (key: MeasurementKey, height: CGFloat)?
    private static var lastLocation: (key: LocationKey, font: UIFont, height: CGFloat)?
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
        if titleLabel.superview == nil { addSubview(titleLabel) }
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
        let layout = fittedLocation(text: text, width: rect.width, height: rect.height)
        configureLocationLabel(text: text, height: layout.height, font: layout.font)
        locationLabel.frame = CGRect(
            x: rect.minX,
            y: verticallyCentered
                ? rect.minY + max((rect.height - layout.height) / 2, 0)
                : rect.maxY - layout.height,
            width: rect.width,
            height: layout.height
        )
    }

    private func fittedLocation(text: String, width: CGFloat, height: CGFloat)
        -> (font: UIFont, height: CGFloat)
    {
        let key = LocationKey(
            measurement: MeasurementKey(text: text, font: baseFont, width: width),
            height: height, scale: layoutScale)
        if let cached = Self.lastLocation, cached.key == key { return (cached.font, cached.height) }
        let naturalHeight = measuredHeight(text: text, font: baseFont, width: width)
        var font = baseFont
        if naturalHeight > height {
            var lower = baseFont.pointSize * height / naturalHeight
            var upper = baseFont.pointSize
            while upper - lower > 1 / layoutScale {
                let size = (lower + upper) / 2
                if measuredHeight(text: text, font: baseFont.withSize(size), width: width) <= height
                {
                    lower = size
                } else {
                    upper = size
                }
            }
            font = baseFont.withSize(lower)
        }
        let fittedHeight = min(measuredHeight(text: text, font: font, width: width), height)
        Self.lastLocation = (key, font, fittedHeight)
        return (font, fittedHeight)
    }

    private func configureLocationLabel(text: String, height: CGFloat, font: UIFont) {
        locationLabel.isHidden = false
        if locationLabel.superview == nil { addSubview(locationLabel) }
        locationLabel.text = text
        locationLabel.font = font
        locationLabel.numberOfLines = max(Int(floor(height / font.lineHeight)), 1)
        locationLabel.preferredMaxLayoutWidth = bounds.width
    }

    private func measuredHeight(text: String, font: UIFont, width: CGFloat) -> CGFloat {
        let key = MeasurementKey(text: text, font: font, width: width)
        if let cached = Self.lastMeasurement, cached.key == key { return cached.height }
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font], context: nil)
        let height = ceil(rect.height)
        Self.lastMeasurement = (key, height)
        return height
    }

    private func hideTitle() {
        titleLabel.isHidden = true
        titleLabel.removeFromSuperview()
        titleLabel.frame = .zero
    }

    private func hideLocation() {
        locationLabel.isHidden = true
        locationLabel.removeFromSuperview()
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
    var touchContentBounds: CGRect? = nil

    func makeUIView(context: Context) -> ScheduleCalendarCardsControl {
        ScheduleCalendarCardsControl()
    }

    func updateUIView(_ view: ScheduleCalendarCardsControl, context: Context) {
        view.isContentVisible = isVisible
        guard isVisible else { return }
        view.interactionEvidence = interactionEvidence
        view.touchContentBounds = touchContentBounds
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
    var touchContentBounds: CGRect?
    var isContentVisible = true {
        didSet {
            guard isContentVisible != oldValue else { return }
            controls.values.forEach { $0.isContentVisible = isContentVisible }
        }
    }
    private var controls: [String: ScheduleBlankContextMenuControl] = [:]
    private var orderedIDs: [String] = []
    private weak var menuCard: ScheduleBlankContextMenuControl?
    private var usesDirectTouch = false

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
        guard let card = card(at: point, expandForTouch: usesDirectTouch) else {
            return
        }
        interactionEvidence?("interaction.ScheduleCalendarCardsControl.tap", "tap")
        card.onTap?()
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        menuCard = card(at: location, expandForTouch: usesDirectTouch)
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
        if let event {
            usesDirectTouch = event.allTouches?.contains { $0.type == .direct } == true
        }
        return card(at: point, expandForTouch: event != nil && usesDirectTouch)
    }

    func card(at point: CGPoint, expandForTouch: Bool) -> ScheduleBlankContextMenuControl? {
        guard let hit = super.hitTest(point, with: nil) else { return nil }
        if let exact = hit as? ScheduleBlankContextMenuControl {
            return exact
        }
        guard hit === self, expandForTouch, touchContentBounds?.contains(point) != false
        else { return nil }
        var nearest: ScheduleBlankContextMenuControl?
        var nearestDistance = CGFloat.infinity
        for id in orderedIDs.reversed() {
            guard let control = controls[id], !control.isHidden, control.isUserInteractionEnabled,
                control.alpha > 0.01
            else { continue }
            let frame = control.frame
            let target = AppDesignSystem.Size.Control.touchTarget
            let hitFrame = frame.insetBy(
                dx: min((frame.width - target) / 2, 0),
                dy: min((frame.height - target) / 2, 0))
            guard hitFrame.contains(point) else { continue }
            let dx = max(frame.minX - point.x, point.x - frame.maxX, 0)
            let dy = max(frame.minY - point.y, point.y - frame.maxY, 0)
            let distance = dx * dx + dy * dy
            if distance < nearestDistance {
                nearest = control
                nearestDistance = distance
            }
        }
        return nearest
    }
}

#endif
