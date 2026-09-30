#if os(iOS)
import DesignSystemKit
import SwiftUI

/// 帖子卡片右上角的更多操作菜单提供作者删除入口。
///
/// 菜单按当前帖子场景条件显示删除入口。
public struct CommunityPosterActionMenu: View {
    let onDelete: (() -> Void)?
    let onReport: (() -> Void)?
    @State private var isPresentingFallbackActions = false

    public init(onDelete: (() -> Void)? = nil, onReport: (() -> Void)? = nil) {
        self.onDelete = onDelete
        self.onReport = onReport
    }

    public var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                Menu {
                    menuActions
                } label: {
                    menuLabel
                }
            } else {
                Button {
                    isPresentingFallbackActions = true
                } label: {
                    menuLabel
                }
                .confirmationDialog("", isPresented: $isPresentingFallbackActions, titleVisibility: .hidden) {
                    menuActions
                    Button("取消", role: .cancel) {}
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var menuActions: some View {
        if let onReport {
            Button("举报帖子", systemImage: "exclamationmark.bubble") {
                onReport()
            }
        }
        if let onDelete {
            Button("删除帖子", systemImage: "trash", role: .destructive) {
                onDelete()
            }
        }
    }

    private var menuLabel: some View {
        Image(systemName: "ellipsis.circle")
            .font(AppDesignSystem.Typography.title)
            .foregroundStyle(AppDesignSystem.Foreground.secondary)
            .frame(width: AppDesignSystem.Size.Control.detailActionButton, height: AppDesignSystem.Size.Control.detailActionButton)
            .accessibilityLabel("更多操作")
    }
}


#endif
