import SwiftUI

/// 紧凑数据行的列定义。
///
/// 课程列表和成绩列表都需要“比例列 + 单行截断 + 数字等宽”的结构，
/// 这里统一几何实现；具体列含义仍由业务页面传入。
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

/// 按比例分配可用宽度的紧凑数据行。
struct AppFixedColumnRow: View {
    let items: [AppFixedColumnItem]
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
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
