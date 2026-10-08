import UIKit
import Foundation

#if DEBUG || RELEASE_NETWORK_SMOKE
@MainActor
enum CommunityWriteMedia {
    static func jpeg() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        guard let data = image.jpegData(compressionQuality: 1) else { throw URLError(.cannotDecodeContentData) }
        return data
    }
}
#endif
