#if os(iOS)
import Combine
import CommunityCore
import Observation
import SwiftUI

/// 跨社区页面的目标工厂，由应用壳层组装并沿视图环境传递。
@MainActor
@Observable
public final class CommunityDestinations {
    public let profile: (Int) -> AnyView
    public let poster: (CommunityPoster, (() -> Void)?) -> AnyView
    public let papers: (Binding<Int?>, @escaping () -> Void) -> AnyView

    public let settingsEntries: [CommunitySettingsEntry]
    public let settings: (CommunitySettingsRequest) -> AnyView
    public let suggestion: () -> AnyView

    public init(
        settingsEntries: [CommunitySettingsEntry],
        settings: @escaping (CommunitySettingsRequest) -> AnyView,
        suggestion: @escaping () -> AnyView,
        profile: @escaping (Int) -> AnyView,
        poster: @escaping (CommunityPoster, (() -> Void)?) -> AnyView,
        papers: @escaping (Binding<Int?>, @escaping () -> Void) -> AnyView
    ) {
        self.settingsEntries = settingsEntries
        self.settings = settings
        self.suggestion = suggestion
        self.profile = profile
        self.poster = poster
        self.papers = papers
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
