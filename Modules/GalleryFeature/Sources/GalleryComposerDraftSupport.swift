#if os(iOS)
import CommunityUI
import StorageCore
import CommunityCore
import DesignSystemKit
import Foundation
import ImageIO
import OSLog
import SwiftUI
import UIKit

public nonisolated struct GalleryComposerImageDraft: Identifiable, Sendable {
    public enum Status: Sendable {
        case uploading
        case compressing
        case prepared
        case uploaded(CommunityImage)
        case failed(String)
    }

    public let id = UUID()
    public let previewData: Data
    public let filename: String
    public var uploadData: Data?
    public var progress: Int = 0
    public var status: Status = .uploading

    public init(
        previewData: Data,
        filename: String,
        uploadData: Data? = nil,
        progress: Int = 0,
        status: Status = .uploading
    ) {
        self.previewData = previewData
        self.filename = filename
        self.uploadData = uploadData
        self.progress = progress
        self.status = status
    }

    /// 上传成功的图片会拿到可提交给发帖接口的 `mid`。
    public var uploadedImage: CommunityImage? {
        guard case .uploaded(let image) = status else { return nil }
        return image
    }
}

/// 发帖页图片缩略图条目。
///
/// 图片状态对应以下交互：
/// - 上传中显示进度
/// - 失败时允许重试
/// - 每种状态都提供删除操作
public struct GalleryComposerImageTile: View {
    let draft: GalleryComposerImageDraft
    let onRetry: () -> Void
    let onRemove: () -> Void
    let showsPreparedSuccessIndicator: Bool

    public init(
        draft: GalleryComposerImageDraft,
        onRetry: @escaping () -> Void,
        onRemove: @escaping () -> Void,
        showsPreparedSuccessIndicator: Bool = true
    ) {
        self.draft = draft
        self.onRetry = onRetry
        self.onRemove = onRemove
        self.showsPreparedSuccessIndicator = showsPreparedSuccessIndicator
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.card)
                    .fill(AppDesignSystem.Palette.Background.secondaryGrouped)

                if let image = UIImage(data: draft.previewData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(AppDesignSystem.Typography.title)
                        .foregroundStyle(AppDesignSystem.Foreground.secondary)
                }
            }
            .frame(width: AppDesignSystem.Size.Media.draft, height: AppDesignSystem.Size.Media.draft)
            .clipShape(AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.card))
            .overlay(alignment: .bottom) {
                overlayContent
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(AppDesignSystem.Typography.title)
                    .foregroundStyle(AppDesignSystem.Palette.Media.foreground, AppDesignSystem.Palette.Media.controlOverlay)
            }
            .padding(AppDesignSystem.Spacing.tiny)
            .buttonStyle(.plain)
            .accessibilityLabel("移除图片")
        }
        .frame(width: AppDesignSystem.Size.Media.draft, height: AppDesignSystem.Size.Media.draft)
    }

    @ViewBuilder
    private var overlayContent: some View {
        switch draft.status {
        case .uploading:
            ZStack {
                Rectangle()
                    .fill(AppDesignSystem.Palette.Media.overlay)
                ProgressView()
                    .tint(.white)
            }
            .frame(height: AppDesignSystem.Size.Control.compact)
        case .compressing:
            ZStack {
                Rectangle()
                    .fill(AppDesignSystem.Palette.Media.overlay)
                Text("\(draft.progress)%")
                    .font(AppDesignSystem.Typography.captionEmphasis)
                    .foregroundStyle(AppDesignSystem.Palette.Media.foreground)
            }
            .frame(height: AppDesignSystem.Size.Control.compact)
        case .prepared:
            if showsPreparedSuccessIndicator {
                Image(systemName: "checkmark.circle.fill")
                    .font(AppDesignSystem.Typography.title)
                    .foregroundStyle(AppDesignSystem.Palette.Media.foreground)
                    .padding(AppDesignSystem.Spacing.tiny)
                    .background(AppDesignSystem.Palette.Media.overlaySoft, in: Circle())
            }
        case .uploaded:
            HStack(spacing: AppDesignSystem.Spacing.tiny) {
                Image(systemName: "checkmark.circle.fill")
                Text("已上传")
            }
            .font(AppDesignSystem.Typography.captionEmphasis)
            .foregroundStyle(AppDesignSystem.Palette.Media.foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppDesignSystem.Spacing.tiny)
            .background(AppDesignSystem.Palette.Media.overlaySoft)
        case .failed:
            Button(action: onRetry) {
                HStack(spacing: AppDesignSystem.Spacing.tiny) {
                    Image(systemName: "arrow.clockwise")
                    Text("重试")
                }
                .font(AppDesignSystem.Typography.captionEmphasis)
                .foregroundStyle(AppDesignSystem.Palette.Media.foreground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppDesignSystem.Spacing.tiny)
                .background(AppDesignSystem.Palette.Status.danger.opacity(AppDesignSystem.Gallery.dangerOverlayOpacity))
            }
            .buttonStyle(.plain)
        }
    }
}

public nonisolated struct ComposerImageDraftSnapshot: Codable, Sendable {
    public let filename: String
    public let previewData: Data
    public let uploadData: Data?
    public init(filename: String, previewData: Data, uploadData: Data?) {
        self.filename = filename
        self.previewData = previewData
        self.uploadData = uploadData
    }
}

public nonisolated struct GalleryComposerDraftSnapshot: Codable, Sendable {
    public let title: String
    public let text: String
    public let selectedTags: [String]
    public let customTags: [String]
    public let anonymous: Bool
    public let isPublic: Bool
    public let selectedClaimID: Int
    public let images: [ComposerImageDraftSnapshot]
    public init(title: String, text: String, selectedTags: [String], customTags: [String], anonymous: Bool, isPublic: Bool, selectedClaimID: Int, images: [ComposerImageDraftSnapshot]) {
        self.title = title
        self.text = text
        self.selectedTags = selectedTags
        self.customTags = customTags
        self.anonymous = anonymous
        self.isPublic = isPublic
        self.selectedClaimID = selectedClaimID
        self.images = images
    }
}

public nonisolated struct DeveloperSuggestionDraftSnapshot: Codable, Sendable {
    public let text: String
    public let images: [ComposerImageDraftSnapshot]
    public let contact: String

    public init(
        text: String,
        images: [ComposerImageDraftSnapshot],
        contact: String = ""
    ) {
        self.text = text
        self.images = images
        self.contact = contact
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case images
        case contact
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        images = try container.decode([ComposerImageDraftSnapshot].self, forKey: .images)
        contact = try container.decodeIfPresent(String.self, forKey: .contact) ?? ""
    }
}

private nonisolated struct StoredComposerDraftImage: Codable {
    let filename: String
}

private nonisolated struct StoredGalleryComposerDraft: Codable {
    let schemaVersion: Int
    let assetRevision: String
    let title: String
    let text: String
    let selectedTags: [String]
    let customTags: [String]
    let anonymous: Bool
    let isPublic: Bool
    let selectedClaimID: Int
    let images: [StoredComposerDraftImage]
}

private nonisolated struct StoredDeveloperSuggestionDraft: Codable {
    let schemaVersion: Int
    let assetRevision: String
    let text: String
    let contact: String
    let images: [StoredComposerDraftImage]
}

public nonisolated final class ComposerDraftStore: Sendable {
    private static let directoryName = "ComposerDrafts"
    private static let logger = Logger(subsystem: "BIT101", category: "ComposerDraft")
    private static let currentSchemaVersion = 1
    private let storage = ComposerDraftStorage()
    private let files: any AppFileService
    private let applicationSupport: URL
    private let currentSession: @MainActor @Sendable () -> AppStorageSession

    public init(files: any AppFileService, applicationSupport: URL, session: @escaping @MainActor @Sendable () -> AppStorageSession) {
        self.files = files
        self.applicationSupport = applicationSupport
        self.currentSession = session
    }

    @MainActor
    @discardableResult
    public func saveGallery(_ snapshot: GalleryComposerDraftSnapshot) async -> Bool {
        await storage.saveGallery(store: self, snapshot, session: currentSession())
    }

    @MainActor
    public func loadGallery() async -> GalleryComposerDraftSnapshot? {
        await storage.loadGallery(store: self, session: currentSession())
    }

    @discardableResult
    fileprivate func persistGallery(_ snapshot: GalleryComposerDraftSnapshot, session: AppStorageSession) -> Bool {
        let fileURL = currentFileURL(for: "gallery.json", session: session)
        let previousRevision = storedGalleryRevision(at: fileURL)
        var newRevision: String?
        do {
            // 清理上次保存留下的版本后再创建新目录；清理失败时本轮写入停止，限制孤立版本数量。
            try removeObsoleteAssetRevisions(
                for: "gallery.json",
                keeping: previousRevision,
                session: session
            )
            let (revision, images) = try writeImages(snapshot.images, filename: "gallery.json", session: session)
            newRevision = revision
            let stored = StoredGalleryComposerDraft(
                schemaVersion: Self.currentSchemaVersion,
                assetRevision: revision,
                title: snapshot.title,
                text: snapshot.text,
                selectedTags: snapshot.selectedTags,
                customTags: snapshot.customTags,
                anonymous: snapshot.anonymous,
                isPublic: snapshot.isPublic,
                selectedClaimID: snapshot.selectedClaimID,
                images: images
            )
            try write(stored, to: fileURL)
            try? removeObsoleteAssetRevisions(for: "gallery.json", keeping: revision, session: session)
            return true
        } catch {
            if let newRevision { removeAssets(for: "gallery.json", revision: newRevision, session: session) }
            Self.logger.error("保存发帖草稿失败：\(String(describing: error), privacy: .public)")
            return false
        }
    }

    fileprivate func loadGallery(session: AppStorageSession) -> GalleryComposerDraftSnapshot? {
        let currentURL = currentFileURL(for: "gallery.json", session: session)
        if let data = readData(at: currentURL) {
            if let stored = try? JSONDecoder().decode(StoredGalleryComposerDraft.self, from: data),
               stored.schemaVersion == Self.currentSchemaVersion,
               let images = readImages(stored.images, filename: "gallery.json", revision: stored.assetRevision, session: session) {
                return GalleryComposerDraftSnapshot(
                    title: stored.title,
                    text: stored.text,
                    selectedTags: stored.selectedTags,
                    customTags: stored.customTags,
                    anonymous: stored.anonymous,
                    isPublic: stored.isPublic,
                    selectedClaimID: stored.selectedClaimID,
                    images: images
                )
            }
            if let legacy = try? JSONDecoder().decode(GalleryComposerDraftSnapshot.self, from: data) {
                _ = persistGallery(legacy, session: session)
                return legacy
            }
        }

        let previousAccountURL = legacyAccountFileURL(for: "gallery.json", session: session)
        if previousAccountURL != currentURL, let data = readData(at: previousAccountURL) {
            if let stored = try? JSONDecoder().decode(StoredGalleryComposerDraft.self, from: data),
               stored.schemaVersion == Self.currentSchemaVersion,
               let images = readImages(
                   stored.images,
                   filename: "gallery.json",
                   revision: stored.assetRevision,
                   session: session,
                   assetDirectory: legacyAssetDirectoryURL(
                       for: "gallery.json",
                       revision: stored.assetRevision,
                       session: session
                   )
               ) {
                let migrated = GalleryComposerDraftSnapshot(
                    title: stored.title,
                    text: stored.text,
                    selectedTags: stored.selectedTags,
                    customTags: stored.customTags,
                    anonymous: stored.anonymous,
                    isPublic: stored.isPublic,
                    selectedClaimID: stored.selectedClaimID,
                    images: images
                )
                if persistGallery(migrated, session: session) {
                    try? files.removeItem(at: previousAccountURL)
                    try? files.removeItem(at: previousAccountURL.appendingPathExtension("assets"))
                }
                return migrated
            }
            if let legacy = try? JSONDecoder().decode(GalleryComposerDraftSnapshot.self, from: data) {
                if persistGallery(legacy, session: session) { try? files.removeItem(at: previousAccountURL) }
                return legacy
            }
        }

        let legacyURL = directoryURL.appendingPathComponent("gallery.json")
        guard let data = readData(at: legacyURL),
              let legacy = try? JSONDecoder().decode(GalleryComposerDraftSnapshot.self, from: data)
        else { return nil }
        if persistGallery(legacy, session: session) {
            try? files.removeItem(at: legacyURL)
        }
        return legacy
    }

    @discardableResult
    @MainActor
    public func saveSuggestion(_ snapshot: DeveloperSuggestionDraftSnapshot) async -> Bool {
        await storage.saveSuggestion(store: self, snapshot, session: currentSession())
    }

    @MainActor
    public func loadSuggestion() async -> DeveloperSuggestionDraftSnapshot? {
        await storage.loadSuggestion(store: self, session: currentSession())
    }

    @discardableResult
    fileprivate func persistSuggestion(_ snapshot: DeveloperSuggestionDraftSnapshot, session: AppStorageSession) -> Bool {
        let fileURL = currentFileURL(for: "suggestion.json", session: session)
        let previousRevision = storedSuggestionRevision(at: fileURL)
        var newRevision: String?
        do {
            // 清理上次保存留下的版本后再创建新目录；清理失败时本轮写入停止，限制孤立版本数量。
            try removeObsoleteAssetRevisions(
                for: "suggestion.json",
                keeping: previousRevision,
                session: session
            )
            let (revision, images) = try writeImages(snapshot.images, filename: "suggestion.json", session: session)
            newRevision = revision
            let stored = StoredDeveloperSuggestionDraft(
                schemaVersion: Self.currentSchemaVersion,
                assetRevision: revision,
                text: snapshot.text,
                contact: snapshot.contact,
                images: images
            )
            try write(stored, to: fileURL)
            try? removeObsoleteAssetRevisions(for: "suggestion.json", keeping: revision, session: session)
            return true
        } catch {
            if let newRevision { removeAssets(for: "suggestion.json", revision: newRevision, session: session) }
            Self.logger.error("保存建议草稿失败：\(String(describing: error), privacy: .public)")
            return false
        }
    }

    fileprivate func loadSuggestion(session: AppStorageSession) -> DeveloperSuggestionDraftSnapshot? {
        let currentURL = currentFileURL(for: "suggestion.json", session: session)
        if let data = readData(at: currentURL) {
            if let stored = try? JSONDecoder().decode(StoredDeveloperSuggestionDraft.self, from: data),
               stored.schemaVersion == Self.currentSchemaVersion,
               let images = readImages(stored.images, filename: "suggestion.json", revision: stored.assetRevision, session: session) {
                return DeveloperSuggestionDraftSnapshot(
                    text: stored.text,
                    images: images,
                    contact: stored.contact
                )
            }
            if let legacy = try? JSONDecoder().decode(DeveloperSuggestionDraftSnapshot.self, from: data) {
                _ = persistSuggestion(legacy, session: session)
                return legacy
            }
        }

        let previousAccountURL = legacyAccountFileURL(for: "suggestion.json", session: session)
        if previousAccountURL != currentURL, let data = readData(at: previousAccountURL) {
            if let stored = try? JSONDecoder().decode(StoredDeveloperSuggestionDraft.self, from: data),
               stored.schemaVersion == Self.currentSchemaVersion,
               let images = readImages(
                   stored.images,
                   filename: "suggestion.json",
                   revision: stored.assetRevision,
                   session: session,
                   assetDirectory: legacyAssetDirectoryURL(
                       for: "suggestion.json",
                       revision: stored.assetRevision,
                       session: session
                   )
               ) {
                let migrated = DeveloperSuggestionDraftSnapshot(
                    text: stored.text,
                    images: images,
                    contact: stored.contact
                )
                if persistSuggestion(migrated, session: session) {
                    try? files.removeItem(at: previousAccountURL)
                    try? files.removeItem(at: previousAccountURL.appendingPathExtension("assets"))
                }
                return migrated
            }
            if let legacy = try? JSONDecoder().decode(DeveloperSuggestionDraftSnapshot.self, from: data) {
                if persistSuggestion(legacy, session: session) { try? files.removeItem(at: previousAccountURL) }
                return legacy
            }
        }

        let legacyURL = directoryURL.appendingPathComponent("suggestion.json")
        guard let data = readData(at: legacyURL),
              let legacy = try? JSONDecoder().decode(DeveloperSuggestionDraftSnapshot.self, from: data)
        else { return nil }
        if persistSuggestion(legacy, session: session) {
            try? files.removeItem(at: legacyURL)
        }
        return legacy
    }

    @MainActor
    public func removeGallery() async {
        await storage.removeGallery(store: self, session: currentSession())
    }

    @MainActor
    public func removeSuggestion() async {
        await storage.removeSuggestion(store: self, session: currentSession())
    }

    private var directoryURL: URL {
        applicationSupport.appending(path: Self.directoryName, directoryHint: .isDirectory)
    }

    private func readData(at url: URL) -> Data? {
        try? files.setPrivateFileProtection(at: url)
        return try? files.readData(at: url)
    }

    private func write<T: Encodable>(_ value: T, to fileURL: URL) throws {
        try files.createDirectory(at: fileURL.deletingLastPathComponent())
        let data = try JSONEncoder().encode(value)
        try files.writeData(
            data,
            to: fileURL,
            options: AppFileSystem.protectedDataWritingOptions
        )
    }

    private func writeImages(
        _ images: [ComposerImageDraftSnapshot],
        filename: String,
        session: AppStorageSession
    ) throws -> (revision: String, references: [StoredComposerDraftImage]) {
        let revision = UUID().uuidString.lowercased()
        let directory = assetDirectoryURL(for: filename, revision: revision, session: session)
        try files.createDirectory(at: directory)
        do {
            let references = try images.enumerated().map { index, image in
                let source = image.uploadData ?? image.previewData
                let data: Data
                if let uploadData = image.uploadData,
                   uploadData.count <= ComposerDraftImageCompressor.maximumBytes {
                    data = uploadData
                } else {
                    data = try ComposerDraftImageCompressor.compress(source)
                }
                try files.writeData(
                    data,
                    to: directory.appending(path: "image-\(index).jpg"),
                    options: AppFileSystem.protectedDataWritingOptions
                )
                return StoredComposerDraftImage(filename: image.filename)
            }
            return (revision, references)
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
    }

    private func readImages(
        _ references: [StoredComposerDraftImage],
        filename: String,
        revision: String,
        session: AppStorageSession,
        assetDirectory: URL? = nil
    ) -> [ComposerImageDraftSnapshot]? {
        let directory = assetDirectory ?? assetDirectoryURL(for: filename, revision: revision, session: session)
        var images: [ComposerImageDraftSnapshot] = []
        for (index, reference) in references.enumerated() {
            let fileURL = directory.appending(path: "image-\(index).jpg")
            guard let data = readData(at: fileURL) else { return nil }
            images.append(ComposerImageDraftSnapshot(
                filename: reference.filename,
                previewData: data,
                uploadData: data
            ))
        }
        return images
    }

    fileprivate func remove(filename: String, session: AppStorageSession) {
        try? files.removeItem(at: currentFileURL(for: filename, session: session))
        try? files.removeItem(at: directoryURL.appendingPathComponent(filename))
        try? files.removeItem(at: assetRootURL(for: filename, session: session))
    }

    private func currentFileURL(for filename: String, session: AppStorageSession) -> URL {
        applicationSupport
            .appending(path: "BIT101-iOS", directoryHint: .isDirectory)
            .appending(path: session.accountStorageIdentifier, directoryHint: .isDirectory)
            .appending(path: "composer-\(filename)")
    }

    private func legacyAccountFileURL(for filename: String, session: AppStorageSession) -> URL {
        applicationSupport
            .appending(path: "BIT101-iOS", directoryHint: .isDirectory)
            .appending(path: session.legacyAccountDirectoryNameForMigration, directoryHint: .isDirectory)
            .appending(path: "composer-\(filename)")
    }

    private func legacyAssetDirectoryURL(
        for filename: String,
        revision: String,
        session: AppStorageSession
    ) -> URL {
        legacyAccountFileURL(for: filename, session: session)
            .appendingPathExtension("assets")
            .appending(path: revision, directoryHint: .isDirectory)
    }

    private func assetRootURL(for filename: String, session: AppStorageSession) -> URL {
        currentFileURL(for: filename, session: session).appendingPathExtension("assets")
    }

    private func assetDirectoryURL(for filename: String, revision: String, session: AppStorageSession) -> URL {
        assetRootURL(for: filename, session: session).appending(path: revision, directoryHint: .isDirectory)
    }

    fileprivate func storedGalleryRevision(at url: URL) -> String? {
        guard let data = readData(at: url) else { return nil }
        return try? JSONDecoder().decode(StoredGalleryComposerDraft.self, from: data).assetRevision
    }

    fileprivate func storedSuggestionRevision(at url: URL) -> String? {
        guard let data = readData(at: url) else { return nil }
        return try? JSONDecoder().decode(StoredDeveloperSuggestionDraft.self, from: data).assetRevision
    }

    private func removeAssets(for filename: String, revision: String, session: AppStorageSession) {
        try? files.removeItem(at: assetDirectoryURL(for: filename, revision: revision, session: session))
    }

    private func removeObsoleteAssetRevisions(
        for filename: String,
        keeping revision: String?,
        session: AppStorageSession
    ) throws {
        let root = assetRootURL(for: filename, session: session)
        guard files.fileExists(at: root) else { return }
        let revisions = try files.contentsOfDirectory(at: root, options: [])
        for oldRevision in revisions where oldRevision.lastPathComponent != revision {
            try files.removeItem(at: oldRevision)
        }
    }
}

private actor ComposerDraftStorage {
    func saveGallery(store: ComposerDraftStore, _ snapshot: GalleryComposerDraftSnapshot, session: AppStorageSession) -> Bool {
        store.persistGallery(snapshot, session: session)
    }

    func loadGallery(store: ComposerDraftStore, session: AppStorageSession) -> GalleryComposerDraftSnapshot? {
        store.loadGallery(session: session)
    }

    func saveSuggestion(store: ComposerDraftStore, _ snapshot: DeveloperSuggestionDraftSnapshot, session: AppStorageSession) -> Bool {
        store.persistSuggestion(snapshot, session: session)
    }

    func loadSuggestion(store: ComposerDraftStore, session: AppStorageSession) -> DeveloperSuggestionDraftSnapshot? {
        store.loadSuggestion(session: session)
    }

    func removeGallery(store: ComposerDraftStore, session: AppStorageSession) {
        store.remove(filename: "gallery.json", session: session)
    }

    func removeSuggestion(store: ComposerDraftStore, session: AppStorageSession) {
        store.remove(filename: "suggestion.json", session: session)
    }
}

public enum ComposerDraftImageCompressor {
    public nonisolated static let maximumBytes = 1 * 1_024 * 1_024

    public nonisolated static func compress(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 1600
                  ] as CFDictionary
              ) else {
            throw GalleryServiceError.uploadFailed
        }

        var best = render(image: image, maxDimension: 1600, quality: 0.68)
        if best.count <= maximumBytes { return best }

        for quality in [0.48, 0.32, 0.2] {
            best = render(image: image, maxDimension: 1600, quality: quality)
            if best.count <= maximumBytes { return best }
        }

        for dimension in [1200, 900, 700, 512, 384, 256] {
            best = render(image: image, maxDimension: CGFloat(dimension), quality: 0.5)
            if best.count <= maximumBytes { return best }
        }
        guard best.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        return best
    }

    private nonisolated static func render(
        image: CGImage,
        maxDimension: CGFloat,
        quality: CGFloat
    ) -> Data {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = min(1, maxDimension / max(width, height))
        let size = CGSize(
            width: max(1, width * scale),
            height: max(1, height * scale)
        )
        return UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: quality) { context in
            context.cgContext.interpolationQuality = .medium
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

#endif
