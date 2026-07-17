import SwiftUI

/// 昵称和个性签名复用的文本编辑弹层。
struct SettingsTextEditSheet: View {
    let title: String
    @Binding var text: String
    var axis: Axis = .horizontal
    let onSubmit: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField(title, text: $text, axis: axis)
                    .lineLimit(axis == .vertical ? 4 : 1, reservesSpace: axis == .vertical)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("确定", action: onSubmit)
                }
            }
        }
    }
}

/// 已隐藏用户的展示和恢复入口。
struct HiddenUsersPage: View {
    let hiddenUsers: [MineUserInfo]
    let isLoading: Bool
    let onReshow: (Int) -> Void

    var body: some View {
        List {
            if isLoading {
                ProgressView("正在加载")
            } else if hiddenUsers.isEmpty {
                ContentUnavailableView("隐藏用户列表为空", systemImage: "person.crop.circle.badge.minus")
            } else {
                ForEach(Array(hiddenUsers.enumerated()), id: \.element.user.id) { index, info in
                    HStack(spacing: 12) {
                        CachedRemoteImage(url: URL(string: info.user.avatar.lowUrl.isEmpty ? info.user.avatar.url : info.user.avatar.lowUrl)) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Circle().fill(Color.blue.opacity(0.15))
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 4) {
                            Text(info.user.nickname)
                            Text(info.user.motto)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("显示") { onReshow(index) }
                    }
                }
            }
        }
        .navigationTitle("隐藏用户列表")
    }
}

/// 已隐藏帖子的展示和恢复入口。
struct HiddenPostersPage: View {
    let hiddenPosters: [HiddenPosterRecord]
    let onReshow: (Int) -> Void

    var body: some View {
        List {
            if hiddenPosters.isEmpty {
                ContentUnavailableView("隐藏帖子列表为空", systemImage: "eye.slash")
            } else {
                ForEach(Array(hiddenPosters.enumerated()), id: \.element.id) { index, poster in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(poster.title.isEmpty ? "未命名帖子" : poster.title)
                            .font(.headline)
                        Text("作者：\(poster.userNickname)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("恢复显示") {
                            onReshow(index)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("隐藏帖子列表")
    }
}
