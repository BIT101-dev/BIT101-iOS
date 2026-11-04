import Foundation
import Observation

public struct CommunityPreferenceSnapshot: Equatable, Hashable {
    public var galleryHideBotPosterInSearch: Bool
    public var galleryHiddenUserIDs: [Int]
    public var galleryHideAnonymousContent: Bool
    public var galleryUseWebView: Bool
    public var hidesCourseHistoryMakeupOutliers: Bool

    public init(
        hideBots: Bool, hiddenUserIDs: [Int], hideAnonymous: Bool, useWebView: Bool,
        hideMakeupOutliers: Bool
    ) {
        galleryHideBotPosterInSearch = hideBots
        galleryHiddenUserIDs = hiddenUserIDs
        galleryHideAnonymousContent = hideAnonymous
        galleryUseWebView = useWebView
        hidesCourseHistoryMakeupOutliers = hideMakeupOutliers
    }
}

@Observable public final class CommunityPreferences {
    private var applied: CommunityPreferenceSnapshot
    @ObservationIgnored private let source: (() -> CommunityPreferenceSnapshot)?
    private let saveMakeupFilter: (Bool) -> Void

    /// 有来源时直接读取来源的最新值，页面随来源的观察依赖刷新。
    public var snapshot: CommunityPreferenceSnapshot { source?() ?? applied }

    public init(snapshot: CommunityPreferenceSnapshot, saveMakeupFilter: @escaping (Bool) -> Void) {
        applied = snapshot
        source = nil
        self.saveMakeupFilter = saveMakeupFilter
    }

    public init(
        source: @escaping () -> CommunityPreferenceSnapshot,
        saveMakeupFilter: @escaping (Bool) -> Void
    ) {
        applied = source()
        self.source = source
        self.saveMakeupFilter = saveMakeupFilter
    }

    public func apply(_ snapshot: CommunityPreferenceSnapshot) { applied = snapshot }
    public var galleryUseWebView: Bool { snapshot.galleryUseWebView }
    public var hidesCourseHistoryMakeupOutliers: Bool { snapshot.hidesCourseHistoryMakeupOutliers }
    public func setHideMakeupOutliers(_ enabled: Bool) { saveMakeupFilter(enabled) }
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
