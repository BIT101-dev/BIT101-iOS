import CommunityCore
import Foundation
import Testing

struct CommunityImageURLTests {
    @Test(arguments: ["", " ", "/relative.png", "javascript:alert(1)", "https://"])
    func invalidThumbnailsKeepAUsableOriginal(value: String) {
        let image = CommunityImage(mid: "image", url: " https://example.com/original.png\n", lowUrl: value)
        #expect(image.thumbnailURL?.absoluteString == "https://example.com/original.png")
        #expect(image.originalURL == image.thumbnailURL)
    }

    @Test func validAddressesPreserveTheRequestedImageQuality() {
        let image = CommunityImage(mid: "image", url: "https://example.com/original.png", lowUrl: " https://example.com/thumbnail.png ")
        #expect(image.thumbnailURL?.lastPathComponent == "thumbnail.png")
        #expect(image.originalURL?.lastPathComponent == "original.png")
        let thumbnail = CommunityImage(mid: "image", url: "invalid", lowUrl: image.lowUrl)
        #expect(thumbnail.originalURL == image.thumbnailURL)
        #expect(CommunityImage(mid: "image", url: "invalid", lowUrl: " ").thumbnailURL == nil)
    }
}
