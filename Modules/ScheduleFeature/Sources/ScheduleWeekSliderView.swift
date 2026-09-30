#if os(iOS)
import DesignSystemKit
import SwiftUI

/// 课表顶部的周次滑动条，直接切换当前周。
struct ScheduleInlineWeekSlider: View {
    let weeks: [Int]
    let currentWeek: Int
    let highlightedWeek: Int
    let onSelectWeek: (Int) -> Void
    @State private var selectedWeek: Int?
#if targetEnvironment(macCatalyst)
    @State private var dragStartIndex: Int?
#endif

    init(
        weeks: [Int],
        currentWeek: Int,
        highlightedWeek: Int,
        onSelectWeek: @escaping (Int) -> Void
    ) {
        self.weeks = weeks
        self.currentWeek = currentWeek
        self.highlightedWeek = highlightedWeek
        self.onSelectWeek = onSelectWeek
        // 由 scrollPosition 在首轮布局后将选中项对齐完整刻度。
        _selectedWeek = State(initialValue: nil)
    }

    var body: some View {
        GeometryReader { proxy in
            let itemWidth = AppDesignSystem.Schedule.WeekSlider.itemWidth
            let barHeight = AppDesignSystem.Schedule.WeekSlider.barHeight
            let controlWidth = AppDesignSystem.Size.Control.touchTarget
            let sliderWidth = max(proxy.size.width - controlWidth * 2, itemWidth)
            let horizontalPadding = max((sliderWidth - itemWidth) / 2, 0)

            HStack(spacing: AppDesignSystem.Spacing.none) {
                stepButton(by: -1)

                ScrollView(.horizontal) {
                    LazyHStack(spacing: AppDesignSystem.Schedule.WeekSlider.itemSpacing) {
                        ForEach(weeks, id: \.self) { week in
                            Button {
                                withAnimation(.snappy) {
                                    selectedWeek = week
                                }
                            } label: {
                                VStack(spacing: AppDesignSystem.Schedule.Grid.cellSpacing) {
                                    Text(isMajorWeek(week) ? "\(week)" : "")
                                        .font(AppDesignSystem.Typography.captionEmphasis)
                                        .foregroundStyle(week == highlightedWeek ? AppDesignSystem.Palette.Accent.primary : AppDesignSystem.Foreground.secondaryColor)
                                        .frame(height: AppDesignSystem.Schedule.WeekSlider.labelHeight)
                                    Capsule()
                                        .fill(week == highlightedWeek
                                            ? AppDesignSystem.Palette.Accent.primary
                                            : AppDesignSystem.Schedule.GridPalette.weekBar)
                                        .frame(
                                            width: week == highlightedWeek
                                                ? AppDesignSystem.Schedule.WeekSlider.selectedBarWidth
                                                : AppDesignSystem.Schedule.WeekSlider.barWidth,
                                            height: isMajorWeek(week)
                                                ? barHeight
                                                : AppDesignSystem.Schedule.WeekSlider.minorBarHeight
                                        )
                                }
                                .frame(
                                    width: itemWidth,
                                    height: AppDesignSystem.Schedule.WeekSlider.itemHeight,
                                    alignment: .top
                                )
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .accessibilityLabel("第\(week)周")
                            .accessibilityValue(week == highlightedWeek ? "当前周" : "")
                            .id(week)
                        }
                    }
                    .scrollTargetLayout()
                    .frame(minHeight: AppDesignSystem.Schedule.WeekSlider.itemHeight)
                }
                .scrollIndicators(.hidden)
                .contentMargins(.horizontal, horizontalPadding, for: .scrollContent)
                .scrollTargetBehavior(weekScrollTargetBehavior)
                .scrollPosition(id: $selectedWeek, anchor: .center)
#if targetEnvironment(macCatalyst)
                .simultaneousGesture(DragGesture().onChanged { _ in
                    if dragStartIndex == nil {
                        dragStartIndex = weeks.firstIndex(of: selectedWeek ?? currentWeek)
                    }
                }.onEnded { value in
                    defer { dragStartIndex = nil }
                    let itemSpacing = AppDesignSystem.Schedule.WeekSlider.itemSpacing
                    let steps = Int((value.translation.width / (itemWidth + itemSpacing)).rounded())
                    guard abs(value.translation.width) > abs(value.translation.height),
                          let index = dragStartIndex, !weeks.isEmpty else { return }
                    let target = weeks[min(max(index - steps, 0), weeks.count - 1)]
                    withAnimation(.snappy) {
                        selectedWeek = target
                    }
                })
#endif
                .frame(maxWidth: .infinity)

                stepButton(by: 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                Image(systemName: "triangle.fill")
                    .font(AppDesignSystem.Typography.caption)
                    .foregroundStyle(AppDesignSystem.Palette.Accent.primary)
                    .rotationEffect(.degrees(180))
                    .allowsHitTesting(false)
            }
            .onAppear {
                selectedWeek = weeks.contains(currentWeek) ? currentWeek : weeks.first
            }
            .onChange(of: selectedWeek) { _, week in
                guard let week, week != currentWeek else { return }
                onSelectWeek(week)
            }
            .onChange(of: currentWeek) { _, week in
                let target = weeks.contains(week) ? week : weeks.first
                guard selectedWeek != target else { return }
                selectedWeek = target
            }
            .onChange(of: weeks) { _, newWeeks in
                let target = newWeeks.contains(currentWeek) ? currentWeek : newWeeks.first
                guard selectedWeek != target else { return }
                selectedWeek = target
            }
        }
    }

    private func stepButton(by step: Int) -> some View {
        let targetWeek = adjacentWeek(by: step)
        let background = AppDesignSystem.Palette.Background.secondaryGrouped
        let gradientColors = step < 0
            ? [background, Color.clear]
            : [Color.clear, background]

        return Button {
            guard let targetWeek else { return }
            withAnimation(.snappy) {
                selectedWeek = targetWeek
            }
        } label: {
            Image(systemName: step < 0 ? "chevron.left" : "chevron.right")
                .font(AppDesignSystem.Typography.captionEmphasis)
                .foregroundStyle(AppDesignSystem.Foreground.secondary)
                .frame(
                    width: AppDesignSystem.Size.Control.touchTarget,
                    height: AppDesignSystem.Size.Control.touchTarget
                )
                .background {
                    LinearGradient(
                        colors: gradientColors,
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(targetWeek == nil)
        .opacity(targetWeek == nil ? AppDesignSystem.Opacity.overlay : AppDesignSystem.Opacity.full)
        .accessibilityLabel(step < 0 ? "上一周" : "下一周")
        .accessibilityValue(
            targetWeek.map { "第\($0)周" }
                ?? (step < 0 ? "已到最前一周" : "已到最后一周")
        )
    }

    private func adjacentWeek(by step: Int) -> Int? {
        guard let index = weeks.firstIndex(of: selectedWeek ?? currentWeek) else { return nil }
        let targetIndex = index + step
        guard weeks.indices.contains(targetIndex) else { return nil }
        return weeks[targetIndex]
    }

    private func isMajorWeek(_ week: Int) -> Bool {
        week == 1 || week % 5 == 0
    }

    private var weekScrollTargetBehavior: ViewAlignedScrollTargetBehavior {
        if #available(iOS 26.0, *) {
            return .init(anchor: .center)
        }
        return .init()
    }
}

#endif
