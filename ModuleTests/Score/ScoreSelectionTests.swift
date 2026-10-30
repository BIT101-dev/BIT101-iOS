import ScoreDomain
import Testing

struct ScoreSelectionTests {
    private func row(_ index: Int, number: String = "CS1", score: String = "95", rank: String = "1") -> ScoreRow {
        .init(index: index, headers: ["课程编号", "课程名称", "成绩", "学分", "开课学期", "排名"],
            values: [number, "课程", score, "3", "term", rank])
    }

    @Test func selectedGradesFollowRefreshAndDetailedFields() {
        let selection = ScoreDetailSelection(row: row(0, score: "80", rank: ""))
        let updated = selection.row(in: [row(0, score: "98", rank: "2")])
        #expect(updated?.score == "98" && updated?["排名"] == "2")
        let reordered = selection.row(in: [row(0, number: "CS2"), row(1, score: "99")])
        #expect(reordered?.courseNumber == "CS1" && reordered?.score == "99")
        #expect(selection.row(in: [row(0, number: "CS2")]) == nil)
        #expect(selection.row(in: [row(1), row(2)]) == nil)
    }

    @Test func pendingSelectionsResolveNewlyPublishedGrades() {
        let course = ScoreCourseSummary(id: "course", term: "term", name: "课程", number: "CS1", type: "",
            teacher: "", classroom: "", campus: "", description: "", creditText: "3", scheduleText: "", weeksText: "", hourText: "")
        let selection = ScoreDetailSelection(course: course)
        #expect(selection.row(in: []) == nil && selection.pendingCourseID == course.id)
        #expect(selection.row(in: [row(0)])?.score == "95")
    }
}
