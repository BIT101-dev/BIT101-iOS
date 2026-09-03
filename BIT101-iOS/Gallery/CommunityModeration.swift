import Foundation

/// 社区本地治理工具。
enum CommunityModeration {
    /// 机器人帖子常见标签的归一化集合。
    ///
    /// 这些关键词会被用于两个场景：
    /// 1. 识别“机器人”分栏里的帖子。
    /// 2. 决定哪些服务端帖子应绕过本地脏词拦截。
    ///
    /// 在初始化阶段就统一做一次 `normalize`，可以避免后续每次比对时重复归一化。
    private nonisolated static let botTagKeywords = [
        "bot",
        "机器人",
        "通知",
        "新闻"
    ].map(normalize)

    /// 英文白名单。
    ///
    /// 三方英语词库会命中一些普通语境下常见的单词，这里手工白名单掉已知误伤项，
    /// 避免用户正常发帖时因为英文短词被错误拦截。
    private nonisolated static let englishAllowlist: Set<String> = [
        "abuse",
        "aroused"
    ]

    /// 打包进 app 的中文脏词词库。
    private nonisolated static let vendoredChineseWords = loadVendoredWords(fileName: "zh")
    /// 打包进 app 的英文脏词词库。
    private nonisolated static let vendoredEnglishWords = loadVendoredWords(fileName: "en")

    /// 用于补齐“包含空格、大小写、变体较多”的敏感词规则。
    ///
    /// 这些表达式更适合处理英文和组合词，避免单纯的 `contains` 无法覆盖的写法。
    private nonisolated static let blockedRegexPatterns = [
        #"(?i)\bfuck\b"#,
        #"(?i)\bbitch\b"#,
        #"(?i)\bslut\b"#,
        #"(?i)\bkill\s*yourself\b"#,
        #"(?i)\bnigger\b"#,
        #"(?i)\brape\b"#,
        #"(?i)\bporn\b"#,
        #"(?i)\bheroin\b"#,
        #"(?i)\bcocaine\b"#
    ]

    /// 对单段文本做本地脏词检测。
    nonisolated static func containsBlockedContent(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let normalized = normalize(trimmed)
        if vendoredChineseWords.contains(where: { normalized.contains($0) }) {
            return true
        }

        let lowered = trimmed.lowercased()
        if vendoredEnglishWords.contains(where: { matchesEnglishWord($0, in: lowered) }) {
            return true
        }

        return blockedRegexPatterns.contains { pattern in
            trimmed.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// 批量检测多段文本，任意一段命中即视为违规。
    nonisolated static func containsBlockedContent(in texts: [String]) -> Bool {
        texts.contains { containsBlockedContent($0) }
    }

    /// 判断一条帖子是否带有机器人标签。
    ///
    /// 这里不直接依赖某个单一标签值，而是容忍 `bot/机器人/通知/新闻` 等多种来源。
    /// 这样即使服务端不同历史帖子使用了不同标签命名，也能统一识别到机器人帖子。
    nonisolated static func isBotPoster(tags: [String]) -> Bool {
        let normalizedTags = tags.map(normalize)
        return normalizedTags.contains { tag in
            botTagKeywords.contains(where: { keyword in tag.contains(keyword) })
        }
    }

    /// 带机器人标签的服务端帖子不参与本地脏词过滤。
    ///
    /// 这条例外只作用于入站展示过滤，不影响用户主动发帖时的检测。
    nonisolated static func shouldBypassDirtyWords(tags: [String]) -> Bool {
        isBotPoster(tags: tags)
    }

    /// 发帖前对标题、正文和标签执行统一校验。
    nonisolated static func validateDraft(title: String, text: String, tags: [String]) -> String? {
        let texts = [title, text] + tags
        guard containsBlockedContent(in: texts) else { return nil }
        return "内容包含违规词，请修改后再发布。"
    }

    /// 发评论前执行本地校验。
    nonisolated static func validateCommentDraft(text: String) -> String? {
        guard containsBlockedContent(text) else { return nil }
        return "评论包含违规词，请修改后再发送。"
    }

    /// 判断单个帖子是否通过本地内容过滤。
    nonisolated static func isPosterVisible(_ poster: GalleryPoster) -> Bool {
        if shouldBypassDirtyWords(tags: poster.tags) { return true }
        let posterTexts = [poster.title, poster.text, poster.user.nickname, poster.user.motto] + poster.tags
        return !containsBlockedContent(in: posterTexts)
    }

    /// 过滤整批帖子列表。
    nonisolated static func filterVisiblePosters(_ posters: [GalleryPoster]) -> [GalleryPoster] {
        posters.filter(isPosterVisible)
    }

    /// 判断单条评论是否通过本地内容过滤。
    nonisolated static func isCommentVisible(_ comment: GalleryComment) -> Bool {
        let commentTexts = [comment.text, comment.user.nickname, comment.user.motto]
        return !containsBlockedContent(in: commentTexts)
    }

    /// 递归过滤评论树，同时保留仍然可见的子评论。
    nonisolated static func filterVisibleComments(_ comments: [GalleryComment]) -> [GalleryComment] {
        comments.compactMap { comment in
            guard isCommentVisible(comment) else { return nil }
            return comment.replacingSubComments(filterVisibleComments(comment.sub))
        }
    }

    /// 统一归一化文本，去掉大小写、空白和标点差异，减少规避检测的空间。
    private nonisolated static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let removedWhitespace = lowered.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
            !CharacterSet.punctuationCharacters.contains(scalar) &&
            !CharacterSet.symbols.contains(scalar)
        }
        return String(String.UnicodeScalarView(removedWhitespace))
    }

    /// 对英语脏词做单词级匹配，避免普通长单词误伤。
    ///
    /// 如果词条本身包含符号，则退回简单包含匹配；纯字母数字词则使用正则边界，
    /// 确保例如 `class` 不会误伤 `ass` 这类短词。
    private nonisolated static func matchesEnglishWord(_ word: String, in text: String) -> Bool {
        guard !englishAllowlist.contains(word) else { return false }

        if word.contains(where: { !$0.isLetter && !$0.isNumber }) {
            return text.contains(word)
        }

        let pattern = "(?<![a-z0-9])\(NSRegularExpression.escapedPattern(for: word))(?![a-z0-9])"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// 从打包进 app 的词表文件中加载中英文脏词。
    ///
    /// 词库在不同构建阶段可能被放到不同目录，所以这里做了多级兜底查找。
    /// 输出时会统一 trim、归一化，并滤掉过短词条，减少无意义命中。
    private nonisolated static func loadVendoredWords(fileName: String) -> [String] {
        guard let url = vendoredWordListURL(fileName: fileName),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }

        return contents
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(normalize)
            .filter { $0.count >= 2 }
    }

    /// 在主 bundle 中查找词表文件位置。
    private nonisolated static func vendoredWordListURL(fileName: String) -> URL? {
        if let bundled = Bundle.main.url(forResource: fileName, withExtension: "txt", subdirectory: "Resources/DirtyWords") {
            return bundled
        }

        if let bundled = Bundle.main.url(forResource: fileName, withExtension: "txt", subdirectory: "ThirdParty/profanity-list/list") {
            return bundled
        }

        if let resourceURL = Bundle.main.resourceURL {
            let copiedResource = resourceURL.appendingPathComponent("Resources/DirtyWords/\(fileName).txt")
            if FileManager.default.fileExists(atPath: copiedResource.path) {
                return copiedResource
            }

            let direct = resourceURL.appendingPathComponent("ThirdParty/profanity-list/list/\(fileName).txt")
            if FileManager.default.fileExists(atPath: direct.path) {
                return direct
            }
        }

        return nil
    }
}
