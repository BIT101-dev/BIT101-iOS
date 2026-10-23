import BIT101TestSupport
import CommunityCore
import CommunityPersistence
import Foundation
import StorageCore
import Testing

@MainActor
struct ComposerImagePersistenceTests {
    @Test(.timeLimit(.minutes(1))) func completedUploadsRoundTripWithReusableLocalAssets() async throws {
        let files = ModuleScoreFiles()
        let session = AppStorageSession(accountIdentifier: "composer-images")
        let store = ComposerDraftStore(files: files, applicationSupport: URL(fileURLWithPath: "/composer-images"),
            session: { session }, prepareImageData: { $0 })
        let uploaded = CommunityImage(mid: "uploaded", url: "https://example.invalid/image.jpg", lowUrl: "")
        var snapshot = GalleryComposerDraftSnapshot(title: "草稿", text: "正文", selectedTags: [], customTags: [],
            anonymous: false, isPublic: true, selectedClaimID: 0, images: [
                .init(filename: "image.jpg", previewData: Data([7]), uploadData: Data([7]), uploadedImage: uploaded)
            ])
        #expect(await store.saveGallery(snapshot))
        #expect(await store.loadGallery().snapshot?.images == snapshot.images)
        let assets = Set(files.storedData.keys.filter { $0.pathExtension == "jpg" })
        snapshot.images = [.init(filename: "image.jpg", previewData: Data([7]), uploadData: Data([7]))]
        #expect(await store.saveGallery(snapshot))
        #expect(await store.loadGallery().snapshot?.images.first?.uploadedImage == nil)
        #expect(Set(files.storedData.keys.filter { $0.pathExtension == "jpg" }) == assets)
        snapshot.images = [.init(filename: "image.jpg", previewData: Data([7]), uploadData: Data([7]), uploadedImage: uploaded)]
        #expect(await store.saveGallery(snapshot))
        #expect(await store.loadGallery().snapshot?.images.first?.uploadedImage == uploaded)
        #expect(Set(files.storedData.keys.filter { $0.pathExtension == "jpg" }) == assets)
    }

    @Test func snapshotsWithoutUploadMetadataRemainReadable() throws {
        let bytes = Data(#"{"filename":"image.jpg","previewData":"Bw=="}"#.utf8)
        let image = try JSONDecoder().decode(ComposerImageDraftSnapshot.self, from: bytes)
        #expect(image.previewData == Data([7]) && image.uploadedImage == nil && image.uploadData == nil)
    }
}
