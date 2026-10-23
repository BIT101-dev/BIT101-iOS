#if os(iOS)
import Combine
import CommunityCore
import Observation
import SwiftUI

/// Each navigation capability follows its consumer's page boundary.
@MainActor
@Observable
public final class CommunityProfileDestination {
    public let profile: (Int) -> AnyView
    public init(profile: @escaping (Int) -> AnyView) { self.profile = profile }
}

@MainActor
@Observable
public final class CommunityPosterDestination {
    public let poster: (CommunityPosterRequest) -> AnyView
    public init(poster: @escaping (CommunityPosterRequest) -> AnyView) { self.poster = poster }
}

public struct CommunityPosterRequest {
    public let poster: CommunityPoster
    public let onUpdated: (() -> Void)?
    public let onDeleted: (() -> Void)?

    public init(poster: CommunityPoster, onUpdated: (() -> Void)? = nil, onDeleted: (() -> Void)? = nil) {
        self.poster = poster; self.onUpdated = onUpdated; self.onDeleted = onDeleted
    }
}

@MainActor
public struct CommunityPaperDestination {
    public let papers: (Binding<Int?>, @escaping () -> Void) -> AnyView
    public let detail: (Int) -> AnyView
    public init(papers: @escaping (Binding<Int?>, @escaping () -> Void) -> AnyView,
        detail: @escaping (Int) -> AnyView) {
        self.papers = papers
        self.detail = detail
    }
}

@MainActor
public struct CommunityCourseDestination {
    public let course: (Int) -> AnyView
    public init(course: @escaping (Int) -> AnyView) { self.course = course }
}

@MainActor
public struct CommunitySettingsDestinations {
    public let settingsEntries: [CommunitySettingsEntry]
    public let settings: (CommunitySettingsRequest) -> AnyView
    public let suggestion: () -> AnyView

    public init(settingsEntries: [CommunitySettingsEntry],
                settings: @escaping (CommunitySettingsRequest) -> AnyView,
                suggestion: @escaping () -> AnyView) {
        self.settingsEntries = settingsEntries
        self.settings = settings
        self.suggestion = suggestion
    }
}

public struct CommunitySettingsEntry: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let systemImage: String

    public init(id: String, title: String, systemImage: String) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
    }
}

public struct CommunitySettingsRequest {
    public let entry: CommunitySettingsEntry
    public let studentID: String
    public let onLogout: () -> Void

    public init(entry: CommunitySettingsEntry, studentID: String, onLogout: @escaping () -> Void) {
        self.entry = entry
        self.studentID = studentID
        self.onLogout = onLogout
    }
}

#endif
