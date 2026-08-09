//
//  SettingsRootView.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import PhotosUI
import SwiftUI
import UIKit
import WebKit

let mitLicenseText = "MIT License Copyright (c) 2026 BIT101 Contributors Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the \"Software\"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE."

/// 设置中心支持的一级菜单。
///
/// “设置首页卡片”与“从其它页面直达某一设置子页”都依赖这个枚举作为统一路由源。
enum SettingsRoute: String, CaseIterable, Identifiable {
    case account
    case pages
    case theme
    case calendar
    case ddl
    case gallery
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: return "账号设置"
        case .pages: return "页面设置"
        case .theme: return "外观设置"
        case .calendar: return "课程表设置"
        case .ddl: return "DDL设置"
        case .gallery: return "话廊设置"
        case .about: return "关于"
        }
    }

    var subtitle: String {
        switch self {
        case .account: return "个人信息编辑及登录状态管理"
        case .pages: return "启动页及页面顺序"
        case .theme: return "主题及暗黑模式"
        case .calendar: return "课程表数据及显示方式"
        case .ddl: return "日程数据及显示方式"
        case .gallery: return "话廊数据及显示方式"
        case .about: return "关于 BIT101"
        }
    }

    var systemImage: String {
        switch self {
        case .account: return "person.crop.circle"
        case .pages: return "square.grid.2x2"
        case .theme: return "paintpalette"
        case .calendar: return "calendar.badge.clock"
        case .ddl: return "list.bullet.clipboard"
        case .gallery: return "bubble.left.and.bubble.right"
        case .about: return "info.circle"
        }
    }
}

/// 全局设置中心入口。
///
/// “我的”页右上角设置、课程表页齿轮、DDL 页齿轮都应当汇入这里。
struct SettingsRootView: View {
    let initialRoute: SettingsRoute?
    let studentID: String
    let onLogout: () -> Void
    var showsCloseButton = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let initialRoute {
                SettingsRoutePage(route: initialRoute, studentID: studentID, onLogout: onLogout)
            } else {
                SettingsIndexPage(studentID: studentID, onLogout: onLogout)
            }
        }
        .navigationTitle(initialRoute?.title ?? "设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
    }
}

/// 设置首页，负责列出全部一级菜单。
///
/// 这里仍然保留卡片式入口，而不是直接用 `List`，是为了和“我的”页的入口风格区分开。
private struct SettingsIndexPage: View {
    let studentID: String
    let onLogout: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(SettingsRoute.allCases) { route in
                    NavigationLink {
                        SettingsRoutePage(route: route, studentID: studentID, onLogout: onLogout)
                    } label: {
                        SettingsIndexCard(route: route)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .background(Color(.systemGroupedBackground))
    }
}

/// 设置首页卡片样式。
private struct SettingsIndexCard: View {
    let route: SettingsRoute

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: route.systemImage)
                .frame(width: 24, height: 24)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 3) {
                Text(route.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(route.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// 根据 route 分发到具体设置页面。
///
/// 这一层的意义是把“路由选择”和“具体页面实现”解耦，便于其它模块直接按 route 深链进来。
private struct SettingsRoutePage: View {
    let route: SettingsRoute
    let studentID: String
    let onLogout: () -> Void

    var body: some View {
        switch route {
        case .account:
            AccountSettingsPage(studentID: studentID, onLogout: onLogout)
        case .pages:
            PagesSettingsPage()
        case .theme:
            ThemeSettingsPage()
        case .calendar:
            CalendarSettingsPage()
        case .ddl:
            DDLSettingsPage()
        case .gallery:
            GallerySettingsPage()
        case .about:
            AboutSettingsPage(onLogout: onLogout)
        }
    }
}

/// 账号设置页。
///
/// 包含个人资料编辑、头像上传、登录状态检查和退出登录。
