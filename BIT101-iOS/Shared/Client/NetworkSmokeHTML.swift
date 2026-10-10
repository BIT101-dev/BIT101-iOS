import Foundation

#if DEBUG || RELEASE_NETWORK_SMOKE
/// 分享页合同沿 HTML 标签和 anchor 属性核对可打开的 App 链接。
nonisolated enum NetworkSmokeHTML {
    static func validate(_ html: String, appURL: String?) throws {
        let tags = try NSRegularExpression(
            pattern: #"<!--[\s\S]*?(?:-->|$)|<(script|style|textarea|title|xmp|iframe|noembed|noframes)\b(?:[^>"']|"[^"]*"|'[^']*')*>.*?(?:</\1\s*>|$)|<![^>]*>|<\s*(/?)\s*([a-z][a-z0-9:-]*)(\s+(?:[^>"']|"[^"]*"|'[^']*')*)?\s*/?>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators])
        let attributes = try NSRegularExpression(
            pattern: #"(?:^|\s)([^\s=/<>"']+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>"'=<>`]+)))?"#)
        var document = false
        var linked = appURL == nil
        var templateDepth = 0
        for tag in tags.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let tagRange = Range(tag.range, in: html) else { continue }
            let text = String(html[tagRange])
            if text.range(of: #"^<!doctype\s+html(?:\s|>)"#, options: [.regularExpression, .caseInsensitive]) != nil {
                document = true
            }
            guard let nameRange = Range(tag.range(at: 3), in: html) else { continue }
            let name = html[nameRange].lowercased()
            let closing = tag.range(at: 2).length > 0
            if name == "template" {
                templateDepth = max(0, templateDepth + (closing ? -1 : 1))
                continue
            }
            guard templateDepth == 0, closing == false else { continue }
            if name == "html" { document = true }
            guard name == "a", let appURL, let attributeRange = Range(tag.range(at: 4), in: html) else { continue }
            let source = String(html[attributeRange])
            for attribute in attributes.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                guard let keyRange = Range(attribute.range(at: 1), in: source), source[keyRange].lowercased() == "href" else { continue }
                let value = (2...4).compactMap { Range(attribute.range(at: $0), in: source) }.first.map { String(source[$0]) } ?? ""
                if try decodeEntities(value) == appURL { linked = true }
                break
            }
        }
        guard document, linked else { throw URLError(.cannotParseResponse) }
    }

    private static func decodeEntities(_ value: String) throws -> String {
        let entities = try NSRegularExpression(pattern: #"&(?:#x([0-9a-fA-F]+)|#([0-9]+)|(amp|quot|apos|lt|gt));"#)
        let named = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">"]
        var decoded = value
        for entity in entities.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            let replacement: String?
            if let hex = Range(entity.range(at: 1), in: value) {
                replacement = Int(value[hex], radix: 16).flatMap(UnicodeScalar.init).map(String.init)
            } else if let decimal = Range(entity.range(at: 2), in: value) {
                replacement = Int(value[decimal]).flatMap(UnicodeScalar.init).map(String.init)
            } else if let name = Range(entity.range(at: 3), in: value) {
                replacement = named[String(value[name])]
            } else { replacement = nil }
            if let replacement, let range = Range(entity.range, in: decoded) {
                decoded.replaceSubrange(range, with: replacement)
            }
        }
        return decoded
    }
}
#endif
