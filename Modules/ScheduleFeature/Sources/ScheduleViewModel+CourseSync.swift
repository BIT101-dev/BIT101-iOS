import SchedulePorts
import ScheduleDomain
import Foundation

extension ScheduleViewModel {
    public func syncCourses(term: String? = nil) async {
        await courseSyncCoordinator.syncCourses(term: term, selectTerm: selectTermForSync, applyPayload: applyCourseSyncPayload)
    }

    public func loadAvailableTerms() async { await courseSyncCoordinator.loadAvailableTerms() }

    public func submitSMSCode(_ code: String) async {
        await courseSyncCoordinator.submitSMSCode(code, applyPayload: applyCourseSyncPayload,
            refreshClassrooms: classroom.refreshClassroomPage)
    }

    public func dismissSMSChallenge() { courseSyncCoordinator.dismissSMSChallenge() }

    /// 先保存用户选择的学期，再独立请求课表。
    ///
    /// 已有快照会立即切换到对应内容；没有快照时清空当前课表数据，当前学期页面从空课表开始。
    /// 后续请求失败时通过 `notice` 提示并保留学期选择。
    private func selectTermForSync(_ term: String) {
        let normalizedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTerm.isEmpty, courseState.currentTerm != normalizedTerm else { return }

        courseState.currentTerm = normalizedTerm
        selectedWeek = resolvedAutomaticWeek()
        persist()
    }

    /// 重新获取当前正在显示的目标学期，首次同步使用学校的“当前学期”标记。
    ///
    /// 用户主动切到其它学期后，普通的“获取/重新同步”继续请求该学期；本地尚未保存
    /// 学期编码时传 `nil`，让学校返回当前学期。
    func syncSelectedTerm() async {
        let term = courseState.currentTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        await syncCourses(term: term.isEmpty ? nil : term)
    }

    /// 课表页面展示的最近一次成功同步时间。
    var coursesLastUpdatedText: String {
        guard courseState.coursesUpdatedAt != .distantPast else { return "更新时间：暂无记录" }
        return "更新时间：\(courseState.coursesUpdatedAt.formatted(.dateTime.month().day().hour().minute()))"
    }

    private func applyCourseSyncPayload(_ payload: CourseSyncPayload) async {
        let generation = accountGeneration
        let incomingCourses = payload.courses
        let now = Date()
        let existingBaseline = courseState.data.schoolCourses(for: payload.term)
        let rules = courseState.manualCourseRulesByTerm[payload.term] ?? []
        let reconciliation = ScheduleCourseEditor.reconcile(
            rules: rules,
            with: incomingCourses
        )
        let coursesAreIdentical = scheduleCourseSourceRecordsEqual(existingBaseline, incomingCourses)

        let snapshot = makeTermSnapshot(from: payload, now: now)
        courseState.data.store(snapshot)

        if courseState.currentTerm == payload.term {
            selectedWeek = resolvedAutomaticWeek()
        }
        trimTermSnapshots(preserving: Set([payload.term]))
        guard await persistAndWait(), accountGeneration == generation else { return }

        if !reconciliation.invalidRules.isEmpty {
            let names = uniqueCourseNames(from: reconciliation.invalidRules)
            let courseText = names.isEmpty ? "相关课程" : names.joined(separator: "、")
            notice = ScheduleNotice.userInput(
                title: "手动调课已失效",
                message: "学校课表中的 \(courseText) 发生了变化，相关手动调课已移除，当前显示最新课程安排。"
            )
        } else if coursesAreIdentical {
            notice = ScheduleNotice.informational(
                title: "课表已是最新",
                message: "本次获取结果与学校原始课表完全一致。"
            )
        }
    }

    private func makeTermSnapshot(from payload: CourseSyncPayload, now: Date) -> TermScheduleSnapshot {
        TermScheduleSnapshot(
            term: payload.term,
            firstDayString: payload.firstDayString,
            courses: payload.courses,
            exams: payload.exams,
            updatedAt: now
        )
    }

    /// 将学期快照数量限制为最多两个，并保留当前显示学期与显式同步的目标学期。
    private func trimTermSnapshots(preserving terms: Set<String>) {
        guard courseState.termSchedulesByTerm.count > 2 else { return }
        let removable = courseState.termSchedulesByTerm.values
            .filter { !terms.contains($0.term) && $0.term != courseState.currentTerm }
            .sorted { $0.updatedAt < $1.updatedAt }
        for snapshot in removable where courseState.termSchedulesByTerm.count > 2 {
            courseState.data.archive(term: snapshot.term)
        }
    }

    private func uniqueCourseNames(from rules: [ScheduleCourseRule]) -> [String] {
        var names: [String] = []
        for rule in rules {
            for name in rule.sourceCourses.map(\.name) where !name.isEmpty {
                guard !names.contains(name) else { continue }
                names.append(name)
            }
        }
        return Array(names.prefix(3))
    }

}
