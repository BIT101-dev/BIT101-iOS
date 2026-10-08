import Foundation
import UIKit
import ClientCore
import CommunityCore
import CommunityTransport
import CourseFeature
import GalleryFeature
import MineFeature
import PaperFeature
import StorageCore
import TransportCore

#if DEBUG || RELEASE_NETWORK_SMOKE
/// 线上写入的事务记录原子保存到本机专用文件，清理复用服务端读取与删除入口。
@MainActor
final class CommunityWriteSmoke {
    enum Kind: String, Codable, CaseIterable { case poster, paper, course }
    struct Content { let text: String; let owned: Bool; let liked: Bool; var imageMids: [String] = [] }
    struct Operations {
        var identity: () -> CommunitySessionIdentity
        var account: () async throws -> Int
        var course: () async throws -> Int
        var create: (Kind, String) async throws -> Int
        var find: (Kind, String) async throws -> [Int]
        var read: (Kind, Int) async throws -> Content?
        var edit: (Kind, Int, String) async throws -> Void
        var delete: (Kind, Int) async throws -> Void
        var comments: (String) async throws -> [CommunityComment]
        var comment: (String, String) async throws -> CommunityComment
        var deleteComment: (Int) async throws -> Void
        var like: (Kind, Int) async throws -> Bool

        var followTarget: () -> Int? = { nil }
        var following: (Int) async throws -> Bool = { _ in throw URLError(.unsupportedURL) }
        var follow: (Int) async throws -> Bool = { _ in throw URLError(.unsupportedURL) }

        func scoped(to owner: CommunitySessionIdentity) -> Self {
            Self(identity: identity,
                account: { try await Self.checked(identity, owner) { try await account() } },
                course: { try await Self.checked(identity, owner) { try await course() } },
                create: { kind, text in try await Self.checked(identity, owner) { try await create(kind, text) } },
                find: { kind, text in try await Self.checked(identity, owner) { try await find(kind, text) } },
                read: { kind, id in try await Self.checked(identity, owner) { try await read(kind, id) } },
                edit: { kind, id, text in try await Self.checked(identity, owner) { try await edit(kind, id, text) } },
                delete: { kind, id in try await Self.checked(identity, owner) { try await delete(kind, id) } },
                comments: { object in try await Self.checked(identity, owner) { try await comments(object) } },
                comment: { object, text in try await Self.checked(identity, owner) { try await comment(object, text) } },
                deleteComment: { id in try await Self.checked(identity, owner) { try await deleteComment(id) } },
                like: { kind, id in try await Self.checked(identity, owner) { try await like(kind, id) } }, followTarget: followTarget,
                following: { id in try await Self.checked(identity, owner) { try await following(id) } },
                follow: { id in try await Self.checked(identity, owner) { try await follow(id) } })
        }

        private static func checked<Value>(_ identity: () -> CommunitySessionIdentity, _ owner: CommunitySessionIdentity,
            operation: () async throws -> Value) async throws -> Value {
            guard identity() == owner else { throw CancellationError() }
            let result: Result<Value, any Error>
            do { result = .success(try await operation()) }
            catch { result = .failure(error) }
            guard identity() == owner else { throw CancellationError() }
            return try result.get()
        }

        static func isMissingContent(_ error: NSError, kind: Kind) -> Bool {
            switch kind {
            case .paper: return error.domain == "BIT101.Paper" && error.localizedDescription == "文章不存在Orz"
            case .poster: return error.domain == "BIT101.Gallery" && error.localizedDescription == "帖子不存在Orz"
            case .course: return false
            }
        }

        static func production(papers: PaperService = PaperService(), courses: CourseService = CourseService(),
            gallery: GalleryService = GalleryService(), followTarget: Int? = nil) -> Self {
            let mine = MineService()
            return Self(identity: { AppAccountSession.storage.communityCredentials.identity }, account: { try await mine.fetchMyInfo().user.id }, course: {
                guard let course = try await courses.fetchCourses(search: "", page: 0).first else { throw URLError(.zeroByteResource) }
                return course.id
            }, create: { kind, text in
                switch kind {
                case .poster:
                    let image = try await gallery.uploadImage(data: CommunityWriteMedia.jpeg(), filename: "smoke.jpg")
                    guard !image.mid.isEmpty else { throw URLError(.cannotParseResponse) }
                    let id = try await gallery.createPoster(title: "功能验收", text: text,
                        imageMids: [image.mid], anonymous: false, tags: [], claimID: 0, isPublic: false)
                    guard try await gallery.fetchPoster(id: id).images.map(\.mid) == [image.mid] else { throw URLError(.cannotParseResponse) }
                    return id
                case .paper: return try await papers.createPaper(title: text, intro: text,
                    content: PaperEditorContentBuilder.editorJSON(from: text), anonymous: false, publicEdit: false)
                case .course: throw URLError(.unsupportedURL)
                }
            }, find: { kind, text in
                var result: Set<Int> = []
                var progress = CommunityPageProgress<Int>()
                var page = 0
                while true {
                    if kind == .poster {
                        let rows = try await mine.fetchMyPosters(page: page)
                        if rows.isEmpty { return result.sorted() }
                        try progress.record(rows.map(\.id))
                        result.formUnion(rows.filter { $0.text.contains(text) }.map(\.id))
                    } else {
                        let rows = try await papers.fetchPapers(search: text, order: .newest, page: page)
                        if rows.isEmpty { return result.sorted() }
                        try progress.record(rows.map(\.id))
                        for row in rows {
                            do {
                                let detail = try await papers.fetchPaper(id: row.id)
                                if detail.own && PaperEditorContentBuilder.plainText(from: detail.content).contains(text) { result.insert(row.id) }
                            } catch let error as NSError where Self.isMissingContent(error, kind: .paper) { continue }
                        }
                    }
                    page += 1
                }
            }, read: { kind, id in
                do {
                    switch kind {
                    case .poster:
                        let value = try await gallery.fetchPoster(id: id)
                        return Content(text: value.text, owned: value.own, liked: value.like, imageMids: value.images.map(\.mid))
                    case .paper:
                        let value = try await papers.fetchPaper(id: id)
                        return Content(text: PaperEditorContentBuilder.plainText(from: value.content), owned: value.own, liked: value.like)
                    case .course:
                        let value = try await courses.fetchCourse(id: id)
                        return Content(text: "", owned: false, liked: value.like)
                    }
                } catch let error as NSError where Self.isMissingContent(error, kind: kind) {
                    return nil
                }
            }, edit: { kind, id, text in
                switch kind {
                case .poster:
                    let current = try await gallery.fetchPoster(id: id)
                    guard !current.images.isEmpty else { throw URLError(.cannotParseResponse) }
                    try await gallery.updatePoster(id: id, title: "功能验收", text: text,
                        imageMids: current.images.map(\.mid), plugins: "[]", anonymous: false, tags: [], claimID: 0, isPublic: false)
                case .paper:
                    let current = try await papers.fetchPaper(id: id)
                    try await papers.updatePaper(id: id, title: text, intro: text,
                        content: PaperEditorContentBuilder.editorJSON(from: text), anonymous: false, publicEdit: false,
                        lastUpdatedAt: current.updateTime)
                case .course: throw URLError(.unsupportedURL)
                }
            }, delete: { kind, id in
                if kind == .poster { try await gallery.deletePoster(id: id) }
                else { try await papers.deletePaper(id: id) }
            }, comments: { object in
                var result: [Int: CommunityComment] = [:]
                var progress = CommunityPageProgress<Int>()
                var page = 0
                while true {
                    let rows = try await gallery.fetchRawComments(objectID: object, order: .oldest, page: page)
                    if rows.isEmpty { return result.values.sorted { $0.id < $1.id } }
                    try progress.record(rows.map(\.id))
                    for row in rows { result[row.id] = row }
                    page += 1
                }
            }, comment: { object, text in
                let value: CommunityComment
                if object.hasPrefix("course") { value = try await courses.createComment(objectID: object, text: text, rate: 6) }
                else if object.hasPrefix("paper") { value = try await papers.createComment(objectID: object, text: text) }
                else {
                    let image = try await gallery.uploadCommentImage(data: CommunityWriteMedia.jpeg(), filename: "smoke.jpg")
                    value = try await gallery.createComment(objectID: object, text: text, imageMids: [image.mid])
                    guard !image.mid.isEmpty, value.images.map(\.mid) == [image.mid] else { throw URLError(.cannotParseResponse) }
                }
                try await Task.sleep(for: .seconds(1))
                return value
            }, deleteComment: { try await gallery.deleteComment(id: $0) }, like: { kind, id in
                let value: Bool
                switch kind {
                case .poster: value = try await gallery.like(objectID: "poster\(id)").like
                case .paper: value = try await papers.likePaper(id: id).like
                case .course: value = try await courses.like(objectID: "course\(id)").like
                }
                try await Task.sleep(for: .seconds(1))
                return value
            }, followTarget: { followTarget }, following: { id in
                let info = try await mine.fetchUserInfo(id: id)
                guard !info.own, info.user.id == id else { throw URLError(.cannotParseResponse) }
                return info.following
            }, follow: { try await mine.followUser(id: $0).following })
        }
    }
    private let operations: Operations
    private let load: () throws -> Data?
    private let save: (Data?) throws -> Void
    private static let journalKey = "network-smoke.community-writes.pending"

    static func loadJournal(files: any AppFileService = AppFileDirectories.files,
        directory: URL = AppFileDirectories.applicationSupport.appendingPathComponent("NetworkSmoke", isDirectory: true),
        legacyData: Data? = AppFileDirectories.defaults.data(forKey: journalKey),
        removeLegacy: () -> Void = { AppFileDirectories.defaults.removeObject(forKey: journalKey) }) throws -> Data? {
        let url = directory.appendingPathComponent("community-write-journal.json")
        if files.fileExists(at: url) {
            let data = try files.readData(at: url)
            let normalized = try normalizedJournalData(data)
            if normalized != data { try saveJournal(normalized, files: files, directory: directory) }
            return normalized
        }
        if let legacyData {
            let normalized = try normalizedJournalData(legacyData)
            try saveJournal(normalized, files: files, directory: directory)
            removeLegacy()
            return normalized
        }
        return nil
    }

    static func saveJournal(_ data: Data?, files: any AppFileService = AppFileDirectories.files,
        directory: URL = AppFileDirectories.applicationSupport.appendingPathComponent("NetworkSmoke", isDirectory: true)) throws {
        let url = directory.appendingPathComponent("community-write-journal.json")
        if let data {
            try files.createDirectory(at: directory)
            try files.writeData(data, to: url, options: AppFileSystem.protectedDataWritingOptions)
        } else if files.fileExists(at: url) {
            try files.removeItem(at: url)
        }
    }

    init(operations: Operations, load: @escaping () throws -> Data? = {
        try CommunityWriteSmoke.loadJournal()
    }, save: @escaping (Data?) throws -> Void = {
        try CommunityWriteSmoke.saveJournal($0)
    }) {
        self.operations = operations; self.load = load; self.save = save
    }

    func run(marker: String, cleanupOnly: Bool = false, expectedAccount: Int? = nil) async throws -> [String] {
        let owner = self.operations.identity()
        let operations = self.operations.scoped(to: owner)
        let account = try await operations.account()
        if !cleanupOnly {
            guard let expectedAccount, expectedAccount > 0, account == expectedAccount
            else { throw failure("社区写入需要与明确指定的专用验收账号一致") }
        }
        if let data = try load() {
            var previous = try JSONDecoder().decode(Journal.self, from: data)
            guard previous.account == account else { throw failure("请登录创建验收内容的账号以完成清理") }
            try await cleanup(&previous, operations: operations, owner: owner)
        }
        guard !cleanupOnly else { return ["服务端清理确认完成"] }
        var journal = Journal(marker: "功能验收 " + marker, account: account)
        journal.evidence.append("验收账号 user\(account)")
        var businessError: (any Error)?
        var operation = "创建内容"
        do {
            guard let followTarget = operations.followTarget(), followTarget > 0,
                  try await operations.following(followTarget) else { throw failure("关注探针需要已关注的专用验收目标") }
            journal.followTarget = followTarget; try persist(journal)
            _ = try await operations.follow(followTarget)
            if try await operations.following(followTarget) == false { _ = try await operations.follow(followTarget) }
            guard try await operations.following(followTarget) else { throw failure("验收关注恢复待完成") }
            journal.evidence.append("关注恢复 user\(followTarget)")
            journal.followTarget = nil; try persist(journal)
            for kind in [Kind.poster, .paper] {
                try Task.checkCancellation()
                journal.attempts.append(kind); try persist(journal)
                operation = "创建 " + kind.rawValue
                let id = try await operations.create(kind, journal.marker)
                let target = Target(kind: kind, id: id)
                journal.targets.append(target); journal.evidence.append("创建 \(kind.rawValue)\(id)")
                try persist(journal)
                operation = "读取 " + kind.rawValue
                guard let created = try await operations.read(kind, id), created.owned,
                      created.text == journal.marker else { throw failure("验收内容创建结果异常") }
                if kind == .poster {
                    guard !created.imageMids.isEmpty else { throw failure("帖子图片引用验收待完成") }
                    journal.evidence.append("图片提交 poster\(id)")
                }
                let edited = journal.marker + " 编辑"
                operation = "编辑 " + kind.rawValue
                try await operations.edit(kind, id, edited)
                guard try await operations.read(kind, id)?.text == edited else { throw failure("验收编辑结果异常") }
            }
            operation = "选择课程"
            let course = try await operations.course()
            journal.targets.append(Target(kind: .course, id: course)); try persist(journal)
            for target in journal.targets {
                operation = "点赞 " + target.kind.rawValue
                try Task.checkCancellation()
                guard try await operations.account() == account else { throw failure("验收账号已切换") }
                guard let before = try await operations.read(target.kind, target.id) else { throw failure("验收目标缺失") }
                journal.likes.append(Like(target: target, original: before.liked)); try persist(journal)
                guard try await operations.like(target.kind, target.id) != before.liked,
                      try await operations.read(target.kind, target.id)?.liked == !before.liked else { throw failure("验收点赞结果异常") }
                guard try await operations.like(target.kind, target.id) == before.liked,
                      try await operations.read(target.kind, target.id)?.liked == before.liked else { throw failure("验收点赞恢复异常") }
                journal.evidence.append("点赞恢复 \(target.kind.rawValue)\(target.id)")
                let parent = target.kind.rawValue + String(target.id)
                journal.parents.append(parent); try persist(journal)
                operation = "评论 " + target.kind.rawValue
                let comment = try await operations.comment(parent, journal.marker)
                guard comment.id > 0, !journal.comments.contains(comment.id) else { throw failure("验收评论标识重复或无效") }
                journal.comments.append(comment.id); journal.evidence.append("创建 comment\(comment.id) 目标 \(parent)")
                journal.commentParents[comment.id] = parent
                if target.kind == .poster {
                    guard !comment.images.isEmpty else { throw failure("评论图片引用验收待完成") }
                    journal.evidence.append("图片提交 comment\(comment.id)")
                }
                let replies = "comment\(comment.id)"
                journal.parents.append(replies); try persist(journal)
                guard comment.own, comment.text == journal.marker,
                      try await operations.comments(parent).contains(where: { $0.id == comment.id }) else { throw failure("验收评论创建结果异常") }
                operation = "回复 " + target.kind.rawValue
                let reply = try await operations.comment(replies, journal.marker)
                guard reply.id > 0, !journal.comments.contains(reply.id) else { throw failure("验收回复标识重复或无效") }
                journal.comments.append(reply.id); journal.evidence.append("创建 comment\(reply.id) 目标 \(replies)")
                journal.commentParents[reply.id] = replies
                try persist(journal)
                guard reply.own, reply.text == journal.marker,
                      try await operations.comments(replies).contains(where: { $0.id == reply.id }) else { throw failure("验收回复创建结果异常") }
            }
        } catch { businessError = failure(operation + "：" + error.localizedDescription) }
        let snapshot = journal
        let cleaned = await Task { @MainActor [self] in
            var pending = snapshot
            do { try await cleanup(&pending, operations: operations, owner: owner); return Result<[String], any Error>.success(pending.evidence) }
            catch { return .failure(error) }
        }.value
        let evidence = try cleaned.get()
        if let businessError { throw failure("写入验收待完成，服务端清理已确认：" + businessError.localizedDescription) }
        return evidence
    }

    private func persist(_ journal: Journal) throws { try save(JSONEncoder().encode(journal)) }

    private func cleanup(_ journal: inout Journal, operations: Operations, owner: CommunitySessionIdentity) async throws {
        var failures: [String] = []
        if let target = journal.followTarget {
            if try await recoverOperation("恢复关注", failures: &failures, operation: {
                if try await operations.following(target) == false { _ = try await operations.follow(target) }
                guard try await operations.following(target) else { throw failure("验收关注恢复待完成") }
            }) {
                journal.followTarget = nil
            }
            try persist(journal)
        }
        var discovered: Set<Kind> = []
        for kind in Set(journal.attempts) {
            if try await recoverOperation("查找 " + kind.rawValue, failures: &failures, operation: {
                for id in try await operations.find(kind, journal.marker) {
                    let target = Target(kind: kind, id: id)
                    if !journal.targets.contains(target) { journal.targets.append(target) }
                }
            }) {
                discovered.insert(kind)
            }
        }
        try persist(journal)
        for like in journal.likes {
            if try await recoverOperation("恢复点赞 " + like.target.kind.rawValue, failures: &failures, operation: {
                if let current = try await operations.read(like.target.kind, like.target.id), current.liked != like.original {
                    _ = try await operations.like(like.target.kind, like.target.id)
                }
                if let restored = try await operations.read(like.target.kind, like.target.id), restored.liked != like.original {
                    throw failure("点赞恢复待完成")
                }
            }) {
                journal.likes.removeAll { $0.target == like.target }
            }
            try persist(journal)
        }
        var parentIndex = 0
        while parentIndex < journal.parents.count {
            let parent = journal.parents[parentIndex]
            parentIndex += 1
            _ = try await recoverOperation("查找评论 " + parent, failures: &failures, operation: {
                for comment in try await operations.comments(parent) where comment.own && comment.text == journal.marker {
                    if !journal.comments.contains(comment.id) { journal.comments.append(comment.id) }
                    journal.commentParents[comment.id] = parent
                    if !parent.hasPrefix("comment") {
                        let replies = "comment\(comment.id)"
                        if !journal.parents.contains(replies) { journal.parents.append(replies) }
                    }
                }
            })
        }
        journal.comments = journal.comments.reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
        try persist(journal)
        let commentIDs = journal.comments
        for id in journal.comments.reversed() {
            if try await recoverOperation("删除 comment\(id)", failures: &failures, operation: {
                let replies = "comment\(id)"
                if journal.parents.contains(replies) {
                    guard try await operations.comments(replies).allSatisfy({ !commentIDs.contains($0.id) && !($0.own && $0.text == journal.marker) })
                    else { throw failure("验收回复清理待完成") }
                    retireComments(replies, journal: &journal)
                    try persist(journal)
                }
                try await operations.deleteComment(id)
            }) {
                journal.evidence.append("删除 comment\(id)")
            }
            try persist(journal)
        }
        for parent in journal.parents {
            if try await recoverOperation("确认评论删除 " + parent, failures: &failures, operation: {
                guard try await operations.comments(parent).allSatisfy({ !commentIDs.contains($0.id) && !($0.own && $0.text == journal.marker) })
                else { throw failure("验收评论清理待完成") }
            }) {
                retireComments(parent, journal: &journal)
            }
            try persist(journal)
        }
        if !journal.comments.isEmpty { failures.append("验收评论需要服务端删除确认") }
        for target in journal.targets.reversed() where target.kind != .course {
            if try await recoverOperation("删除 " + target.kind.rawValue, failures: &failures, operation: {
                guard !journal.parents.contains(target.kind.rawValue + String(target.id)) else { throw failure("验收评论清理待完成") }
                if let current = try await operations.read(target.kind, target.id) {
                    guard current.owned, current.text.hasPrefix(journal.marker) else { throw failure("验收清理目标身份异常") }
                    try await operations.delete(target.kind, target.id)
                }
                guard try await operations.read(target.kind, target.id) == nil else { throw failure("验收内容清理待完成") }
            }) {
                journal.targets.removeAll { $0 == target }
                journal.likes.removeAll { $0.target == target }
                journal.evidence.append("服务端确认删除 \(target.kind.rawValue)\(target.id)")
            }
            try persist(journal)
        }
        journal.attempts.removeAll { kind in discovered.contains(kind) && !journal.targets.contains(where: { $0.kind == kind }) }
        guard operations.identity() == owner else { throw failure("验收账号已切换，清理记录已保留") }
        if !failures.isEmpty { try persist(journal); throw failure(failures.joined(separator: "；")) }
        try save(nil)
    }

    private func retireComments(_ parent: String, journal: inout Journal) {
        let ids = journal.commentParents.filter { $0.value == parent }.map(\.key)
        journal.comments.removeAll { ids.contains($0) }
        for id in ids { journal.commentParents.removeValue(forKey: id) }
        journal.parents.removeAll { $0 == parent }
        for id in ids where !journal.evidence.contains("服务端确认删除 comment\(id)") {
            journal.evidence.append("服务端确认删除 comment\(id)")
        }
    }

    private func recoverOperation(_ name: String, failures: inout [String], operation: () async throws -> Void) async throws -> Bool {
        do { try await operation(); return true }
        catch {
            if TaskCancellation.matches(error) { throw error }
            failures.append(name + "：" + error.localizedDescription)
            return false
        }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "BIT101.CommunityWriteSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#endif

/// ReleaseNetworkSmokeRunner 在当前进程执行发布前网络探针。
///
/// 这份实现同时服务于：
/// - 真机采样宿主：通过 `bit101://network-smoke/...` 在当前进程内复用会话执行；
/// - XCTest：保留一个直接调用入口，方便回归和未来 CI 复用同一组探针。
