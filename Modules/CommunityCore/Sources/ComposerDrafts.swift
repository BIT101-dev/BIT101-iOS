import Foundation

public nonisolated struct ComposerImageDraft: Identifiable, Sendable {
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

public nonisolated enum ComposerDraftImagePolicy {
    public static let maximumBytes = 1 * 1_024 * 1_024
    public static let maximumImageCount = 9
    public static let maximumMetadataBytes = maximumBytes
    public static let maximumLegacyMetadataBytes = maximumImageCount * 2 * ((maximumBytes + 2) / 3 * 4) + maximumMetadataBytes
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

/// 清理操作捕获提交所属账号和草稿版本，异步执行语义由公共契约统一。
public typealias ComposerDraftCleanup = @Sendable () async -> Void

/// 草稿读取结果保留源文件的恢复状态，保存沿同一结果判断写权限。
public nonisolated enum ComposerDraftLoadResult<Snapshot: Sendable>: Sendable {
    case missing
    case loaded(Snapshot)
    case unreadable
    case unsupportedVersion(Int)

    public var snapshot: Snapshot? {
        guard case .loaded(let snapshot) = self else { return nil }
        return snapshot
    }

    public var allowsWrite: Bool {
        switch self {
        case .missing, .loaded: true
        case .unreadable, .unsupportedVersion: false
        }
    }

    public var recoveryMessage: String? {
        switch self {
        case .missing, .loaded: nil
        case .unreadable: "草稿原文件与图片已保留，保存已暂停。请联系维护者恢复草稿后重试。"
        case .unsupportedVersion: "草稿由其他格式版本保存，原文件与图片已保留。请使用支持该格式的版本恢复草稿。"
        }
    }
}

@MainActor
public protocol GalleryComposerDraftStoring: Sendable {
    func saveGallery(_ snapshot: GalleryComposerDraftSnapshot) async -> Bool
    func loadGallery() async -> ComposerDraftLoadResult<GalleryComposerDraftSnapshot>
    func removeGallery() async
    func captureGalleryCleanup() async -> ComposerDraftCleanup
}

@MainActor
public protocol DeveloperSuggestionDraftStoring: Sendable {
    func saveSuggestion(_ snapshot: DeveloperSuggestionDraftSnapshot) async -> Bool
    func loadSuggestion() async -> ComposerDraftLoadResult<DeveloperSuggestionDraftSnapshot>
    func removeSuggestion() async
    func captureSuggestionCleanup() async -> ComposerDraftCleanup
}
