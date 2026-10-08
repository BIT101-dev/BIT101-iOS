#if os(iOS)
import StorageCore
import TransportCore
import Foundation
import CryptoKit
import OSLog
import Observation

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
    let avatarHTTPClient: HTTPClient
    let stillDecoder: GalleryThumbnailDecoder
    let animatedDecoder: RemoteAnimatedImageDecoder
    private let previewQuota: ImageCacheDiskQuota
    private let previewFiles: any AppFileService
    private let preferences: GalleryImageCachePreferences
    private let previewOwnership: PreviewFileOwnership
    private var temporaryPreviewFiles: [UUID: Set<URL>] = [:]
    private static let logger = Logger(subsystem: "BIT101", category: "PreviewFiles")

    public init(
        files: any AppFileService,
        previewFiles: any AppFileService,
        defaults: UserDefaults,
        imageHTTPClient: HTTPClient,
        avatarHTTPClient: HTTPClient
    ) {
        let preferences = GalleryImageCachePreferences(defaults: defaults)
        let ownership = PreviewFileOwnership()
        previewOwnership = ownership
        let quota = ImageCacheDiskQuota(files: files, cacheLimitMB: { preferences.limitMB }, previewOwnership: ownership)
        self.preferences = preferences
        self.previewFiles = previewFiles
        previewQuota = ImageCacheDiskQuota(files: previewFiles, cacheLimitMB: { preferences.limitMB }, previewOwnership: ownership)
        self.avatarHTTPClient = avatarHTTPClient
        stillDecoder = GalleryThumbnailDecoder(files: files)
        animatedDecoder = RemoteAnimatedImageDecoder(files: files)
        images = RemoteImageCache(files: files, quota: quota, httpClient: imageHTTPClient)
        avatars = CachedRemoteImageStore(files: files, quota: quota)
        removeReleasedLocalPreviews()
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

    func localPreviewFile(data: Data, owner: UUID) throws -> URL {
        try Task.checkCancellation()
        guard previewOwnership.contains(owner) else { throw CancellationError() }
        let directory = ImageCacheDirectories.gallery(using: previewFiles)
        let file = directory.appendingPathComponent("preview-local-\(SHA256.hash(data: data).hexString).png")
        try previewFiles.createDirectory(at: directory)
        if !previewFiles.fileExists(at: file) { try previewFiles.writeData(data, to: file, options: [.atomic]) }
        guard previewOwnership.pin(file, using: previewFiles, owner: owner) else { throw CancellationError() }
        temporaryPreviewFiles[owner, default: []].insert(file)
        return file
    }

    private func removePreviewFile(_ file: URL) {
        guard previewFiles.fileExists(at: file) else { return }
        do { try previewFiles.removeItem(at: file) }
        catch { Self.logger.error("Preview cleanup failed: \(error.localizedDescription, privacy: .public)") }
    }

    private func removeReleasedLocalPreviews() {
        let directory = ImageCacheDirectories.gallery(using: previewFiles)
        let children = (try? previewFiles.contentsOfDirectory(at: directory, options: [.skipsHiddenFiles])) ?? []
        let files = previewFiles
        let logger = Self.logger
        previewOwnership.withPaths { retained in
            for file in children where file.lastPathComponent.hasPrefix("preview-local-") || file.lastPathComponent.hasPrefix("local-") {
                guard !retained.contains(files.canonicalFileURL(file).path) else { continue }
                do { try files.removeItem(at: file) }
                catch { logger.error("Local preview cleanup failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }

    func previewFile(at cachedURL: URL, owner: UUID? = nil) async throws -> URL {
        if let owner, !previewOwnership.contains(owner) { throw CancellationError() }
        let file = try await images.previewFile(at: cachedURL, using: previewFiles)
        try Task.checkCancellation()
        if let owner {
            guard previewOwnership.pin(file, using: previewFiles, owner: owner) else { throw CancellationError() }
        }
        await previewQuota.enforce(protecting: [file])
        try Task.checkCancellation()
        if let owner, !previewOwnership.contains(owner) { throw CancellationError() }
        return file
    }

    public func usedBytes() async -> Int64 { await images.usedBytes() }
    public func enforceCurrentLimit() async {
        removeReleasedLocalPreviews()
        await images.enforceCurrentLimit()
        await previewQuota.enforce(force: true)
    }
    public func clearCaches() async {
        await images.clearAll()
        await avatars.clearAll()
        await stillDecoder.clear()
        await animatedDecoder.clear()
    }
}

#endif
