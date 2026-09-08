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

/// 主 App 使用的远程图片缓存视图。
///
/// 在内存和 `Caches` 目录缓存图片数据，应用重启后可以复用磁盘缓存。
struct CachedRemoteImage<Content: View, Placeholder: View>: View {
    /// 需要加载的远程资源地址；为空时直接展示占位内容。
    let url: URL?
    /// 成功加载后的渲染闭包，由调用方决定裁剪、圆角、缩放等样式。
    let content: (Image) -> Content
    /// 加载前或失败时的占位内容。
    let placeholder: () -> Placeholder

    /// 使用 `StateObject` 为单个视图实例保留加载状态，避免 `body` 重算时重复创建 loader。
    @StateObject private var loader = CachedRemoteImageLoader()

    /// 创建一个使用本地缓存的远程图片视图。
    init(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
    }

    /// 按加载状态显示图片或占位内容。URL 变化时，`.task(id:)` 会取消旧任务并启动新任务。
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
    /// 当前用于显示的位图。
    @Published private(set) var image: UIImage?

    /// 当前加载任务对应的 URL，用于校验网络响应是否仍属于当前视图。
    private var currentURL: URL?

    /// 先读取本地缓存，未命中时下载。切换 URL 时清空旧图。
    func load(url: URL?) async {
        if currentURL == url, image != nil {
            return
        }

        currentURL = url
        image = nil

        guard let url else { return }

        if let cachedImage = await CachedRemoteImageStore.shared.image(for: url) {
            image = cachedImage
            return
        }

        do {
            let response = try await HTTPClient.shared.send(URLRequest(url: url))
            let data = response.data
            guard !Task.isCancelled, currentURL == url else { return }
            guard let downloadedImage = await CachedRemoteImageStore.shared.storeAndDecode(data, for: url) else {
                return
            }
            image = downloadedImage
        } catch {
            // 加载失败时保留占位内容。
            image = nil
        }
    }
}

/// 提供远程图片缓存清理入口。
enum CachedRemoteImageCacheMaintenance {
    static func clearAll() async {
        await CachedRemoteImageStore.shared.clearAll()
    }
}

private actor CachedRemoteImageStore {
    /// 共享缓存实例，统一内存缓存和磁盘目录。
    static let shared = CachedRemoteImageStore()

    /// 原始图片数据的内存缓存。
    private let memoryCache = NSCache<NSString, NSData>()
    /// 已准备显示的位图内存缓存。
    private let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 160
        cache.totalCostLimit = 24 * 1_024 * 1_024
        return cache
    }()
    private let fileManager = FileManager.default
    /// 磁盘缓存根目录。
    private let directoryURL: URL

    /// 初始化缓存目录。
    ///
    /// 缓存目录位于 `Caches`，系统可在空间不足时删除其中的内容。
    init() {
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directoryURL = cachesDirectory.appendingPathComponent("BIT101ImageCache", isDirectory: true)
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        self.directoryURL = directoryURL
    }

    /// 按“内存 -> 磁盘”顺序读取缓存数据。
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

    /// 读取缓存图片，并准备其显示位图。
    func image(for url: URL) -> UIImage? {
        let key = cacheKey(for: url)
        if let cached = imageCache.object(forKey: key as NSString) {
            return cached
        }
        guard let data = data(for: url), let source = UIImage(data: data) else { return nil }
        let decoded = source.preparingForDisplay() ?? source
        imageCache.setObject(decoded, forKey: key as NSString, cost: decodedPixelCost(decoded))
        return decoded
    }

    /// 将图片数据写入内存缓存和磁盘。
    func store(_ data: Data, for url: URL) {
        let key = cacheKey(for: url)
        memoryCache.setObject(data as NSData, forKey: key as NSString)
        let fileURL = directoryURL.appendingPathComponent(key)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 写入下载数据，并缓存准备显示的位图。
    func storeAndDecode(_ data: Data, for url: URL) -> UIImage? {
        store(data, for: url)
        guard let source = UIImage(data: data) else { return nil }
        let decoded = source.preparingForDisplay() ?? source
        let key = cacheKey(for: url) as NSString
        imageCache.setObject(decoded, forKey: key, cost: decodedPixelCost(decoded))
        return decoded
    }

    /// 清空当前进程的内存缓存和磁盘中的远程图片缓存。
    func clearAll() {
        memoryCache.removeAllObjects()
        imageCache.removeAllObjects()

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

    /// 使用 URL 的 SHA-256 摘要生成稳定文件名，避免文件名非法、过长或暴露原始 query。
    private func cacheKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func decodedPixelCost(_ image: UIImage) -> Int {
        Int(image.size.width * image.scale) * Int(image.size.height * image.scale) * 4
    }
}
