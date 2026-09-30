import CommunityCore
import CommunityTransport
import Observation

/// 文章页面按列表、详情和编辑场景注入服务。
@MainActor
@Observable
public final class PaperDependencies {
    let list: any PaperListServicing
    let detail: any PaperDetailServicing
    let composer: any PaperComposerServicing

    public init(list: any PaperListServicing, detail: any PaperDetailServicing, composer: any PaperComposerServicing) {
        self.list = list
        self.detail = detail
        self.composer = composer
    }
}

