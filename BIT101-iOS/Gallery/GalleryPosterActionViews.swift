//
//  GalleryPosterActionViews.swift
//  BIT101-iOS
//
//  Split from GalleryRootView.swift.
//

import SwiftUI

/// 帖子卡片右上角的更多操作菜单，只保留作者自己的删除入口。
///
/// 删除帖子是条件出现的能力，因此统一放在这个菜单里按场景裁剪。
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

/// 搜索输入框。
///
/// 输入框本体、自定义排序按钮和清空按钮都集中在这里，避免搜索页本身承载过多细节。
