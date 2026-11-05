import SwiftUI
import WidgetKit

/// WidgetKit 扩展入口。
///
/// 扩展提供桌面与锁屏的课表、DDL 组件，以及课程提醒 Live Activity。
@main
struct BIT101ScheduleWidgetsBundle: WidgetBundle {
    /// 扩展提供给系统的 WidgetKit 入口。
    var body: some Widget {
        BIT101ScheduleWidgets()
        BIT101DeadlineWidget()
        CourseReminderLiveActivityWidget()
    }
}
