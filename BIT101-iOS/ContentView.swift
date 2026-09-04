//
//  ContentView.swift
//  BIT101-iOS
//
//  Created by Harry Bit on 2026-03-24.
//

import SwiftUI

/// 应用内复用的法务信息。
///
/// ICP 备案号统一跳转到工信部备案管理系统公共入口，便于用户自行核验公示内容。
enum AppLegalInfo {
    static let icpDisplayText = "京ICP备2026016481号"
    static let icpPublicNoticeURL = AppURL.required("https://beian.miit.gov.cn/")
}

/// 根容器视图。
///
/// 目前整个应用都从登录态入口开始，后续如果增加启动广告、全局路由，
/// 也会优先从这里接入。
///
/// 这个文件故意保持极薄：`App` 入口负责场景级副作用，真正的业务壳层和登录判断
/// 交给下一级视图。这样后续如果要插入开屏页、实验性全局路由或者调试包装层，
/// 只需要改这里，不必去扰动 `BIT101_iOSApp` 的生命周期代码。
struct ContentView: View {
    /// 应用根节点当前只承载登录模块。
    ///
    /// 登录成功后，后续导航全部交给 `LoginRootView` 内部的壳层处理。
    /// 之所以不在 `ContentView` 内部直接判断登录态，是为了让登录模块自己管理
    /// “已登录 / 未登录 / 恢复会话中”这些状态机，避免根视图逐步膨胀成总控层。
    var body: some View {
        LoginRootView()
    }
}
