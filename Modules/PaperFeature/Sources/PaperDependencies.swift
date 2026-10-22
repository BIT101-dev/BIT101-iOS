import CommunityCore
import TransportCore
import Observation

/// 文章页面按列表、详情和编辑场景注入服务。
@MainActor
@Observable
public final class PaperDependencies {
    let list: any PaperListServicing
    let detail: any PaperDetailServicing
    let composer: any PaperComposerServicing
    let drafts: any PaperComposerDraftStoring
    let networkPath: NetworkPathState

    public init(list: any PaperListServicing, detail: any PaperDetailServicing, composer: any PaperComposerServicing, drafts: any PaperComposerDraftStoring, networkPath: NetworkPathState) {
        self.list = list
        self.detail = detail
        self.composer = composer
        self.drafts = drafts
        self.networkPath = networkPath
    }
}
