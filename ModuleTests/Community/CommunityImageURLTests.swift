import CommunityCore
import Foundation
import Testing

struct CommunityImageURLTests {
    @Test(arguments: [#"{"id":7}"#, #"{"id":7,"nickname":null,"avatar":{},"identity":false,"motto":2}"#])
    func optionalProfileMetadataPreservesTheUsersIdentity(body: String) throws {
        let user = try JSONDecoder().decode(CommunityUser.self, from: Data(body.utf8))
        #expect(user.id == 7 && user.nickname == "未命名用户")
        #expect(user.avatar.thumbnailURL == nil && user.identity.text.isEmpty && user.motto.isEmpty)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(CommunityUser.self, from: Data(#"{"nickname":"用户"}"#.utf8)) }
    }

    @Test func missingImageVariantsKeepTheirAvailableAddress() throws {
        let image = try JSONDecoder().decode(CommunityImage.self, from: Data(#"{"mid":"image","url":"https://example.com/original.png"}"#.utf8))
        #expect(image.thumbnailURL?.lastPathComponent == "original.png")
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(CommunityImage.self, from: Data(#"{"url":"https://example.com/original.png"}"#.utf8)) }
        let identity = try JSONDecoder().decode(CommunityIdentity.self, from: Data(#"{"id":1,"text":"认证"}"#.utf8))
        #expect(identity.text == "认证" && identity.color.isEmpty)
    }

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
