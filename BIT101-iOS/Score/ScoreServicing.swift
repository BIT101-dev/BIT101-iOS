import Foundation

protocol ScoreListServicing {
    func startScoreChallenge() async throws -> BITLoginAuthenticationChallenge
    func fetchScores(
        detail: Bool,
        authenticatedBy challenge: BITLoginAuthenticationChallenge
    ) async throws -> [ScoreRow]
    func submitScoreSMSCode(
        _ code: String,
        for challenge: BITLoginAuthenticationChallenge
    ) async throws -> BITLoginAuthenticationChallenge
}

protocol TrustedTranscriptServicing {
    func fetchTrustedTranscriptPages() async throws -> [Data]
    func submitTranscriptSMSCode(
        _ code: String,
        for challenge: BITLoginAuthenticationChallenge
    ) async throws -> [Data]
}

extension ScoreService: ScoreListServicing, TrustedTranscriptServicing {}
