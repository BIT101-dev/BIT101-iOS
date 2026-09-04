import SwiftUI

/// watch 主页面。
///
/// 展示顺序保持极简：先给出“当前/下一节”的摘要，再向下列出后续课节，
/// 让用户抬腕后能先看到最关键的信息，继续滚动时再看完整一些的安排。
struct WatchScheduleRootView: View {
    @ObservedObject var model: WatchScheduleStatusModel
    @State private var isShowingClearConfirmation = false

    var body: some View {
        TabView {
            primaryPage
            actionsPage
        }
        .tabViewStyle(.page)
        .navigationTitle("课表")
        .onAppear {
            model.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .scheduleExternalSnapshotDidChange)) { _ in
            model.handleSnapshotDidChange()
        }
        .confirmationDialog("清除本地课表数据？", isPresented: $isShowingClearConfirmation, titleVisibility: .visible) {
            Button("清除", role: .destructive) {
                model.clearLocalData()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅清除手表本地缓存，不影响手机端。")
        }
    }

    private var primaryPage: some View {
        ScrollView {
            if model.contentState == .ready, let next = model.nextOccurrence {
                LazyVStack(alignment: .leading) {
                    VStack(alignment: .leading) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(next.isCurrent(at: model.referenceDate) ? "正在上课" : "下一节")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Spacer(minLength: 0)

                            Text(next.relativeDayText(referenceDate: model.referenceDate))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text(next.title)
                            .font(.title2)
                            .lineLimit(2)

                        Text(next.rangeText)
                            .font(.title2)

                        if !next.classroom.isEmpty {
                            Text(next.classroom)
                                .font(.title2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    if model.upcomingOccurrences.count > 1 {
                        Divider()
                            .padding(.vertical, 2)

                        Text("后续课节")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(Array(model.upcomingOccurrences.dropFirst())) { occurrence in
                            VStack(alignment: .leading) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(occurrence.relativeDayText(referenceDate: model.referenceDate))
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.secondary)

                                    Spacer(minLength: 4)

                                    Text(occurrence.rangeText)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.secondary)
                                }

                                Text(occurrence.title)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(2)

                                if !occurrence.classroom.isEmpty {
                                    Text(occurrence.classroom)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if model.contentState == .loggedOut {
                WatchScheduleEmptyStateView(message: "请先在手机上登录")
            } else if model.contentState == .rest {
                WatchScheduleEmptyStateView(message: "暂无后续课程")
            } else {
                WatchScheduleEmptyStateView(
                    message: "打开手机 App 同步课表",
                    actionTitle: model.refreshButtonTitle,
                    feedbackText: model.refreshFeedbackText,
                    isActionDisabled: model.isRefreshing,
                    action: {
                        model.requestRefresh()
                    }
                )
            }
        }
    }

    private var actionsPage: some View {
        VStack(spacing: 10) {
            Text("操作")
                .font(.headline)

            Button(model.refreshButtonTitle) {
                model.requestRefresh()
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isRefreshing)

            if let feedbackText = model.refreshFeedbackText {
                Text(feedbackText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("清除数据", role: .destructive) {
                isShowingClearConfirmation = true
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WatchScheduleEmptyStateView: View {
    let message: String
    var actionTitle: String? = nil
    var feedbackText: String? = nil
    var isActionDisabled = false
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            Text(message)
                .font(.headline)
                .multilineTextAlignment(.center)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .disabled(isActionDisabled)
            }

            if let feedbackText {
                Text(feedbackText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}
