import XCTest

final class ScheduleConflictUITests: UIAutomationTestCase {
    @MainActor
    func testKeepLocalConflictContentPersists() { resolveConflict(keepingLocal: true) }

    @MainActor
    func testUseSyncedConflictContentPersists() { resolveConflict(keepingLocal: false) }

    @MainActor
    private func resolveConflict(keepingLocal: Bool) {
        app = configureApp(resetStorage: true, scheduleConflict: true, initialSettings: "calendar")
        let nameRow = app.buttons["schedule.settings.primary-name"]
        reveal(nameRow)
        nameRow.tapBriefly()
        replaceText("本机标题", in: app.textFields["schedule.rename.name"])
        dismissKeyboard()
        tap("确定")
        let local = app.buttons["schedule.conflict.keep-local"]
        let synced = app.buttons["schedule.conflict.use-cloud"]
        assertUI(local.appears(timeout: 5) && synced.exists, "版本分歧应展示两种明确选择。")
        let choice = keepingLocal ? local : synced
        reveal(choice)
        choice.tapBriefly()
        assertUI(local.disappears(timeout: 5), "版本选择应完成保存并关闭提示。")
        let title = keepingLocal ? "本机标题" : "同步标题"
        assertUI(nameRow.label.contains(title), "课表名称应采用所选冲突版本。")
        app = configureApp(resetStorage: false, restartProcess: true, initialSettings: "calendar")
        assertUI(app.buttons["schedule.settings.primary-name"].label.contains(title), "冷启动应恢复已保存版本。")
    }
}
