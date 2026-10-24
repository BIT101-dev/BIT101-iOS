import CommunityCore
#if os(iOS)
import CommunityUI
import Combine
import CommunityTransport
import TransportCore
import Observation

/// 话廊按首页、消息、详情、举报、编辑和图片上传分别注入服务。
public struct GalleryWebCredentials {
    let cookie: () -> String
    let changes: AnyPublisher<Void, Never>
    public init(cookie: @escaping () -> String, changes: AnyPublisher<Void, Never>) {
        self.cookie = cookie
        self.changes = changes
    }
}

@MainActor
@Observable
public final class GalleryDependencies {
    let webCredentials: GalleryWebCredentials
    let currentIdentity: () -> CommunitySessionIdentity
    let feed: any GalleryFeedServicing
    let messageService: any GalleryMessageServicing
    let posterDetail: any GalleryPosterDetailServicing
    let subscriptions: any GallerySubscriptionServicing
    let reporting: any GalleryReportServicing
    let composer: any GalleryComposerServicing
    let images: any GalleryImageUploading
    let preferences: CommunityPreferences
    let messages: any GalleryMessageReadStoring
    let drafts: any GalleryComposerDraftStoring & ComposerPublicationStoring
    let networkPath: NetworkPathState

    public init(
        webCredentials: GalleryWebCredentials,
        currentIdentity: @escaping () -> CommunitySessionIdentity,
        feed: any GalleryFeedServicing,
        messageService: any GalleryMessageServicing,
        posterDetail: any GalleryPosterDetailServicing,
        subscriptions: any GallerySubscriptionServicing,
        reporting: any GalleryReportServicing,
        composer: any GalleryComposerServicing,
        images: any GalleryImageUploading,
        preferences: CommunityPreferences,
        messages: any GalleryMessageReadStoring,
        drafts: any GalleryComposerDraftStoring & ComposerPublicationStoring,
        networkPath: NetworkPathState
    ) {
        self.webCredentials = webCredentials
        self.currentIdentity = currentIdentity
        self.feed = feed
        self.messageService = messageService
        self.posterDetail = posterDetail
        self.subscriptions = subscriptions
        self.reporting = reporting
        self.composer = composer
        self.images = images
        self.preferences = preferences
        self.messages = messages
        self.drafts = drafts
        self.networkPath = networkPath
    }
}

#endif
