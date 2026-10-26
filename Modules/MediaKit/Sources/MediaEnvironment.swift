#if os(iOS)
import StorageCore
import TransportCore
import Foundation
import ImageIO
import CryptoKit
import OSLog
import Observation
import UIKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

public nonisolated enum RemoteImageResourceLimits {
    public static let maximumEncodedBytes = 32 * 1_024 * 1_024
    public static let maximumDecodedBytes = 48 * 1_024 * 1_024
    static func completeImageSource(from data: Data) -> CGImageSource? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete else { return nil }
        // GIF 缓存和动画解码共用数据流结束标记校验。
        if CGImageSourceGetType(source) as String? == "com.compuserve.gif", data.last != 0x3B { return nil }
        if CGImageSourceGetType(source) as String? == "public.png", !hasPNGEndChunk(data) { return nil }
        return source
    }
    private static func hasPNGEndChunk(_ data: Data) -> Bool {
        var offset = data.startIndex + 8
        while offset <= data.endIndex - 12 {
            let length = data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= data.endIndex - offset - 12 else { return false }
            if data[offset + 4..<offset + 8].elementsEqual([0x49, 0x45, 0x4E, 0x44]) { return length == 0 }
            offset += length + 12
        }
        return false
    }
    static func cachedData(at file: URL, using files: any AppFileService) -> Data? {
        guard let size = files.regularFileSize(at: file), size <= maximumEncodedBytes else { return nil }
        return try? files.readData(at: file, maximumBytes: maximumEncodedBytes)
    }
}

@Observable
public final class MediaEnvironment {
    private(set) var imageRetryGeneration: UInt64 = 0
    public func retryFailedImages() { imageRetryGeneration &+= 1 }

    private nonisolated let photoDataLoader: @Sendable (PhotosPickerItem) async throws -> Data?

    public nonisolated func loadBoundedImageData(from item: PhotosPickerItem) async throws -> Data? {
        try await photoDataLoader(item)
    }

    let images: RemoteImageCache
    let avatars: CachedRemoteImageStore
    let downloads: MediaDownloadCoordinator
    let displayBudget = MediaDisplayBudget()
    let stillDecoder: GalleryThumbnailDecoder
    let animatedDecoder: RemoteAnimatedImageDecoder
    private let previewQuota: ImageCacheDiskQuota
    private let cacheQuota: ImageCacheDiskQuota
    private let previewFiles: any AppFileService
    private let cacheFiles: any AppFileService
    private let cacheSharesPreviewStorage: Bool
    private let preferences: GalleryImageCachePreferences
    private let previewOwnership: PreviewFileOwnership
    private var temporaryPreviewFiles: [UUID: Set<URL>] = [:]
    @ObservationIgnored private var memoryWarningTask: Task<Void, Never>?
    @ObservationIgnored private var connectionRecoveryTask: Task<Void, Never>?
    @ObservationIgnored private var foregroundRecoveryTask: Task<Void, Never>?
    private nonisolated static let logger = Logger(subsystem: "BIT101", category: "PreviewFiles")

    public init(
        files cacheFileOverride: (any AppFileService)? = nil,
        previewStorage: MediaPreviewStorage,
        defaults: UserDefaults,
        loadPickedImage: @escaping @Sendable (PhotosPickerItem) async throws -> Data?,
        imageHTTPClient: HTTPClient,
        avatarHTTPClient: HTTPClient,
        networkPath: NetworkPathState? = nil
    ) {
        photoDataLoader = loadPickedImage
        let preferences = GalleryImageCachePreferences(defaults: defaults)
        let files = cacheFileOverride ?? previewStorage.files
        cacheFiles = files
        let previewFiles = previewStorage.files
        let sharesStorage = cacheFileOverride == nil || (files as AnyObject) === (previewFiles as AnyObject)
        cacheSharesPreviewStorage = sharesStorage
        let ownership = previewStorage.ownership
        previewOwnership = ownership
        let quota = ImageCacheDiskQuota(files: files, cacheLimitMB: { preferences.limitMB }, previewOwnership: ownership)
        cacheQuota = quota
        self.preferences = preferences
        self.previewFiles = previewFiles
        previewQuota = sharesStorage ? quota : ImageCacheDiskQuota(files: previewFiles,
            cacheLimitMB: { preferences.limitMB }, previewOwnership: ownership)
        let downloads = MediaDownloadCoordinator(avatarClient: avatarHTTPClient, galleryClient: imageHTTPClient)
        self.downloads = downloads
        stillDecoder = GalleryThumbnailDecoder(files: files)
        animatedDecoder = RemoteAnimatedImageDecoder(files: files)
        let images = RemoteImageCache(files: files, quota: quota, httpClient: imageHTTPClient,
            download: { try await downloads.response(for: $0, source: .gallery) })
        self.images = images
        avatars = CachedRemoteImageStore(files: files, resources: images,
            download: { try await downloads.response(for: $0, source: .avatar) })
        Task { await Self.removeReleasedLocalPreviews(files: previewFiles, ownership: ownership) }
        memoryWarningTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didReceiveMemoryWarningNotification) {
                guard !Task.isCancelled else { return }
                await self?.releaseCachedImages()
            }
        }
        if let networkPath {
            let recoveries = networkPath.connectionRecoveries()
            connectionRecoveryTask = Task { [weak self] in
                for await _ in recoveries {
                    guard !Task.isCancelled else { return }
                    self?.retryFailedImages()
                }
            }
            foregroundRecoveryTask = Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                    guard !Task.isCancelled else { return }
                    if networkPath.isReachable { self?.retryFailedImages() }
                }
            }
        }
    }

    isolated deinit {
        memoryWarningTask?.cancel()
        connectionRecoveryTask?.cancel()
        foregroundRecoveryTask?.cancel()
    }

    func releaseCachedImages() async {
        await avatars.clearMemory()
        await stillDecoder.clear()
        await animatedDecoder.clear()
    }

    public static func normalizedCacheLimitMB(_ value: Int) -> Int {
        GalleryImageCachePreferences.normalizedLimitMB(value)
    }

    public var cacheLimitMB: Int {
        get { preferences.limitMB }
        set { preferences.limitMB = GalleryImageCachePreferences.normalizedLimitMB(newValue) }
    }

    /// Materialize injected image bytes through the host's system-readable file service.
    func beginPreview(owner: UUID) { previewOwnership.begin(owner) }
    @discardableResult
    func endPreview(owner: UUID) -> Task<Void, Never> {
        let cleanup = previewOwnership.end(owner)
        let released = temporaryPreviewFiles.removeValue(forKey: owner) ?? []
        let retained = temporaryPreviewFiles.values.reduce(into: Set<URL>()) { $0.formUnion($1) }
        let files = previewFiles, ownership = previewOwnership
        return Task {
            await cleanup.value
            for file in released.subtracting(retained) { await Self.removePreviewFile(file, files: files, ownership: ownership) }
            await cacheQuota.didReleaseFiles(cacheSharesPreviewStorage ? released : [])
            if previewQuota !== cacheQuota { await previewQuota.didReleaseFiles(released) }
        }
    }

    func localPreviewFile(image: UIImage, owner: UUID) async throws -> URL {
        let data = try await Self.previewData(image)
        return try await localPreviewFile(data: data, owner: owner)
    }

    @concurrent
    private static func previewData(_ image: UIImage) async throws -> Data {
        try Task.checkCancellation()
        guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    func localPreviewFile(data: Data, owner: UUID) async throws -> URL {
        let file = try await Self.materializeLocalPreview(data: data, files: previewFiles, ownership: previewOwnership, owner: owner)
        guard !Task.isCancelled, previewOwnership.contains(owner) else {
            await Self.removePreviewFile(file, files: previewFiles, ownership: previewOwnership)
            throw CancellationError()
        }
        temporaryPreviewFiles[owner, default: []].insert(file)
        return file
    }

    @concurrent
    private static func materializeLocalPreview(data: Data, files: any AppFileService,
                                               ownership: PreviewFileOwnership, owner: UUID) async throws -> URL {
        try Task.checkCancellation()
        let directory = ImageCacheDirectories.previews(using: files)
        let file = directory.appendingPathComponent("preview-local-\(SHA256.hash(data: data).hexString).png")
        try ownership.materializeAndPin(file, using: files, owner: owner) {
            try files.createDirectory(at: directory)
            if !files.fileExists(at: file) { try files.writeData(data, to: file, options: [.atomic, .completeFileProtection]) }
        }
        return file
    }

    @concurrent
    private static func removePreviewFile(_ file: URL, files: any AppFileService, ownership: PreviewFileOwnership) async {
        ownership.withPaths { retained in
            guard !retained.contains(files.canonicalFileURL(file).path), files.fileExists(at: file) else { return }
            do { try files.removeItem(at: file) }
            catch { Self.logger.error("Preview cleanup failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    @concurrent
    private static func removeReleasedLocalPreviews(files: any AppFileService, ownership: PreviewFileOwnership) async {
        let temporary = (try? files.contentsOfDirectory(at: ImageCacheDirectories.previews(using: files), options: [.skipsHiddenFiles])) ?? []
        let legacy = (try? files.contentsOfDirectory(at: ImageCacheDirectories.gallery(using: files), options: [.skipsHiddenFiles])) ?? []
        let children = temporary + legacy.filter { $0.lastPathComponent.hasPrefix("preview-local-") || $0.lastPathComponent.hasPrefix("local-") }
        let logger = Self.logger
        ownership.withPaths { retained in
            for file in children {
                guard !retained.contains(files.canonicalFileURL(file).path) else { continue }
                do { try files.removeItem(at: file) }
                catch { logger.error("Local preview cleanup failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }

    func previewFile(at cachedURL: URL, owner: UUID? = nil) async throws -> URL {
        if let owner, !previewOwnership.contains(owner) { throw CancellationError() }
        let file = try await images.previewFile(at: cachedURL, using: previewFiles, sharesStorage: cacheSharesPreviewStorage,
            ownership: previewOwnership, owner: owner)
        try Task.checkCancellation()
        if let owner {
            guard previewOwnership.contains(owner) else { throw CancellationError() }
        }
        await previewQuota.enforce(protecting: [file])
        try Task.checkCancellation()
        if let owner, !previewOwnership.contains(owner) { throw CancellationError() }
        return file
    }

    public func verifyRemoteImage(at url: URL) async throws -> Int {
        let galleryBytes = try await images.withFile(for: url) { @MainActor [self] file in
            guard let data = RemoteImageResourceLimits.cachedData(at: file, using: cacheFiles),
                  await stillDecoder.image(at: file) != nil,
                  await animatedDecoder.image(at: file, reduceMotion: false) != nil else { throw URLError(.cannotDecodeContentData) }
            return data.count
        }
        let loader = CachedRemoteImageLoader()
        await loader.load(url: url, media: self)
        try Task.checkCancellation()
        guard loader.image != nil, let avatarData = await avatars.diskData(for: url),
              BoundedStillImageDecoder.image(from: avatarData) != nil else { throw URLError(.cannotDecodeContentData) }
        return galleryBytes + avatarData.count
    }

    func remotePreviewFile(for url: URL, owner: UUID) async throws -> URL {
        try await images.withFile(for: url) { @MainActor [self] file in
            try await previewFile(at: file, owner: owner)
        }
    }

    func cachedRemotePreviewFile(for url: URL, owner: UUID) async throws -> URL? {
        try await images.withCachedFile(for: url) { @MainActor [self] file in
            try await previewFile(at: file, owner: owner)
        }
    }

    public func usedBytes() async -> Int64 { await images.usedBytes() }
    public func enforceCurrentLimit() async {
        await Self.removeReleasedLocalPreviews(files: previewFiles, ownership: previewOwnership)
        await images.enforceCurrentLimit()
        if previewQuota !== cacheQuota { await previewQuota.enforce(force: true) }
    }
    public var cacheDirectories: Set<URL> {
        Set([cacheFiles, previewFiles].flatMap {
            [ImageCacheDirectories.gallery(using: $0), ImageCacheDirectories.avatars(using: $0), ImageCacheDirectories.previews(using: $0)]
        })
    }

    @discardableResult public func clearCaches() async -> Bool {
        downloads.clear()
        let avatarsCleared = await avatars.clearAll()
        let previewsCleared = await previewQuota.clearDirectory(ImageCacheDirectories.previews(using: previewFiles))
        await stillDecoder.clear()
        await animatedDecoder.clear()
        return avatarsCleared && previewsCleared
    }
}

/// Environments sharing preview files consume the same storage and ownership resource.
public final class MediaPreviewStorage {
    let files: any AppFileService
    let ownership = PreviewFileOwnership()
    public init(files: any AppFileService) { self.files = files }
}

#endif
