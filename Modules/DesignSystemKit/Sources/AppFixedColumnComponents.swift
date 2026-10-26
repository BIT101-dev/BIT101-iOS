#if os(iOS)
import SwiftUI

/// AppFixedColumnItem 定义紧凑数据行的一列文本及其显示参数。
///
/// 课程列表和成绩列表使用比例列和等宽数字，辅助功能字号采用逐项排列。
/// AppFixedColumnRow 统一列宽和数字显示；业务页面传入列含义。
public struct AppFixedColumnItem {
    let text: String
    let ratio: CGFloat
    let font: Font
    let color: Color
    let alignment: Alignment

    public init(
        text: String,
        ratio: CGFloat,
        font: Font,
        color: Color,
        alignment: Alignment = .leading
    ) {
        self.text = text
        self.ratio = ratio
        self.font = font
        self.color = color
        self.alignment = alignment
    }
}

/// AppFixedColumnRow 按比例分配可用宽度，行高容纳当前字体并沿用指定最小高度。
public struct AppFixedColumnRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    public init(items: [AppFixedColumnItem], height: CGFloat) {
        self.items = items
        _height = ScaledMetric(wrappedValue: height, relativeTo: .body)
    }

    let items: [AppFixedColumnItem]
    @ScaledMetric private var height: CGFloat

    public var body: some View {
        let expanded = dynamicTypeSize.isAccessibilitySize
        let layout = expanded
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: AppDesignSystem.Spacing.tiny))
            : AnyLayout(AppFixedColumnLayout(ratios: items.map(\.ratio)))
        layout {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                Text(item.text)
                    .font(item.font)
                    .foregroundStyle(item.color)
                    .lineLimit(expanded ? nil : 1)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: expanded ? .leading : item.alignment)
            }
        }
        .frame(minHeight: height)
    }
}

private struct AppFixedColumnLayout: Layout {
    let ratios: [CGFloat]

    private func widths(for width: CGFloat) -> [CGFloat] {
        let total = ratios.reduce(CGFloat.zero) { $0 + max($1, 0) }
        return ratios.map { total > 0 ? width * max($0, 0) / total : 0 }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.reduce(CGFloat.zero) {
            $0 + $1.sizeThatFits(.unspecified).width
        }
        let columns = widths(for: width)
        let height = subviews.indices.map { index in
            subviews[index].sizeThatFits(ProposedViewSize(width: columns[index], height: nil)).height
        }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = widths(for: bounds.width)
        var x = bounds.minX
        for index in subviews.indices {
            subviews[index].place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                proposal: ProposedViewSize(width: columns[index], height: bounds.height))
            x += columns[index]
        }
    }
}
#endif
