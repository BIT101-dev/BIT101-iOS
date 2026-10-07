import CommunityTransport
import ScheduleSync
import Combine
import Foundation

/// 同步状态随所选账号事件重置，迟到报告按完整账号代际筛选。
@MainActor
final class ScheduleCloudSyncPresentation: ObservableObject {
    @Published private(set) var status: ScheduleCloudSyncStatus = .idle
    private let currentAccount: () -> ScheduleCloudAccount?
    private var subscription: AnyCancellable?

    init(currentAccount: @escaping () -> ScheduleCloudAccount?, accountChanges: AnyPublisher<CommunitySessionIdentity, Never>) {
        self.currentAccount = currentAccount
        subscription = accountChanges.sink { [weak self] identity in
            guard let self else { return }
            if let account = self.currentAccount() {
                guard account.studentID == identity.accountIdentifier, account.generation == identity.generation else { return }
            } else {
                guard identity.accountIdentifier.isEmpty else { return }
            }
            self.status = .idle
        }
    }

    func receive(account: ScheduleCloudAccount, status: ScheduleCloudSyncStatus) {
        guard account == currentAccount() else { return }
        self.status = status
    }

    var message: String {
        switch status {
        case .idle: "课表同步已开启，编辑后同步到 iCloud。"
        case .syncing: "正在同步课表…"
        case .pending: "课表保留在本机，等待完成 iCloud 同步。"
        case .synchronized: "课表已与 iCloud 同步。"
        case .unavailable: "请在系统设置中登录 iCloud 后继续同步。"
        case .conflict: "本机与 iCloud 课表存在版本差异，请选择保留的版本。"
        case .failed(let reason): "iCloud 同步失败：\(reason)"
        }
    }
}
