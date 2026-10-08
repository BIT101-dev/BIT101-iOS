import ScoreDomain
import ScoreFeature
import TransportCore
import DesignSystemKit
//
//  ContentView.swift
//  BIT101-iOS
//
//  Created by Harry Bit on 2026-03-24.
//

import SwiftUI

/// 提供应用内展示的 ICP 备案号和工信部备案管理系统入口，供用户核验备案信息。
enum AppLegalInfo {
    static let icpDisplayText = "京ICP备2026016481号"
    static let icpPublicNoticeURL = AppURL.required("https://beian.miit.gov.cn/")
}

/// 应用根容器持有会话状态，组装登录页和登录后壳层。
struct ContentView: View {
    let transcriptService: any TrustedTranscriptServicing
    @ObservedObject var localData: AppLocalDataService
    @StateObject private var loginViewModel = LoginViewModel()

    var body: some View {
        Group {
            switch loginViewModel.screenState {
            case .signedOut:
                LoginRootView(viewModel: loginViewModel)
            case let .signedIn(studentID):
                AppShellView(transcriptService: transcriptService, studentID: studentID, onLogout: loginViewModel.logout)
            }
        }
        .disabled(localData.isCleaning)
        .allowsHitTesting(!localData.isCleaning)
        .overlay {
            if localData.isCleaning {
                AppLoadingState(title: "正在清理本机数据")
                    .background(.regularMaterial)
            }
        }
        .task { await loginViewModel.bootstrapIfNeeded() }
        .diagnosticAlert(item: $loginViewModel.alert)
        .appDiagnosticRecoveryActions()
        .defaultAppStorage(AppFileDirectories.defaults)
    }
}
