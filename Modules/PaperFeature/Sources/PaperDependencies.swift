import CommunityCore
import CommunityTransport
import TransportCore
import Observation

/// 文章页面按列表、详情和编辑场景注入服务。
@MainActor
@Observable
public final class PaperDependencies {
    let list: any PaperListServicing
    let detail: any PaperDetailServicing
    let composer: any PaperComposerServicing
    let drafts: any PaperComposerDraftStoring & ComposerPublicationStoring
    let networkPath: NetworkPathState
    let currentIdentity: () -> CommunitySessionIdentity

    public init(list: any PaperListServicing, detail: any PaperDetailServicing, composer: any PaperComposerServicing, drafts: any PaperComposerDraftStoring & ComposerPublicationStoring, networkPath: NetworkPathState, currentIdentity: @escaping () -> CommunitySessionIdentity) {
        self.list = list
        self.detail = detail
        self.composer = composer
        self.drafts = drafts
        self.networkPath = networkPath
        self.currentIdentity = currentIdentity
    }
}
