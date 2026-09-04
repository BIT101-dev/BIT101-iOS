import XCTest
import UIKit
@testable import BIT101_iOS

final class ErrorReportAndSchedulePolicyTests: XCTestCase {
    @MainActor
    func testGlobalKeyboardAccessory() async throws {
        let coordinator = KeyboardBackgroundTapInstaller.Coordinator()
        let window = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)
        )
        let textField = UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 44))
        window.addSubview(textField)
        defer {
            textField.resignFirstResponder()
            textField.removeFromSuperview()
        }

        XCTAssertTrue(textField.becomeFirstResponder())
        await Task.yield()
        XCTAssertNotNil(textField.inputAccessoryView)
        XCTAssertTrue(textField.inputAccessoryView is UIToolbar)

        _ = coordinator
    }

    func testForcedRedactionKeepsPersonalFieldsButRemovesCredentials() {
        let output = ErrorReportRedactor.forced("name=张三&student_id=1120260000&password=secret&token=abc&cookie=session&ticket=ST-secret")
        XCTAssertTrue(output.contains("张三"))
        XCTAssertTrue(output.contains("1120260000"))
        XCTAssertFalse(output.contains("secret"))
        XCTAssertFalse(output.contains("token=abc"))
        XCTAssertFalse(output.contains("cookie=session"))
        XCTAssertFalse(output.contains("ST-secret"))
        XCTAssertFalse(ErrorReportRedactor.forced(#"{"accessToken":"abc","sessionID":"xyz"}"#).contains("abc"))
        let sanitized = ErrorReportRedactor.sanitized("student_id=1120260000&name=张三&status=401")
        XCTAssertFalse(sanitized.contains("1120260000"))
        XCTAssertFalse(sanitized.contains("张三"))
        XCTAssertTrue(sanitized.contains("401"))
    }

    func testAutomaticWeekPositioningClampsOnlyCalculatedWeeks() {
        XCTAssertEqual(ScheduleAutomaticWeekPolicy.clamped(-20), -12)
        XCTAssertEqual(ScheduleAutomaticWeekPolicy.clamped(-12), -12)
        XCTAssertEqual(ScheduleAutomaticWeekPolicy.clamped(8), 8)
        XCTAssertEqual(ScheduleAutomaticWeekPolicy.clamped(20), 20)
        XCTAssertEqual(ScheduleAutomaticWeekPolicy.clamped(25), 20)

        // 手动翻页没有学期或课程周数上限。
        XCTAssertEqual(ScheduleWeekCodec.nextWeek(after: 25), 26)
        XCTAssertEqual(ScheduleWeekCodec.previousWeek(before: -12), -13)
    }

    func testUnpublishedScheduleResponsePreservesSchoolMessage() throws {
        let data = #"{"datas":{"cxxszhxqkb":{"extParams":{"code":3,"msg":"此学年学期的课表未发布"},"rows":[]}}}"#.data(using: .utf8)!
        let response = try JSONDecoder().decode(CourseResponse.self, from: data)
        XCTAssertTrue(response.datas.cxxszhxqkb.rows.isEmpty)
        XCTAssertEqual(response.datas.cxxszhxqkb.extParams?.code, 3)
        XCTAssertEqual(response.datas.cxxszhxqkb.extParams?.msg, "此学年学期的课表未发布")
        XCTAssertEqual(ScheduleService.schoolBusinessErrorMessage(from: data), "此学年学期的课表未发布")
        XCTAssertTrue(ScheduleServiceError.schoolResponse("此学年学期的课表未发布").isUnpublishedCourseSchedule)
        XCTAssertFalse(ScheduleNotice(title: "课表暂未发布", message: "此学年学期的课表未发布").allowsDiagnostics)
    }

    func testSchoolBusinessInspectorDoesNotRejectSuccessfulOrLegitimateEmptyResponses() {
        let success = #"{"datas":{"rows":[]},"code":"0"}"#.data(using: .utf8)!
        let nestedSuccess = #"{"datas":{"rows":[],"extParams":{"code":1}},"code":"0"}"#.data(using: .utf8)!
        XCTAssertNil(ScheduleService.schoolBusinessErrorMessage(from: success))
        XCTAssertNil(ScheduleService.schoolBusinessErrorMessage(from: nestedSuccess))
    }

    func testCourseReplacementRequiresNewCourseAndNoStrictReduction() {
        let old = course(id: "1", name: "高数")
        let added = course(id: "2", name: "英语")
        XCTAssertFalse(CourseSyncReplacementPolicy.shouldReplace(existing: [old], with: []))
        XCTAssertFalse(CourseSyncReplacementPolicy.shouldReplace(existing: [old], with: [old]))
        XCTAssertTrue(CourseSyncReplacementPolicy.shouldReplace(existing: [old], with: [old, added]))
        XCTAssertTrue(CourseSyncReplacementPolicy.shouldReplace(existing: [old], with: [added]))
        XCTAssertFalse(CourseSyncReplacementPolicy.shouldReplace(existing: [old, added], with: [old]))
    }

    func testReducedPublishedCourseResponseRequiresConfirmation() {
        let old = course(id: "1", name: "高数")
        let added = course(id: "2", name: "英语")

        XCTAssertEqual(
            CourseSyncReplacementPolicy.decision(existing: [old, added], with: [old]),
            .confirm(existingCount: 2, incomingCount: 1)
        )
        XCTAssertEqual(
            CourseSyncReplacementPolicy.decision(existing: [old], with: []),
            .preserve
        )
    }

    private func course(id: String, name: String) -> CourseRecord {
        CourseRecord(id: id, term: "2024-2025-1", name: name, teacher: "教师", classroom: "教室",
                     description: "", weeks: [1, 2], weekday: 1, startSection: 1, endSection: 2,
                     campus: "", number: id, credit: 1, hour: 16, type: "", category: "", department: "")
    }
}
