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

/// 应用根容器，由登录模块根据会话状态显示登录页或登录后壳层。
struct ContentView: View {
    var body: some View {
        LoginRootView()
    }
}
