#if os(iOS)
import StorageCore
import TransportCore
import Foundation
import CryptoKit
import OSLog
import Observation
import UIKit

public nonisolated enum RemoteImageResourceLimits {
    public static let maximumEncodedBytes = 32 * 1_024 * 1_024
    public static let maximumDecodedBytes = 48 * 1_024 * 1_024
    static func cachedData(at file: URL, using files: any AppFileService) -> Data? {
        guard let size = files.regularFileSize(at: file), size <= maximumEncodedBytes else { return nil }
        return try? files.readData(at: file)
    }
}

@Observable
public final class MediaEnvironment {
    private(set) var imageRetryGeneration: UInt64 = 0
    public func retryFailedImages() { imageRetryGeneration &+= 1 }

    let images: RemoteImageCache
    let avatars: CachedRemoteImageStore
    let downloads: MediaDownloadCoordinator
    let displayBudget = MediaDisplayBudget()
    let stillDecoder: GalleryThumbnailDecoder
    let animatedDecoder: RemoteAnimatedImageDecoder
    private let previewQuota: ImageCacheDiskQuota
    private let previewFiles: any AppFileService
    private let cacheFiles: any AppFileService
    private let preferences: GalleryImageCachePreferences
    private let previewOwnership: PreviewFileOwnership
    private var temporaryPreviewFiles: [UUID: Set<URL>] = [:]
    private nonisolated static let logger = Logger(subsystem: "BIT101", category: "PreviewFiles")

    public init(
        files: any AppFileService,
        previewStorage: MediaPreviewStorage,
        defaults: UserDefaults,
        imageHTTPClient: HTTPClient,
        avatarHTTPClient: HTTPClient
    ) {
        let preferences = GalleryImageCachePreferences(defaults: defaults)
        cacheFiles = files
        let previewFiles = previewStorage.files
        let ownership = previewStorage.ownership
        previewOwnership = ownership
        let quota = ImageCacheDiskQuota(files: files, cacheLimitMB: { preferences.limitMB }, previewOwnership: ownership)
        self.preferences = preferences
        self.previewFiles = previewFiles
        previewQuota = ImageCacheDiskQuota(files: previewFiles, cacheLimitMB: { preferences.limitMB }, previewOwnership: ownership)
        let downloads = MediaDownloadCoordinator(avatarClient: avatarHTTPClient, galleryClient: imageHTTPClient)
        self.downloads = downloads
        stillDecoder = GalleryThumbnailDecoder(files: files)
        animatedDecoder = RemoteAnimatedImageDecoder(files: files)
        images = RemoteImageCache(files: files, quota: quota, httpClient: imageHTTPClient,
            download: { try await downloads.response(for: $0, source: .gallery) })
        avatars = CachedRemoteImageStore(files: files, quota: quota)
        Task { await Self.removeReleasedLocalPreviews(files: previewFiles, ownership: ownership) }
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
    func endPreview(owner: UUID) {
        previewOwnership.end(owner)
        let released = temporaryPreviewFiles.removeValue(forKey: owner) ?? []
        let retained = temporaryPreviewFiles.values.reduce(into: Set<URL>()) { $0.formUnion($1) }
        for file in released.subtracting(retained) { removePreviewFile(file) }
        Task { await enforceCurrentLimit() }
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
            removePreviewFile(file)
            throw CancellationError()
        }
        temporaryPreviewFiles[owner, default: []].insert(file)
        return file
    }

    @concurrent
    private static func materializeLocalPreview(data: Data, files: any AppFileService,
                                               ownership: PreviewFileOwnership, owner: UUID) async throws -> URL {
        try Task.checkCancellation()
        let directory = ImageCacheDirectories.gallery(using: files)
        let file = directory.appendingPathComponent("preview-local-\(SHA256.hash(data: data).hexString).png")
        try ownership.materializeAndPin(file, using: files, owner: owner) {
            try files.createDirectory(at: directory)
            if !files.fileExists(at: file) { try files.writeData(data, to: file, options: [.atomic]) }
        }
        return file
    }

    private func removePreviewFile(_ file: URL) {
        let files = previewFiles
        previewOwnership.withPaths { retained in
            guard !retained.contains(files.canonicalFileURL(file).path), files.fileExists(at: file) else { return }
            do { try files.removeItem(at: file) }
            catch { Self.logger.error("Preview cleanup failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    @concurrent
    private static func removeReleasedLocalPreviews(files: any AppFileService, ownership: PreviewFileOwnership) async {
        let directory = ImageCacheDirectories.gallery(using: files)
        let children = (try? files.contentsOfDirectory(at: directory, options: [.skipsHiddenFiles])) ?? []
        let logger = Self.logger
        ownership.withPaths { retained in
            for file in children where file.lastPathComponent.hasPrefix("preview-local-") || file.lastPathComponent.hasPrefix("local-") {
                guard !retained.contains(files.canonicalFileURL(file).path) else { continue }
                do { try files.removeItem(at: file) }
                catch { logger.error("Local preview cleanup failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }

    func previewFile(at cachedURL: URL, owner: UUID? = nil) async throws -> URL {
        if let owner, !previewOwnership.contains(owner) { throw CancellationError() }
        let file = try await images.previewFile(at: cachedURL, using: previewFiles, ownership: previewOwnership, owner: owner)
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
        let file = try await images.file(for: url)
        guard let galleryData = RemoteImageResourceLimits.cachedData(at: file, using: cacheFiles),
              await stillDecoder.image(at: file) != nil else { throw URLError(.cannotDecodeContentData) }
        let loader = CachedRemoteImageLoader()
        await loader.load(url: url, media: self)
        try Task.checkCancellation()
        guard loader.image != nil, let avatarData = await avatars.diskData(for: url),
              BoundedStillImageDecoder.image(from: avatarData) != nil else { throw URLError(.cannotDecodeContentData) }
        return galleryData.count + avatarData.count
    }

    public func usedBytes() async -> Int64 { await images.usedBytes() }
    public func enforceCurrentLimit() async {
        await Self.removeReleasedLocalPreviews(files: previewFiles, ownership: previewOwnership)
        await images.enforceCurrentLimit()
        await previewQuota.enforce(force: true)
    }
    public func clearCaches() async {
        downloads.clear()
        await images.clearAll()
        await avatars.clearAll()
        await stillDecoder.clear()
        await animatedDecoder.clear()
    }
}

/// Environments sharing preview files consume the same storage and ownership resource.
public final class MediaPreviewStorage {
    let files: any AppFileService
    let ownership = PreviewFileOwnership()
    public init(files: any AppFileService) { self.files = files }
}

#endif
