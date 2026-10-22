#if os(iOS)
import MediaKit
import SwiftUI

/// 消息与外部资源入口直接进入文章详情。
public struct PaperDetailDestination: View {
    private let detail: PaperDetailView

    public init(dependencies: PaperDependencies, media: MediaEnvironment, paperID: Int) {
        detail = PaperDetailView(dependencies: dependencies, media: media,
            initialPaper: PaperSummary(id: paperID, title: "文章", intro: "", likeNum: 0, commentNum: 0,
                updateTime: ""), onChanged: {})
    }

    public var body: some View { detail }
}
#endif
