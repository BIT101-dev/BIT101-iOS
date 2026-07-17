//
//  CachedRemoteImage.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-29.
//

import Combine
import CryptoKit
import SwiftUI
import UIKit

/// 主 app 内统一复用的远程图片缓存视图。
///
/// SwiftUI 的 `AsyncImage` 很依赖系统和服务端的缓存策略。头像资源如果服务端没有正确下发
/// `Cache-Control`，每次冷启动都可能重新下载。这里显式补一层“内存 + 磁盘”缓存，保证头像
/// 在应用重启后也能命中本地缓存，而不必每次重新走网络。
struct CachedRemoteImage<Content: View, Placeholder: View>: View {
    /// 需要加载的远程资源地址；为空时直接展示占位内容。
    let url: URL?
    /// 成功加载后的渲染闭包，由调用方决定裁剪、圆角、缩放等样式。
    let content: (Image) -> Content
    /// 加载前或失败时的占位内容。
    let placeholder: () -> Placeholder

    /// 为单个视图实例维护加载状态。
    ///
    /// 这里必须用 `StateObject`，否则列表滚动复用时每次 body 重算都会重新创建 loader，
    /// 反而把本地缓存命中后的显示也变得不稳定。
    @StateObject private var loader = CachedRemoteImageLoader()

    /// 构造一个带有显式本地缓存能力的远程图片视图。
    ///
    /// 调用方式刻意保持和 `AsyncImage` 接近，这样项目里替换头像加载方案时，
    /// 只需要把原来的 `AsyncImage` 换成这里的包装即可，界面层改动会比较小。
    init(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
    }

    /// 根据当前加载状态渲染占位图或真实图片。
    ///
    /// 使用 `.task(id: url)` 的原因是：URL 变化时自动取消旧任务并启动新任务，
    /// 列表复用场景下比手动监听 `onAppear` / `onChange` 更稳。
    var body: some View {
        Group {
            if let image = loader.image {
                content(Image(uiImage: image))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            await loader.load(url: url)
        }
    }
}

@MainActor
private final class CachedRemoteImageLoader: ObservableObject {
    /// 当前已经准备好展示的位图。
    @Published private(set) var image: UIImage?

    /// 记录最近一次请求的 URL，用来识别列表复用和异步返回乱序。
    private var currentURL: URL?

    /// 加载指定 URL 的图片。
    ///
    /// 先读本地缓存，再回退到网络下载。URL 切换时会主动清掉旧图，避免列表复用时闪旧头像。
    func load(url: URL?) async {
        if currentURL == url, image != nil {
            return
        }

        currentURL = url
        image = nil

        guard let url else { return }

        if let cachedData = await CachedRemoteImageStore.shared.data(for: url),
           let cachedImage = UIImage(data: cachedData) {
            image = cachedImage
            return
        }

        do {
            let response = try await HTTPClient.shared.send(URLRequest(url: url))
            let data = response.data
            guard !Task.isCancelled, currentURL == url else { return }
            guard let downloadedImage = UIImage(data: data) else { return }

            await CachedRemoteImageStore.shared.store(data, for: url)
            image = downloadedImage
        } catch {
            // 头像加载失败时直接停留在占位图，不额外打断 UI。
        }
    }
}

/// 头像图片的轻量本地缓存。
///
/// 这里不走复杂的 LRU 或 HTTP 协商，目标只是把频繁重复使用的头像稳定落到本地缓存目录。
enum CachedRemoteImageCacheMaintenance {
    static func clearAll() async {
        await CachedRemoteImageStore.shared.clearAll()
    }
}

private actor CachedRemoteImageStore {
    /// 全局唯一缓存实例，避免不同页面各自维护重复的磁盘目录和内存缓存。
    static let shared = CachedRemoteImageStore()

    /// 内存层缓存，负责加速当前进程内的重复命中。
    private let memoryCache = NSCache<NSString, NSData>()
    private let fileManager = FileManager.default
    /// 磁盘缓存根目录。
    private let directoryURL: URL

    /// 初始化缓存目录。
    ///
    /// 目录放在 `Caches` 下而不是 `Documents`，因为头像属于可再生资源；
    /// 系统需要回收空间时可以安全删除，不应该污染需要备份的用户文稿目录。
    init() {
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directoryURL = cachesDirectory.appendingPathComponent("BIT101ImageCache", isDirectory: true)
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        self.directoryURL = directoryURL
    }

    /// 读取指定 URL 的缓存数据。
    ///
    /// 读取顺序固定为“内存 -> 磁盘”。这是为了让热门头像在列表频繁刷新的时候
    /// 不必每次都走文件系统，同时又能在应用重启后继续利用磁盘层结果。
    func data(for url: URL) -> Data? {
        let key = cacheKey(for: url)

        if let cached = memoryCache.object(forKey: key as NSString) {
            return Data(referencing: cached)
        }

        let fileURL = directoryURL.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        memoryCache.setObject(data as NSData, forKey: key as NSString)
        return data
    }

    /// 写入指定 URL 的缓存数据。
    ///
    /// 这里同时更新内存和磁盘，两层保持最终一致；不额外做写入去重，是因为头像文件
    /// 普遍较小，直接覆盖的实现更简单，也足够支撑当前项目规模。
    func store(_ data: Data, for url: URL) {
        let key = cacheKey(for: url)
        memoryCache.setObject(data as NSData, forKey: key as NSString)
        let fileURL = directoryURL.appendingPathComponent(key)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 清空当前进程内和磁盘上的远程图片缓存。
    func clearAll() {
        memoryCache.removeAllObjects()

        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        if let children = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for child in children {
                try? fileManager.removeItem(at: child)
            }
        }
    }

    /// 把 URL 转成稳定文件名。
    ///
    /// 直接使用原始 URL 作为文件名容易遇到非法字符、长度过长以及 query 泄漏问题。
    /// 用 SHA-256 做哈希后，文件名固定、可复现，也不会把头像 URL 原文暴露到缓存目录里。
    private func cacheKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
