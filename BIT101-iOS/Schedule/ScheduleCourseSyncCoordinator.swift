import Foundation

/// Work that must resume after teaching-center SMS authentication succeeds.
enum ScheduleAuthenticationContinuation: Equatable {
    case courseSync(term: String?)
    case availableTerms
    case classroomRefresh
}

/// Keeps authentication continuation state out of the main schedule view model.
@MainActor
final class ScheduleCourseSyncCoordinator {
    private(set) var continuation: ScheduleAuthenticationContinuation?

    var courseSyncTerm: String? {
        guard case let .courseSync(term) = continuation else { return nil }
        return term
    }

    func waitForCourseAuthentication(term: String?) {
        continuation = .courseSync(term: term)
    }

    func waitForAvailableTermsAuthentication() {
        continuation = .availableTerms
    }

    func waitForClassroomAuthentication() {
        continuation = .classroomRefresh
    }

    func reset() {
        continuation = nil
    }
}
