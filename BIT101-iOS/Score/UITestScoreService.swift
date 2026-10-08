import ScoreDomain
import ClientCore
import ScoreFeature
#if BIT101_UI_TESTING
import Foundation
import UIKit

struct UITestScoreService: ScoreListServicing, TrustedTranscriptServicing {
    let transcriptServiceIdentity: AnyHashable = UUID()
    private static let challenge = BITLoginAuthenticationChallenge(
        challengeID: "ui-test-score-challenge",
        accessToken: "ui-test-score-token",
        status: "sms_required",
        maskedPhone: "138****0000",
        expiresIn: 600
    )

    func startScoreChallenge() async throws -> BITLoginAuthenticationChallenge {
        throw ScoreServiceError.secondFactorRequired(Self.challenge)
    }

    func fetchScores(
        detail: Bool,
        authenticatedBy challenge: BITLoginAuthenticationChallenge
    ) async throws -> [ScoreRow] {
        [
            ScoreRow(
                index: 1,
                headers: ["课程编号", "课程名称", "开课学期", "成绩", "学分", "课程性质"],
                values: ["UI-001", "自动化测试课程", "ui-test-term", "92", "3", "必修"]
            ),
        ]
    }

    func submitScoreSMSCode(
        _ code: String,
        for challenge: BITLoginAuthenticationChallenge
    ) async throws -> BITLoginAuthenticationChallenge {
        guard code == "123456" else {
            throw ScoreServiceError.queryFailed("测试验证码错误。")
        }
        return Self.challenge
    }

    func fetchTrustedTranscriptPages() async throws -> [Data] {
        throw ScoreServiceError.secondFactorRequired(Self.challenge)
    }

    func submitTranscriptSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> [Data] {
        _ = try await submitScoreSMSCode(code, for: challenge)
        return [UIColor.systemBlue, UIColor.systemOrange].map { color in
            UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400)).pngData { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
            }
        }
    }
}
#endif
