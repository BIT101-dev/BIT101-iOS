import XCTest

final class ScheduleConflictUITests: UIAutomationTestCase {
    @MainActor
    func testDamagedRootRebuildRequiresConfirmationAndRestoresEditing() {
        app = configureApp(resetStorage: true, scheduleRootDamage: true, initialSettings: "calendar")
        let nameRow = app.buttons["schedule.settings.primary-name"]
        let rebuild = app.buttons["schedule.recovery.rebuild"]
        assertUI(rebuild.appears(timeout: 5) && !nameRow.isEnabled, "损坏的根文件应提供所属日程域的确认重建入口。")
        rebuild.tapBriefly()
        tap("schedule.recovery.rebuild.cancel")
        assertUI(rebuild.exists && !nameRow.isEnabled, "取消确认后应保留原文件与读取状态。")
        rebuild.tapBriefly()
        tap("schedule.recovery.rebuild.confirm")
        assertUI(rebuild.disappears(timeout: 5) && nameRow.isEnabled, "确认重建后应恢复日程编辑。")
        reveal(nameRow)
        nameRow.tapBriefly()
        replaceText("重建课表", in: app.textFields["schedule.rename.name"])
        dismissKeyboard()
        tap("确定")
        app = configureApp(resetStorage: false, restartProcess: true, initialSettings: "calendar")
        let saved = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
            "schedule.settings.primary-name", "重建课表")).firstMatch
        assertUI(saved.appears(timeout: 5), "冷启动应恢复重建后的编辑。")
    }

    @MainActor
    func testDDLSettingsResumeAfterCacheRecoveryConfirmation() {
        app = configureApp(resetStorage: true, scheduleRecovery: true, initialSettings: "ddl")
        let before = app.buttons["ui.ddl-settings-page.before-day"]
        let after = app.buttons["ui.ddl-settings-page.after-day"]
        let confirm = app.buttons["schedule.recovery.confirm"]
        assertUI(confirm.appears(timeout: 5) && !before.isEnabled && !after.isEnabled,
                 "DDL 显示设置应等待日程恢复确认。")
        app.buttons["ddl.refresh"].assertDisabled("恢复确认前应保留学校日程。")
        tap("schedule.recovery.retry")
        assertUI(confirm.appears(timeout: 5) && !before.isEnabled, "读取重试应沿用恢复状态。")
        confirm.tapBriefly()
        assertUI(confirm.disappears(timeout: 5) && before.isEnabled && after.isEnabled, "确认后应恢复 DDL 设置。")
        before.tapBriefly()
        let wheel = app.pickerWheels.firstMatch
        assertUI(wheel.appears(timeout: 5), "恢复后的天数设置应继续使用系统滚轮。")
        wheel.adjust(toPickerWheelValue: "7 天")
        tap("完成")
        assertUI(wheel.disappears(timeout: 5), "保存后应关闭滚轮。")
        app = configureApp(resetStorage: false, restartProcess: true, initialSettings: "ddl")
        tap("变色天数")
        assertUI(app.pickerWheels.firstMatch.value as? String == "7 天", "冷启动应恢复已确认的 DDL 设置。")
        tap("取消")
    }

    @MainActor
    func testKeepLocalConflictContentPersists() { resolveConflict(keepingLocal: true) }

    @MainActor
    func testUseSyncedConflictContentPersists() { resolveConflict(keepingLocal: false) }

    @MainActor
    func testRecoveredScheduleRequiresConfirmationAndPersistsSubsequentEdits() {
        app = configureApp(resetStorage: true, scheduleRecovery: true, initialSettings: "calendar")
        let nameRow = app.buttons["schedule.settings.primary-name"]
        let retry = app.buttons["schedule.recovery.retry"], confirm = app.buttons["schedule.recovery.confirm"]
        assertUI(confirm.appears(timeout: 5) && retry.exists, "恢复结果应提供核对、重试和确认入口。")
        assertUI(!nameRow.isEnabled, "确认恢复结果后继续编辑日程。")
        retry.tapBriefly()
        assertUI(confirm.appears(timeout: 5) && !nameRow.isEnabled, "重试读取应保留待确认的恢复结果。")
        confirm.tapBriefly()
        assertUI(confirm.disappears(timeout: 5) && nameRow.isEnabled, "确认成功后应恢复编辑。")
        reveal(nameRow)
        nameRow.tapBriefly()
        replaceText("确认课表", in: app.textFields["schedule.rename.name"])
        dismissKeyboard()
        tap("确定")
        app = configureApp(resetStorage: false, restartProcess: true, initialSettings: "calendar")
        let saved = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
            "schedule.settings.primary-name", "确认课表")).firstMatch
        assertUI(saved.appears(timeout: 5), "冷启动应恢复确认后的编辑。")
        assertUI(!app.buttons["schedule.recovery.confirm"].exists, "已保存的日程应直接进入常规编辑状态。")
    }

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
        assertUI(!nameRow.isEnabled, "版本冲突期间课表编辑应等待版本选择。")
        back()
        openSettings("ddl")
        let before = app.buttons["ui.ddl-settings-page.before-day"]
        assertUI(local.appears(timeout: 5) && !before.isEnabled, "DDL 设置应共享日程版本选择。")
        app.buttons["ui.ddl-settings-page.after-day"].assertDisabled("版本选择完成后可调整滞留天数。")
        let choice = keepingLocal ? local : synced
        reveal(choice)
        choice.tapBriefly()
        assertUI(local.disappears(timeout: 5), "版本选择应完成保存并关闭提示。")
        assertUI(before.isEnabled, "版本选择应恢复 DDL 显示设置。")
        back()
        openSettings("calendar")
        assertUI(nameRow.isEnabled, "版本选择保存后应恢复编辑。")
        let title = keepingLocal ? "本机标题" : "同步标题"
        let selectedName = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
            "schedule.settings.primary-name", title)).firstMatch
        assertUI(selectedName.appears(timeout: 5), "课表名称应采用所选冲突版本。")
        app = configureApp(resetStorage: false, restartProcess: true, initialSettings: "calendar")
        assertUI(selectedName.appears(timeout: 5), "冷启动应恢复已保存版本。")
    }
}
