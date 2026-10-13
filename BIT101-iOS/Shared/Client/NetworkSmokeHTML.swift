import Foundation

#if DEBUG || RELEASE_NETWORK_SMOKE
/// 分享页沿目的地址与静态可见内容核对入口，浏览器交接沿人工专项验收。
nonisolated enum NetworkSmokeHTML {
    static func validate(_ html: String, appURL: String?) throws {
        let tags = try NSRegularExpression(
            pattern: #"<!--[\s\S]*?(?:-->|$)|<(script|style|textarea|title|xmp|iframe|noembed|noframes|noscript)\b(?:[^>"']|"[^"]*"|'[^']*')*>.*?(?:</\1\s*>|$)|<![^>]*>|<\s*(/?)\s*([a-z][a-z0-9:-]*)(\s+(?:[^>"']|"[^"]*"|'[^']*')*)?\s*/?>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators])
        let attributes = try NSRegularExpression(
            pattern: #"(?:^|\s)([^\s=/<>"']+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>"'=<>`]+)))?"#)
        let scriptOpening = try NSRegularExpression(pattern: #"^<script\b((?:[^>"']|"[^"]*"|'[^']*')*)>"#, options: .caseInsensitive)
        var homeTitle = false
        var homeContent = false
        var homeRoot = false
        var homeModule = false
        var document = false
        var linked = false
        var ancestors: [(name: String, hidden: Bool, appLink: Bool, closedDetails: Bool, summarySeen: Bool)] = []
        var cursor = html.startIndex
        let voidTags: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
        for tag in tags.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let tagRange = Range(tag.range, in: html) else { continue }
            if ancestors.last?.hidden == false, ancestors.last?.closedDetails == false, ancestors.contains(where: \.appLink),
               try hasVisibleText(String(html[cursor..<tagRange.lowerBound])) { linked = true }
            if ancestors.last?.hidden == false, ancestors.last?.closedDetails == false, ancestors.contains(where: { $0.name == "body" }),
               try hasVisibleText(String(html[cursor..<tagRange.lowerBound])) { homeContent = true }
            cursor = tagRange.upperBound
            let text = String(html[tagRange])
            if appURL == nil, ancestors.last?.hidden != true, ancestors.last?.closedDetails != true,
               text.range(of: #"^<title\b[^>]*>\s*BIT101\s*</title\s*>$"#,
                          options: [.regularExpression, .caseInsensitive]) != nil { homeTitle = true }
            if appURL == nil, ancestors.last?.hidden != true, ancestors.last?.closedDetails != true,
               let opening = scriptOpening.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let source = Range(opening.range(at: 1), in: text) {
                let values = attributeValues(String(text[source]), using: attributes)
                let path = values["src"] ?? ""
                if values["type"]?.lowercased() == "module", values["hidden"] == nil,
                   !inlineStyleIsHidden(values["style"] ?? ""), path.hasPrefix("/"), !path.hasPrefix("//"),
                   URL(string: path)?.pathExtension.lowercased() == "js" { homeModule = true }
            }
            if text.range(of: #"^<!doctype\s+html(?:\s|>)"#, options: [.regularExpression, .caseInsensitive]) != nil {
                document = true
            }
            guard let nameRange = Range(tag.range(at: 3), in: html) else { continue }
            let name = html[nameRange].lowercased()
            let closing = tag.range(at: 2).length > 0
            if closing {
                if let index = ancestors.lastIndex(where: { $0.name == name }) { ancestors.removeSubrange(index...) }
                continue
            }
            if name == "html" { document = true }
            let source = Range(tag.range(at: 4), in: html).map { String(html[$0]) } ?? ""
            let values = attributeValues(source, using: attributes)
            let displayIsHidden = inlineStyleIsHidden(try decodeEntities(values["style"] ?? ""))
            let closedParent = ancestors.last?.closedDetails == true
            let visibleSummary = name == "summary" && ancestors.last?.summarySeen == false
            if closedParent, name == "summary" { ancestors[ancestors.count - 1].summarySeen = true }
            let hidden = ancestors.last?.hidden == true || name == "template" || values["hidden"] != nil
                || values["inert"] != nil || displayIsHidden || closedParent && !visibleSummary
                || name == "dialog" && values["open"] == nil
            if !hidden, values["id"] == "app", ancestors.contains(where: { $0.name == "body" }) { homeRoot = true }
            let appLink = try name == "a" && appURL != nil && decodeEntities(values["href"] ?? "") == appURL
            if !hidden, name == "img", ancestors.contains(where: \.appLink),
               !(values["src"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { linked = true }
            if !voidTags.contains(name) { ancestors.append((name, hidden, appLink, name == "details" && values["open"] == nil, false)) }
        }
        if ancestors.last?.hidden == false, ancestors.last?.closedDetails == false, ancestors.contains(where: \.appLink),
           try hasVisibleText(String(html[cursor...])) { linked = true }
        if appURL == nil { linked = homeTitle && (homeContent || homeRoot && homeModule) }
        guard document, linked else { throw URLError(.cannotParseResponse) }
    }

    private static func attributeValues(_ source: String, using attributes: NSRegularExpression) -> [String: String] {
        var values: [String: String] = [:]
        for attribute in attributes.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let keyRange = Range(attribute.range(at: 1), in: source) else { continue }
            let key = source[keyRange].lowercased()
            guard values[key] == nil else { continue }
            let value = (2...4).compactMap { Range(attribute.range(at: $0), in: source) }.first.map { String(source[$0]) } ?? ""
            values[key] = value
        }
        return values
    }

    private static func hasVisibleText(_ text: String) throws -> Bool {
        !(try decodeEntities(text)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func inlineStyleIsHidden(_ style: String) -> Bool {
        let cleaned = style.replacingOccurrences(of: #"/\*.*?\*/"#, with: "", options: .regularExpression).lowercased()
        var properties: [String: (value: String, important: Bool)] = [:]
        for declaration in cleaned.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let property = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard ["display", "visibility", "opacity", "pointer-events"].contains(property) else { continue }
            let value = String(parts[1])
            let important = value.range(of: #"!\s*important\s*$"#, options: .regularExpression) != nil
            if properties[property]?.important == true && !important { continue }
            properties[property] = (value.replacingOccurrences(of: #"!\s*important\s*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines), important)
        }
        let visibility = properties["visibility"]?.value
        let opacity = properties["opacity"].flatMap { Double($0.value.hasSuffix("%") ? String($0.value.dropLast()) : $0.value) }
        return properties["display"]?.value == "none" || visibility == "hidden" || visibility == "collapse"
            || properties["pointer-events"]?.value == "none"
            || opacity.map { $0.isFinite && $0 <= 0 } == true
    }

    private static func decodeEntities(_ value: String) throws -> String {
        let entities = try NSRegularExpression(pattern: #"&(?:#x([0-9a-fA-F]+)|#([0-9]+)|(amp|quot|apos|lt|gt|nbsp));"#)
        let named = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">", "nbsp": "\u{00a0}"]
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
