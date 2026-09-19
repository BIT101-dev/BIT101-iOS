import SwiftUI
import UIKit

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
        // 等待滚动内容完成首轮布局，再设置选中项，使选中项对齐完整刻度。
        _selectedWeek = State(initialValue: nil)
    }

    var body: some View {
        GeometryReader { proxy in
            let itemWidth = AppDesignSystem.Schedule.weekSlider.itemWidth
            let barHeight = AppDesignSystem.Schedule.weekSlider.barHeight
            let horizontalPadding = max((proxy.size.width - itemWidth) / 2, 0).rounded()

            ScrollViewReader { scrollProxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: AppDesignSystem.Schedule.weekSlider.itemSpacing) {
                        ForEach(weeks, id: \.self) { week in
                            VStack(spacing: AppDesignSystem.Schedule.grid.cellSpacing) {
                                Text(isMajorWeek(week) ? "\(week)" : "")
                                    .font(.caption2.weight(.semibold))
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
                            .contentShape(Rectangle())
                            .id(week)
                            .onTapGesture {
                                withAnimation(.snappy) {
                                    selectedWeek = week
                                }
                            }
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
                        .font(.caption2)
                        .foregroundStyle(.tint)
                        .rotationEffect(.degrees(180))
                        .allowsHitTesting(false)
                }
                .onAppear {
                    let target = weeks.contains(currentWeek) ? currentWeek : weeks.first
                    guard let target else { return }
                    DispatchQueue.main.async {
                        selectedWeek = target
                        DispatchQueue.main.async {
                            scrollProxy.scrollTo(target, anchor: .center)
                        }
                    }
                }
                .onChange(of: selectedWeek) { _, week in
                    guard let week, week != currentWeek else { return }
                    onSelectWeek(week)
                }
                .onChange(of: currentWeek) { _, week in
                    let target = weeks.contains(week) ? week : weeks.first
                    guard selectedWeek != target else { return }
                    selectedWeek = target
                    alignSelection(using: scrollProxy, to: target)
                }
                .onChange(of: weeks) { _, newWeeks in
                    let target = newWeeks.contains(currentWeek) ? currentWeek : newWeeks.first
                    guard selectedWeek == target else {
                        selectedWeek = target
                        alignSelection(using: scrollProxy, to: target)
                        return
                    }
                    alignSelection(using: scrollProxy, to: target)
                }
            }
        }
    }

    private func isMajorWeek(_ week: Int) -> Bool {
        week == 1 || week % 5 == 0
    }

    /// 首次布局完成后再次定位到完整周次项，使冷启动时的选中项对齐完整刻度。
    private func alignSelection(using proxy: ScrollViewProxy, to target: Int? = nil) {
        guard let target = target ?? selectedWeek else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(target, anchor: .center)
        }
    }
}

