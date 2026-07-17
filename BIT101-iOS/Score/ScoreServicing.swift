import Foundation

protocol ScoreListServicing {
    func fetchScores(detail: Bool) async throws -> [ScoreRow]
    func submitSMSCode(
        _ code: String,
        for challenge: BITLoginAuthenticationChallenge,
        detail: Bool
    ) async throws -> [ScoreRow]
}

protocol TrustedTranscriptServicing {
    func fetchTrustedTranscript() async throws -> URL
    func submitTranscriptSMSCode(
        _ code: String,
        for challenge: BITLoginAuthenticationChallenge
    ) async throws -> URL
    func downloadTrustedTranscript(from url: URL) async throws -> Data
}

extension ScoreService: ScoreListServicing, TrustedTranscriptServicing {}
