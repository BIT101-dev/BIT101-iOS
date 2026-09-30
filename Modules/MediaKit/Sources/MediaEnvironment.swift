#if os(iOS)
import StorageCore
import TransportCore
import Foundation
import Observation

@Observable
public final class MediaEnvironment {
    let images: RemoteImageCache
    let avatars: CachedRemoteImageStore
    let avatarHTTPClient: HTTPClient
    let stillDecoder: GalleryThumbnailDecoder
    let animatedDecoder: RemoteAnimatedImageDecoder
    private let previewQuota: ImageCacheDiskQuota
    private let previewFiles: any AppFileService
    private let preferences: GalleryImageCachePreferences

    public init(
        files: any AppFileService,
        previewFiles: any AppFileService,
        defaults: UserDefaults,
        imageHTTPClient: HTTPClient,
        avatarHTTPClient: HTTPClient
    ) {
        let preferences = GalleryImageCachePreferences(defaults: defaults)
        let quota = ImageCacheDiskQuota(files: files, cacheLimitMB: { preferences.limitMB })
        self.preferences = preferences
        self.previewFiles = previewFiles
        previewQuota = ImageCacheDiskQuota(files: previewFiles, cacheLimitMB: { preferences.limitMB })
        self.avatarHTTPClient = avatarHTTPClient
        stillDecoder = GalleryThumbnailDecoder(files: files)
        animatedDecoder = RemoteAnimatedImageDecoder(files: files)
        images = RemoteImageCache(files: files, quota: quota, httpClient: imageHTTPClient)
        avatars = CachedRemoteImageStore(files: files, quota: quota)
    }

    public static func normalizedCacheLimitMB(_ value: Int) -> Int {
        GalleryImageCachePreferences.normalizedLimitMB(value)
    }

    public var cacheLimitMB: Int {
        get { preferences.limitMB }
        set { preferences.limitMB = GalleryImageCachePreferences.normalizedLimitMB(newValue) }
    }

    /// Materialize injected image bytes through the host's system-readable file service.
    func previewFile(at cachedURL: URL) async throws -> URL {
        let file = try await images.previewFile(at: cachedURL, using: previewFiles)
        await previewQuota.enforce(protecting: [file])
        return file
    }

    public func usedBytes() async -> Int64 { await images.usedBytes() }
    public func enforceCurrentLimit() async { await images.enforceCurrentLimit() }
    public func clearAvatars() async { await avatars.clearAll() }
}

#endif
