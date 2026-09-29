import SwiftUI

extension CommunityDestinations {
    static func appDestinations() -> CommunityDestinations {
        CommunityDestinations(
            deletePoster: { try await GalleryService().deletePoster(id: $0) },
            profile: { AnyView(UserProfileRootView(userID: $0)) },
            poster: { AnyView(GalleryPosterDetailView(poster: $0, onDeleted: $1)) },
            papers: { requestedID, surface in AnyView(PaperRootView(requestedPaperID: requestedID, onShowFeed: { surface.wrappedValue = "gallery" })) }
        )
    }
}
