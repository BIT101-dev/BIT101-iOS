import CommunityCore
import Testing
@testable import GalleryFeature

@Suite("Gallery hidden user policy")
struct GalleryContentFilterTests {
    @Test("Hiding a user also hides replies targeting that user")
    func hidesReplyTarget() {
        let hiddenIDs: Set<Int> = [42]

        #expect(GalleryContentFilter.shouldHideComment(
            authorID: 42,
            replyTargetID: 8,
            isAnonymous: false,
            hiddenUserIDs: hiddenIDs,
            hideAnonymousContent: false
        ))
        #expect(GalleryContentFilter.shouldHideComment(
            authorID: 8,
            replyTargetID: 42,
            isAnonymous: false,
            hiddenUserIDs: hiddenIDs,
            hideAnonymousContent: false
        ))
    }

    @Test("Anonymous filtering remains an independent preference")
    func keepsAnonymousContentWhenPreferenceIsOff() {
        #expect(!GalleryContentFilter.shouldHideComment(
            authorID: 8,
            replyTargetID: 0,
            isAnonymous: true,
            hiddenUserIDs: [],
            hideAnonymousContent: false
        ))
        #expect(GalleryContentFilter.shouldHideComment(
            authorID: 8,
            replyTargetID: 0,
            isAnonymous: true,
            hiddenUserIDs: [],
            hideAnonymousContent: true
        ))
    }
}
