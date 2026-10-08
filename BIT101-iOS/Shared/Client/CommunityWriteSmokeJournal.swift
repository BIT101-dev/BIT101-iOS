import Foundation

#if DEBUG || RELEASE_NETWORK_SMOKE
extension CommunityWriteSmoke {
    struct Target: Codable, Hashable { let kind: Kind; let id: Int }
    struct Like: Codable { let target: Target; let original: Bool }

    struct Journal: Codable {
        static let currentVersion = 3
        let schemaVersion: Int
        let marker: String
        let account: Int
        var attempts: [Kind] = []
        var targets: [Target] = []
        var parents: [String] = []
        var comments: [Int] = []
        var commentParents: [Int: String] = [:]
        var likes: [Like] = []
        var followTarget: Int?
        var evidence: [String] = []

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, marker, account, attempts, targets, parents, comments, commentParents, likes, evidence, followTarget
        }

        init(marker: String, account: Int) {
            schemaVersion = Self.currentVersion
            self.marker = marker
            self.account = account
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
            guard (0...Self.currentVersion).contains(schemaVersion) else {
                throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: values,
                    debugDescription: "社区恢复记录需要支持当前格式版本的宿主")
            }
            marker = try values.decode(String.self, forKey: .marker)
            account = try values.decode(Int.self, forKey: .account)
            if schemaVersion == 0 {
                attempts = try values.decodeIfPresent([Kind].self, forKey: .attempts) ?? []
                targets = try values.decodeIfPresent([Target].self, forKey: .targets) ?? []
                parents = try values.decodeIfPresent([String].self, forKey: .parents) ?? []
                comments = try values.decodeIfPresent([Int].self, forKey: .comments) ?? []
                for target in targets {
                    let parent = target.kind.rawValue + String(target.id)
                    if !parents.contains(parent) { parents.append(parent) }
                }
                likes = try values.decodeIfPresent([Like].self, forKey: .likes) ?? []
                evidence = try values.decodeIfPresent([String].self, forKey: .evidence) ?? []
            } else {
                attempts = try values.decode([Kind].self, forKey: .attempts)
                targets = try values.decode([Target].self, forKey: .targets)
                parents = try values.decode([String].self, forKey: .parents)
                comments = try values.decode([Int].self, forKey: .comments)
                likes = try values.decode([Like].self, forKey: .likes)
                evidence = try values.decode([String].self, forKey: .evidence)
            }
            if schemaVersion >= 3 { followTarget = try values.decodeIfPresent(Int.self, forKey: .followTarget) }
            if schemaVersion >= 2 {
                commentParents = try values.decode([Int: String].self, forKey: .commentParents)
            } else {
                for item in evidence {
                    let parts = item.split(separator: " ").map(String.init)
                    guard parts.count == 4, parts[0] == "创建", parts[1].hasPrefix("comment"), parts[2] == "目标",
                          let id = Int(parts[1].dropFirst(7)), comments.contains(id), parents.contains(parts[3]) else { continue }
                    commentParents[id] = parts[3]
                }
            }
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(Self.currentVersion, forKey: .schemaVersion)
            try values.encode(marker, forKey: .marker)
            try values.encode(account, forKey: .account)
            try values.encode(attempts, forKey: .attempts)
            try values.encode(targets, forKey: .targets)
            try values.encode(parents, forKey: .parents)
            try values.encode(comments, forKey: .comments)
            try values.encode(commentParents, forKey: .commentParents)
            try values.encode(likes, forKey: .likes)
            try values.encode(evidence, forKey: .evidence)
            try values.encodeIfPresent(followTarget, forKey: .followTarget)
        }
    }

    static func normalizedJournalData(_ data: Data) throws -> Data {
        let journal = try JSONDecoder().decode(Journal.self, from: data)
        return journal.schemaVersion == Journal.currentVersion ? data : try JSONEncoder().encode(journal)
    }
}
#endif
