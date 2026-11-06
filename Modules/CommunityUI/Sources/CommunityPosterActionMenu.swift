#if os(iOS)
import DesignSystemKit
import SwiftUI

/// 帖子卡片右上角的更多操作菜单提供作者删除入口。
///
/// 菜单按当前帖子场景条件显示删除入口。
public struct CommunityPosterActionMenu: View {
    let onDelete: (() -> Void)?
    let onReport: (() -> Void)?

    public init(onDelete: (() -> Void)? = nil, onReport: (() -> Void)? = nil) {
        self.onDelete = onDelete
        self.onReport = onReport
    }

    public var body: some View {
        Menu {
            menuActions
        } label: {
            menuLabel
        }
        .accessibilityIdentifier("ui.community-poster-action-menu.menu")
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
            .frame(
                width: AppDesignSystem.Size.Control.touchTarget,
                height: AppDesignSystem.Size.Control.touchTarget
            )
            .accessibilityLabel("更多操作")
    }
}

#endif
