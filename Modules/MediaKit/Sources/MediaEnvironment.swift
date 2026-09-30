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
    private let preferences: GalleryImageCachePreferences

    public init(
        files: any AppFileService,
        defaults: UserDefaults,
        imageHTTPClient: HTTPClient,
        avatarHTTPClient: HTTPClient
    ) {
        let preferences = GalleryImageCachePreferences(defaults: defaults)
        let quota = ImageCacheDiskQuota(files: files, cacheLimitMB: { preferences.limitMB })
        self.preferences = preferences
        self.avatarHTTPClient = avatarHTTPClient
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

    public func usedBytes() async -> Int64 { await images.usedBytes() }
    public func enforceCurrentLimit() async { await images.enforceCurrentLimit() }
    public func clearAvatars() async { await avatars.clearAll() }
}

#endif
