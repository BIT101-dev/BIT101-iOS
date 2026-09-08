import Foundation
import UIKit

/// SwiftUI `Text` 以值类型 `AttributedString` 接收文本，`NSCache` 通过对象盒保存解析结果。
private final class GalleryAttributedStringBox: NSObject {
    let value: AttributedString

    init(_ value: AttributedString) {
        self.value = value
    }
}

/// 信息流正文链接解析缓存。
///
/// 卡片在 LazyVStack 中重复出现时，同一正文复用解析结果，避免快速滚动时
/// 重复创建 `NSDataDetector` 并扫描整段文字。
private enum GalleryLinkifiedTextCache {
    static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    static let values: NSCache<NSString, GalleryAttributedStringBox> = {
        let cache = NSCache<NSString, GalleryAttributedStringBox>()
        cache.countLimit = 600
        return cache
    }()
}

/// 将话廊正文中的普通网址转换成系统可点击链接。
///
/// 使用系统 `NSDataDetector` 解析链接，兼容 `https://`、`http://` 和常见的 `www.` 地址，
/// 同时保留用户原本输入的显示文字。
func galleryLinkifiedText(_ text: String) -> AttributedString {
    let key = text as NSString
    if let cached = GalleryLinkifiedTextCache.values.object(forKey: key) {
        return cached.value
    }

    let rendered = NSMutableAttributedString(string: text)
    guard let detector = GalleryLinkifiedTextCache.detector else {
        return AttributedString(text)
    }

    let fullRange = NSRange(text.startIndex ..< text.endIndex, in: text)
    for match in detector.matches(in: text, range: fullRange) {
        guard let url = match.url else { continue }
        rendered.addAttribute(.link, value: url, range: match.range)
    }

    let result = (try? AttributedString(rendered, including: \.uiKit)) ?? AttributedString(text)
    GalleryLinkifiedTextCache.values.setObject(GalleryAttributedStringBox(result), forKey: key)
    return result
}
