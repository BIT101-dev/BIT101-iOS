import SwiftUI

/// 课表顶部的周次滑动条，直接切换当前周。
struct ScheduleInlineWeekSlider: View {
    let weeks: [Int]
    let currentWeek: Int
    let highlightedWeek: Int
    let onSelectWeek: (Int) -> Void
    @State private var selectedWeek: Int?

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
            let itemWidth = AppDesignSystem.Schedule.weekSlider.itemWidth
            let barHeight = AppDesignSystem.Schedule.weekSlider.barHeight
            let horizontalPadding = max((proxy.size.width - itemWidth) / 2, 0).rounded()

            ScrollView(.horizontal) {
                LazyHStack(spacing: AppDesignSystem.Schedule.weekSlider.itemSpacing) {
                    ForEach(weeks, id: \.self) { week in
                        Button {
                            withAnimation(.snappy) {
                                selectedWeek = week
                            }
                        } label: {
                            VStack(spacing: AppDesignSystem.Schedule.grid.cellSpacing) {
                                Text(isMajorWeek(week) ? "\(week)" : "")
                                    .font(AppDesignSystem.Typography.caption2Emphasis)
                                    .foregroundStyle(week == highlightedWeek ? AppDesignSystem.Palette.accent : .secondary)
                                    .frame(height: AppDesignSystem.Schedule.weekSlider.labelHeight)
                                Capsule()
                                    .fill(week == highlightedWeek
                                        ? AppDesignSystem.Palette.accent
                                        : AppDesignSystem.Schedule.GridPalette.weekBar)
                                    .frame(
                                        width: week == highlightedWeek
                                            ? AppDesignSystem.Schedule.weekSlider.selectedBarWidth
                                            : AppDesignSystem.Schedule.weekSlider.barWidth,
                                        height: isMajorWeek(week)
                                            ? barHeight
                                            : AppDesignSystem.Schedule.weekSlider.minorBarHeight
                                    )
                            }
                            .frame(
                                width: itemWidth,
                                height: AppDesignSystem.Schedule.weekSlider.itemHeight,
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
                .frame(minHeight: AppDesignSystem.Schedule.weekSlider.itemHeight)
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $selectedWeek, anchor: .center)
            .safeAreaPadding(.horizontal, horizontalPadding)
            .overlay(alignment: .top) {
                Image(systemName: "triangle.fill")
                    .font(AppDesignSystem.Typography.caption2)
                    .foregroundStyle(AppDesignSystem.Palette.accent)
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

    private func isMajorWeek(_ week: Int) -> Bool {
        week == 1 || week % 5 == 0
    }
}
