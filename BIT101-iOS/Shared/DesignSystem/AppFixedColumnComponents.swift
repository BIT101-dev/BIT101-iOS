import SwiftUI

/// AppFixedColumnItem 定义紧凑数据行的一列文本及其显示参数。
///
/// 课程列表和成绩列表使用比例列、单行截断和等宽数字。
/// AppFixedColumnRow 统一列宽、截断规则和数字显示；业务页面传入列含义。
struct AppFixedColumnItem {
    let text: String
    let ratio: CGFloat
    let font: Font
    let color: Color
    let alignment: Alignment

    init(
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

/// AppFixedColumnRow 按比例分配可用宽度，并使用指定高度显示单行列文本。
struct AppFixedColumnRow: View {
    let items: [AppFixedColumnItem]
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: AppDesignSystem.Spacing.none) {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    Text(item.text)
                        .font(item.font)
                        .foregroundStyle(item.color)
                        .lineLimit(1)
                        .monospacedDigit()
                        .frame(
                            width: proxy.size.width * item.ratio,
                            height: height,
                            alignment: item.alignment
                        )
                }
            }
        }
        .frame(height: height)
    }
}
