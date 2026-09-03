//
//  ScheduleEditingSupport.swift
//  BIT101-iOS
//

import SwiftUI

enum CourseEditorMode: Equatable {
    case add
    case editOccurrence(week: Int)
    case editCourse(courseID: String)

    var title: String {
        switch self {
        case .add:
            return "添加课程"
        case .editOccurrence:
            return "调这节课"
        case .editCourse:
            return "调这门课"
        }
    }

    var locksWeeks: Bool {
        if case .editOccurrence = self {
            return true
        }
        return false
    }

    var fixedWeek: Int? {
        if case let .editOccurrence(week) = self {
            return week
        }
        return nil
    }

    var footerText: String {
        switch self {
        case .add:
            return "添加的课程会存储在本地；删除应用后信息将丢失。"
        case let .editOccurrence(week):
            return "这次只会修改第\(week)周这一节课，系统会把它从原课程里拆出来单独保存。"
        case .editCourse:
            return "这会修改这门课在所选周次内的统一排课信息。"
        }
    }
}

/// 点击课表顶部日期后进入的日期调整上下文。
struct ScheduleDayAdjustmentContext: Identifiable {
    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "M.d"
        return formatter
    }()

    let date: Date
    let week: Int
    let weekday: Int

    var id: String {
        "\(week)-\(weekday)-\(ScheduleDateCodec.formatDate(date))"
    }

    var shortTitle: String {
        "\(weekdayText) \(Self.shortDateFormatter.string(from: date))"
    }

    var fullDateText: String {
        "\(ScheduleDateCodec.formatDate(date))（\(weekdayText)）"
    }

    private var weekdayText: String {
        let titles = ["一", "二", "三", "四", "五", "六", "日"]
        guard (1 ... titles.count).contains(weekday) else { return "?" }
        return "周\(titles[weekday - 1])"
    }
}

/// 单日课表调整模式。
enum ScheduleDayAdjustmentMode: String, CaseIterable, Identifiable {
    case holiday
    case transfer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .holiday:
            return "放假"
        case .transfer:
            return "调至某天"
        }
    }
}

/// 单日课表调整草稿。
struct ScheduleDayAdjustmentDraft: Equatable {
    var mode: ScheduleDayAdjustmentMode = .holiday
    var targetDate = Date()
}

/// 放假 / 调休调整页。
struct DayAdjustmentSheet: View {
    let context: ScheduleDayAdjustmentContext
    @Binding var draft: ScheduleDayAdjustmentDraft
    let onSubmit: () -> Void
    let onDismiss: () -> Void

    @State private var pendingConfirmation: PendingDayAdjustmentConfirmation?

    var body: some View {
        NavigationStack {
            Form {
                Section("日期") {
                    LabeledContent("当前日期", value: context.fullDateText)
                    LabeledContent("当前周次", value: "第\(context.week)周")
                }

                Section("操作") {
                    Picker("类型", selection: $draft.mode) {
                        ForEach(ScheduleDayAdjustmentMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .appSelectionFeedback(trigger: draft.mode)

                    if draft.mode == .transfer {
                        DatePicker("调至", selection: $draft.targetDate, displayedComponents: .date)
                    }
                }

                Section {
                    Text(footerText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("调休 / 放假")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消", action: onDismiss)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("确定") {
                        pendingConfirmation = PendingDayAdjustmentConfirmation(
                            mode: draft.mode,
                            sourceDateText: context.fullDateText,
                            targetDateText: ScheduleDateCodec.formatDate(draft.targetDate)
                        )
                    }
                }
            }
            .alert(item: $pendingConfirmation) { confirmation in
                Alert(
                    title: Text(confirmation.title),
                    message: Text(confirmation.message),
                    primaryButton: .destructive(Text("确定")) {
                        onSubmit()
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
        }
    }

    private var footerText: String {
        switch draft.mode {
        case .holiday:
            return "放假会清空这一天的课程；考试和自定义日程不会被删除。"
        case .transfer:
            return "调课会先清空当前日期的课程，再把这些课程移动到目标日期；如果目标日期已有课程，将被覆盖。"
        }
    }

    private struct PendingDayAdjustmentConfirmation: Identifiable {
        let id = UUID()
        let mode: ScheduleDayAdjustmentMode
        let sourceDateText: String
        let targetDateText: String

        var title: String {
            switch mode {
            case .holiday:
                return "确认放假"
            case .transfer:
                return "确认调课"
            }
        }

        var message: String {
            switch mode {
            case .holiday:
                return "这会清空 \(sourceDateText) 的课程。"
            case .transfer:
                return "这会清空 \(sourceDateText) 的课程，并调至 \(targetDateText)。如果目标日期已有课程，将被覆盖。"
            }
        }
    }
}
