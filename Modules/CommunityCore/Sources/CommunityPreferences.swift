import Combine
import Foundation

public struct CommunityPreferenceSnapshot: Equatable {
    public var galleryHideBotPosterInSearch: Bool
    public var galleryHiddenUserIDs: [Int]
    public var galleryHideAnonymousContent: Bool
    public var galleryUseWebView: Bool
    public var hidesCourseHistoryMakeupOutliers: Bool

    public init(hideBots: Bool, hiddenUserIDs: [Int], hideAnonymous: Bool, useWebView: Bool, hideMakeupOutliers: Bool) {
        galleryHideBotPosterInSearch = hideBots
        galleryHiddenUserIDs = hiddenUserIDs
        galleryHideAnonymousContent = hideAnonymous
        galleryUseWebView = useWebView
        hidesCourseHistoryMakeupOutliers = hideMakeupOutliers
    }
}

public final class CommunityPreferences: ObservableObject {
    @Published public private(set) var snapshot: CommunityPreferenceSnapshot
    private let saveMakeupFilter: (Bool) -> Void

    public init(snapshot: CommunityPreferenceSnapshot, saveMakeupFilter: @escaping (Bool) -> Void) {
        self.snapshot = snapshot
        self.saveMakeupFilter = saveMakeupFilter
    }

    public func apply(_ snapshot: CommunityPreferenceSnapshot) { self.snapshot = snapshot }
    public var galleryUseWebView: Bool { snapshot.galleryUseWebView }
    public var hidesCourseHistoryMakeupOutliers: Bool { snapshot.hidesCourseHistoryMakeupOutliers }
    public func setHidesCourseHistoryMakeupOutliers(_ enabled: Bool) { saveMakeupFilter(enabled) }
}

/// 课程详情用于学分展示的学校课程摘要。
public nonisolated struct CommunityCourseCredit: Sendable {
    public let number: String
    public let name: String
    public let credit: Double

    public init(number: String, name: String, credit: Double) {
        self.number = number
        self.name = name
        self.credit = credit
    }
}

