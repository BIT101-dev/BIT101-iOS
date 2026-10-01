import CommunityCore
#if os(iOS)
import CommunityUI
import CommunityTransport
import TransportCore
import Observation

/// 话廊按首页、消息、详情、举报、编辑和图片上传分别注入服务。
@MainActor
@Observable
public final class GalleryDependencies {
    let session: CommunitySession
    let feed: any GalleryFeedServicing
    let messageService: any GalleryMessageServicing
    let posterDetail: any GalleryPosterDetailServicing
    let reporting: any GalleryReportServicing
    let composer: any GalleryComposerServicing
    let images: any GalleryImageUploading
    let preferences: CommunityPreferences
    let messages: any GalleryMessageReadStoring
    let drafts: any GalleryComposerDraftStoring
    let networkPath: NetworkPathState

    public init(
        session: CommunitySession,
        feed: any GalleryFeedServicing,
        messageService: any GalleryMessageServicing,
        posterDetail: any GalleryPosterDetailServicing,
        reporting: any GalleryReportServicing,
        composer: any GalleryComposerServicing,
        images: any GalleryImageUploading,
        preferences: CommunityPreferences,
        messages: any GalleryMessageReadStoring,
        drafts: any GalleryComposerDraftStoring,
        networkPath: NetworkPathState
    ) {
        self.session = session
        self.feed = feed
        self.messageService = messageService
        self.posterDetail = posterDetail
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
