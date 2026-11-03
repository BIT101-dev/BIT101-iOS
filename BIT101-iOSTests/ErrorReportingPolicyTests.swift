import ClientCore
import CommunityCore
import CommunityTransport
import CoreLocation
import DesignSystemKit
import GalleryFeature
import PaperFeature
import ScheduleDomain
import SchedulePorts
import ScoreDomain
import ScorePorts
import SwiftUI
import Testing
import TransportCore
import UIKit
import XCTest

@testable import BIT101_iOS
@testable import MapFeature
@testable import ScheduleFeature
@testable import ScheduleInfrastructure
@testable import ScoreFeature

extension ErrorReportAndSchedulePolicyTests {
    @MainActor
    func testTranscriptPreparesEveryBudget() async throws {
        let page = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 128)).pngData {
            context in
            UIColor.label.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 128))
        }
        let model = TrustedTranscriptViewModel(
            service: TranscriptPageService(pages: [page, page]),
            limits: .init(maximumDecodedBytes: 4_096))
        await model.apply()
        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.images.count, 2)
        let bitmaps = try model.images.map { try XCTUnwrap($0.cgImage) }
        XCTAssertLessThanOrEqual(bitmaps.reduce(0) { $0 + $1.bytesPerRow * $1.height }, 4_096)
        for bitmap in bitmaps {
            XCTAssertLessThan(bitmap.width, 256)
            XCTAssertEqual(Double(bitmap.width) / Double(bitmap.height), 2, accuracy: 0.2)
        }
    }

    @MainActor
    func testTranscriptRejectsExcessPagesBytes() async {
        let page = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).pngData { _ in }
        for limits in [
            TrustedTranscriptResourceLimits(maximumPageCount: 1),
            .init(maximumEncodedBytes: page.count * 2 - 1), .init(maximumDecodedBytes: 3),
        ] {
            let model = TrustedTranscriptViewModel(
                service: TranscriptPageService(pages: [page, page]), limits: limits)
            await model.apply()
            guard case .failed = model.state else {
                XCTFail("Expected transcript resource limit failure")
                continue
            }
            XCTAssertTrue(model.images.isEmpty)
        }
    }

    func testCalendarPermissionNoticeSettings() {
        XCTAssertTrue(ScheduleSystemCalendarError.permissionDenied.requiresCalendarSettings)
        XCTAssertTrue(ScheduleSystemCalendarError.noWritableCalendarSource.requiresCalendarSettings)
        XCTAssertFalse(ScheduleSystemCalendarError.missingSchedule.requiresCalendarSettings)
        XCTAssertEqual(
            ScheduleNotice(
                title: "导入失败",
                message: "日历权限需要调整。",
                recoveryAction: .openAppSettings
            ).recoveryAction, .openAppSettings)
    }

    func testCertificateFailureIsNotAsExpiredVerify() {
        let error = ScheduleServiceError.challengeInvalid(
            """
            HTTPSConnectionPool(host='webvpn.bit.edu.cn'): SSLCertVerificationError: certificat\
            e has expired
            """
        )

        XCTAssertTrue(error.isSchoolTransportFailure)
        let notice = ScheduleNotice(
            title: "学校服务连接失败",
            message: error.schoolTransportFailureMessage
        )
        XCTAssertTrue(notice.allowsDiagnostics)
    }

    func testSchoolBusinessInspectorResponses() {
        let success = Data(#"{"datas":{"rows":[]},"code":"0"}"#.utf8)
        let nestedSuccess = Data(#"{"datas":{"rows":[],"extParams":{"code":1}},"code":"0"}"#.utf8)
        let alternateSuccessCode = Data(
            #"{"datas":{"rows":[],"extParams":{"code":2,"msg":"查询成功"}},"code":"0"}"#.utf8
        )
        XCTAssertNil(ScheduleService.schoolBusinessError(from: success))
        XCTAssertNil(ScheduleService.schoolBusinessError(from: nestedSuccess))
        XCTAssertNil(ScheduleService.schoolBusinessError(from: alternateSuccessCode))
    }

    func testRealDeviceCourseIsRecognizedAsSuccess() throws {
        // 真机 schedule smoke 响应；学生学号与姓名字段已脱敏。
        let bundle = Bundle(for: ErrorReportAndSchedulePolicyTests.self)
        let fixtureURL =
            bundle.url(
                forResource: "schedule-service-response",
                withExtension: "json",
                subdirectory: "Fixtures"
            ) ?? bundle.url(forResource: "schedule-service-response", withExtension: "json")
        let fixture = try XCTUnwrap(fixtureURL)
        let data = try Data(contentsOf: fixture)
        let response = try JSONDecoder().decode(CourseResponse.self, from: data)

        XCTAssertEqual(response.datas.cxxszhxqkb.extParams?.code, 1)
        XCTAssertEqual(response.datas.cxxszhxqkb.extParams?.msg, "查询成功")
        XCTAssertEqual(response.datas.cxxszhxqkb.rows.count, 14)
        XCTAssertNil(ScheduleService.schoolBusinessError(from: data))

        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let datas = try XCTUnwrap(root["datas"] as? [String: Any])
        let timetable = try XCTUnwrap(datas["cxxszhxqkb"] as? [String: Any])
        let rows = try XCTUnwrap(timetable["rows"] as? [[String: Any]])
        XCTAssertTrue(rows.allSatisfy { $0["XH"] == nil && $0["XM"] == nil })
    }

    func testSchoolBusinessInspectorIgnoresRows() {
        let data = Data(#"{"datas":{"cxxszhxqkb":{"rows":[{"msg":"课程暂未发布说明"}]}}}"#.utf8)

        XCTAssertNil(ScheduleService.schoolBusinessError(from: data))
    }

    func testSchoolBusinessInspectorStatus() {
        let data = Data(#"{"data":{"success":false,"code":0,"msg":"学校服务当前不可用"}}"#.utf8)
        let failureMessageWithSuccessCode = Data(#"{"code":0,"msg":"课表查询失败"}"#.utf8)

        XCTAssertEqual(
            ScheduleService.schoolBusinessError(from: data),
            "学校服务当前不可用"
        )
        XCTAssertEqual(
            ScheduleService.schoolBusinessError(from: failureMessageWithSuccessCode),
            "课表查询失败"
        )
    }

    func testSchoolBusinessIgnoresStatusEnvelopes() {
        let data = Data(#"{"data":{"metadata":{"code":9,"msg":"仅供诊断的字段"}}}"#.utf8)

        XCTAssertNil(ScheduleService.schoolBusinessError(from: data))
    }

    func testSchoolBusinessInspectorFields() {
        let data = Data(#"{"DATA":{"ExtParams":{"CODE":"3","MSG":"查询失败"}}}"#.utf8)

        XCTAssertEqual(
            ScheduleService.schoolBusinessError(from: data),
            "查询失败"
        )
    }

    func testSchoolBusinessInspectorUsesTypedValues() {
        let numericFlag = Data(#"{"success":0,"msg":"查询成功"}"#.utf8)
        let fractionalCode = Data(#"{"code":2.5,"msg":"其他提示"}"#.utf8)
        let englishFailure = Data(#"{"data":{"message":"Request failed"}}"#.utf8)

        XCTAssertNil(ScheduleService.schoolBusinessError(from: numericFlag))
        XCTAssertNil(ScheduleService.schoolBusinessError(from: fractionalCode))
        XCTAssertEqual(
            ScheduleService.schoolBusinessError(from: englishFailure),
            "Request failed"
        )
    }

    func testSchoolBusinessDeterministically() {
        let data = Data(
            #"""
            {"datas":{"z":{"extParams":{"code":3,"msg":"课表暂未发布"}},"a":{"extParams":{"code":4,"\#
            msg":"此学年学期的课表未发布"}}}}
            """#
            .utf8
        )
        let messageInDataEnvelope = Data(#"{"datas":{"msg":"本学期课表未发布"}}"#.utf8)

        XCTAssertEqual(
            ScheduleService.schoolBusinessError(from: data),
            "此学年学期的课表未发布"
        )
        XCTAssertEqual(
            ScheduleService.schoolBusinessError(from: messageInDataEnvelope),
            "本学期课表未发布"
        )
    }
}
