import ScoreDomain
import ScorePorts
import ClientCore
import ScoreFeature
#if BIT101_UI_TESTING
import Foundation
import UIKit

struct UITestScoreService: ScoreListServicing, TrustedTranscriptServicing {
    let transcriptServiceIdentity: AnyHashable = UUID()
    private static var transcriptFailureScene: Int?
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

    func fetchTrustedTranscriptPages(onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages {
        throw ScoreServiceError.secondFactorRequired(Self.challenge)
    }

    func submitTranscriptSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> BITLoginAuthenticationChallenge {
        _ = try await submitScoreSMSCode(code, for: challenge)
        return challenge
    }
    func fetchTrustedTranscriptPages(authenticatedBy challenge: BITLoginAuthenticationChallenge, onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages {
        let pages = [UIColor.systemBlue, UIColor.systemOrange].map { color in
            UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400)).pngData { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
            }
        }
        let scene = UITestSceneConfiguration.shared.snapshot
        if scene.environment["BIT101_UI_TEST_TRANSCRIPT_FAILURE_ONCE"] == "1", Self.transcriptFailureScene != scene.revision {
            Self.transcriptFailureScene = scene.revision
            return .init(pages: [.init(number: 1, data: pages[0])], expectedPageCount: 2, failure: URLError(.networkConnectionLost))
        }
        return .init(pages)
    }
}
#endif
