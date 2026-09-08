//
//  GalleryPosterActionViews.swift
//  BIT101-iOS
//
//  Split from GalleryRootView.swift.
//

import SwiftUI

/// 帖子卡片右上角的更多操作菜单提供作者删除入口。
///
/// 菜单按当前帖子场景条件显示删除入口。
struct GalleryPosterActionMenu: View {
    let onDelete: (() -> Void)?
    @State private var isPresentingFallbackActions = false

    var body: some View {
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
        if let onDelete {
            Button("删除帖子", systemImage: "trash", role: .destructive) {
                onDelete()
            }
        }
    }

    private var menuLabel: some View {
        Image(systemName: "ellipsis.circle")
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(width: AppDesignSystem.Size.control.detailActionButton, height: AppDesignSystem.Size.control.detailActionButton)
    }
}
