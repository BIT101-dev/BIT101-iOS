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
    nonisolated enum Kind: String, Codable, CaseIterable, Sendable { case poster, paper, course }
    struct Content {
        let text: String; let owned: Bool; let liked: Bool
        var imageMids: [String] = []
        var anonymous = false
        var publicAccess = false
        var title = ""
        var intro = ""
        var tags: [String] = []
        var claimID = 0
        var images: [CommunityImage] = []
    }
    struct CommentDestination {
        let kind: Kind
        let object: String
        var replyObjectID: String? = nil
        var replyUID: Int? = nil
    }
    struct Operations {
        typealias RecordImage = @MainActor (String) throws -> Void
        typealias RecordSubmission = @MainActor () throws -> Void
        var identity: () -> CommunitySessionIdentity
        var account: () async throws -> Int
        var course: () async throws -> Int
        var create: (Kind, String, RecordImage, RecordSubmission) async throws -> Int
        var find: (Kind, String) async throws -> [Int]
        var read: (Kind, Int) async throws -> Content?
        var edit: (Kind, Int, String) async throws -> Void
        var delete: (Kind, Int) async throws -> Void
        var comments: (String, Set<Int>?) async throws -> [CommunityComment]
        var comment: (CommentDestination, String, RecordImage, RecordSubmission) async throws -> CommunityComment
        var deleteComment: (Int) async throws -> Void
        var like: (Kind, Int) async throws -> Bool
        var likeComment: (Kind, Int) async throws -> Bool = { _, _ in throw URLError(.unsupportedURL) }
        var verifyImages: ([CommunityImage]) async throws -> Void = { _ in throw URLError(.unsupportedURL) }

        var followTarget: () -> Int? = { nil }
        var following: (Int) async throws -> Bool = { _ in throw URLError(.unsupportedURL) }
        var follow: (Int) async throws -> Bool = { _ in throw URLError(.unsupportedURL) }

        func scoped(to owner: CommunitySessionIdentity) -> Self {
            Self(identity: identity,
                account: { try await Self.checked(identity, owner) { try await account() } },
                course: { try await Self.checked(identity, owner) { try await course() } },
                create: { kind, text, record, submit in try await Self.checked(identity, owner) {
                    try await create(kind, text, { mid in
                        guard identity() == owner else { throw CancellationError() }
                        try record(mid)
                    }, {
                        try Task.checkCancellation()
                        guard identity() == owner else { throw CancellationError() }
                        try submit()
                    })
                } },
                find: { kind, text in try await Self.checked(identity, owner) { try await find(kind, text) } },
                read: { kind, id in try await Self.checked(identity, owner) { try await read(kind, id) } },
                edit: { kind, id, text in try await Self.checked(identity, owner) { try await edit(kind, id, text) } },
                delete: { kind, id in try await Self.checked(identity, owner) { try await delete(kind, id) } },
                comments: { object, identifiers in try await Self.checked(identity, owner) { try await comments(object, identifiers) } },
                comment: { object, text, record, submit in try await Self.checked(identity, owner) {
                    try await comment(object, text, { mid in
                        guard identity() == owner else { throw CancellationError() }
                        try record(mid)
                    }, {
                        try Task.checkCancellation()
                        guard identity() == owner else { throw CancellationError() }
                        try submit()
                    })
                } },
                deleteComment: { id in try await Self.checked(identity, owner) { try await deleteComment(id) } },
                like: { kind, id in try await Self.checked(identity, owner) { try await like(kind, id) } },
                likeComment: { kind, id in try await Self.checked(identity, owner) { try await likeComment(kind, id) } },
                verifyImages: { images in try await Self.checked(identity, owner) { try await verifyImages(images) } }, followTarget: followTarget,
                following: { id in try await Self.checked(identity, owner) { try await following(id) } },
                follow: { id in try await Self.checked(identity, owner) { try await follow(id) } })
        }

        private static func checked<Value>(_ identity: () -> CommunitySessionIdentity, _ owner: CommunitySessionIdentity,
            operation: () async throws -> Value) async throws -> Value {
            guard identity() == owner else { throw CancellationError() }
            let result: Result<Value, any Error>
            do { result = .success(try await operation()) }
            catch { result = .failure(error) }
            if case let .failure(error) = result, error is SubmissionNotSent { throw error }
            guard identity() == owner else { throw CancellationError() }
            return try result.get()
        }

        static func submission<Value>(_ operation: () async throws -> Value) async throws -> Value {
            var started = false
            do {
                return try await HTTPRequestEvidenceContext.$willStart.withValue({ started = true }) {
                    try await operation()
                }
            } catch {
                if let unsent = error as? HTTPRequestNotSent {
                    throw SubmissionNotSent(underlying: unsent.underlying)
                }
                if started { throw error }
                throw SubmissionNotSent(underlying: error)
            }
        }

        static func isMissingContent(_ error: any Error, kind: Kind) -> Bool {
            switch kind {
            case .paper: if case PaperServiceError.missingPaper = error { return true }; return false
            case .poster: if case GalleryServiceError.missingPoster = error { return true }; return false
            case .course: return false
            }
        }

        static func production(papers: PaperService = PaperService(), courses: CourseService = CourseService(),
            gallery: GalleryService = GalleryService(), mine: MineService = ReleaseNetworkSmokeDependencies.mineService(),
            followTarget: Int? = nil, courseFixture: NetworkSmokeFixtures? = nil,
            verifyImages: @escaping ([CommunityImage]) async throws -> Void = { images in
                let urls = NetworkSmokePaging.imageURLs(in: images)
                guard !urls.isEmpty else { throw URLError(.cannotParseResponse) }
                for value in urls {
                    guard let url = URL(string: value) else { throw URLError(.badURL) }
                    _ = try await ReleaseNetworkSmokeDependencies.probeRemoteImage(at: url)
                }
            }) -> Self {
            return Self(identity: { AppAccountSession.storage.communityCredentials.identity }, account: { try await mine.fetchMyInfo().user.id }, course: {
                guard let fixture = courseFixture, fixture.isValid else { throw URLError(.badURL) }
                let course = try await courses.fetchCourse(id: fixture.courseID)
                guard course.id == fixture.courseID, course.number == fixture.courseNumber else { throw URLError(.cannotParseResponse) }
                return course.id
            }, create: { kind, text, record, submit in
                switch kind {
                case .poster:
                    let image = try await gallery.uploadImage(data: CommunityWriteMedia.jpeg(), filename: "smoke.jpg")
                    guard !image.mid.isEmpty else { throw URLError(.cannotParseResponse) }
                    try record(image.mid)
                    return try await Self.submission {
                        try submit()
                        return try await gallery.createPoster(title: "功能验收", text: text,
                            imageMids: [image.mid], anonymous: false, tags: [], claimID: 0, isPublic: false)
                    }
                case .paper:
                    return try await Self.submission {
                        try submit()
                        return try await papers.createPaper(title: text, intro: text,
                            content: PaperEditorContentBuilder.editorJSON(from: text), anonymous: false, publicEdit: false)
                    }
                case .course: throw URLError(.unsupportedURL)
                }
            }, find: { kind, text in
                var result: Set<Int> = []
                var scanned: Set<Int> = []
                var progress = CommunityPageProgress<Int>()
                var page = 0
                while true {
                    try NetworkSmokePaging.checkSampleBudget(page: page, items: scanned.count)
                    if kind == .poster {
                        let rows = try await mine.fetchMyPosters(page: page)
                        if rows.isEmpty { return result.sorted() }
                        scanned.formUnion(rows.map(\.id))
                        try NetworkSmokePaging.checkSampleBudget(page: page, items: scanned.count)
                        try progress.record(rows.map(\.id))
                        result.formUnion(rows.filter { $0.text.contains(text) }.map(\.id))
                    } else {
                        let rows = try await papers.fetchPapers(search: text, order: .newest, page: page)
                        if rows.isEmpty { return result.sorted() }
                        scanned.formUnion(rows.map(\.id))
                        try NetworkSmokePaging.checkSampleBudget(page: page, items: scanned.count)
                        try progress.record(rows.map(\.id))
                        for row in rows {
                            do {
                                let detail = try await papers.fetchPaper(id: row.id)
                                if detail.own && PaperEditorContentBuilder.plainText(from: detail.content).contains(text) { result.insert(row.id) }
                            } catch let error where Self.isMissingContent(error, kind: .paper) { continue }
                        }
                    }
                    page += 1
                }
            }, read: { kind, id in
                do {
                    switch kind {
                    case .poster:
                        let value = try await gallery.fetchPoster(id: id)
                        return Content(text: value.text, owned: value.own, liked: value.like, imageMids: value.images.map(\.mid),
                            anonymous: value.anonymous, publicAccess: value.public, title: value.title,
                            tags: value.tags, claimID: value.claim.id, images: value.images)
                    case .paper:
                        let value = try await papers.fetchPaper(id: id)
                        return Content(text: PaperEditorContentBuilder.plainText(from: value.content), owned: value.own, liked: value.like,
                            anonymous: value.anonymous, publicAccess: value.publicEdit, title: value.title, intro: value.intro)
                    case .course:
                        let value = try await courses.fetchCourse(id: id)
                        return Content(text: "", owned: false, liked: value.like)
                    }
                } catch let error where Self.isMissingContent(error, kind: kind) {
                    return nil
                }
            }, edit: { kind, id, text in
                switch kind {
                case .poster:
                    let current = try await gallery.fetchPoster(id: id)
                    guard !current.images.isEmpty else { throw URLError(.cannotParseResponse) }
                    try await gallery.updatePoster(id: id, title: "功能验收", text: text,
                        imageMids: current.images.map(\.mid), plugins: "[]", anonymous: false, tags: [], claimID: 0, isPublic: false)
                    for level in [GallerySubscriptionLevel.silent, .update, .comment, .none] {
                        try await gallery.setSubscription(objectID: "poster\(id)", level: level)
                        guard try await gallery.fetchPoster(id: id).subscription == level else {
                            throw URLError(.cannotParseResponse)
                        }
                    }
                case .paper:
                    let current = try await papers.fetchPaper(id: id)
                    try await papers.updatePaper(id: id, title: text, intro: text,
                        content: PaperEditorContentBuilder.editorJSON(from: text), anonymous: false, publicEdit: false,
                        lastUpdatedAt: current.updateTime)
                case .course: throw URLError(.unsupportedURL)
                }
            }, delete: { kind, id in
                if kind == .poster {
                    let detail = try await gallery.fetchPoster(id: id)
                    if (detail.subscription?.rawValue ?? 0) > 0 {
                        try await gallery.setSubscription(objectID: "poster\(id)", level: .none)
                    }
                    try await gallery.deletePoster(id: id)
                }
                else { try await papers.deletePaper(id: id) }
            }, comments: { object, identifiers in
                if identifiers?.isEmpty == true { return [] }
                var result: [Int: CommunityComment] = [:]
                var progress = CommunityPageProgress<Int>()
                var page = 0
                while true {
                    try NetworkSmokePaging.checkSampleBudget(page: page, items: result.count)
                    let rows = try await gallery.fetchRawComments(objectID: object,
                        order: identifiers == nil ? .oldest : .newest, page: page)
                    if rows.isEmpty { return result.values.sorted { $0.id < $1.id } }
                    try progress.record(rows.map(\.id))
                    for row in rows { result[row.id] = row }
                    try NetworkSmokePaging.checkSampleBudget(page: page, items: result.count)
                    if let identifiers, identifiers.isSubset(of: Set(result.keys)) {
                        return result.values.filter { identifiers.contains($0.id) }
                    }
                    page += 1
                }
            }, comment: { destination, text, record, submit in
                let object = destination.object
                let value: CommunityComment
                if destination.kind == .course {
                    value = try await Self.submission {
                        try submit()
                        return try await courses.createComment(objectID: object, text: text,
                            replyObjectID: destination.replyObjectID, replyUID: destination.replyUID,
                            rate: object.hasPrefix("course") ? 6 : nil)
                    }
                } else if destination.kind == .paper {
                    value = try await Self.submission {
                        try submit()
                        return try await papers.createComment(objectID: object, text: text,
                            replyObjectID: destination.replyObjectID, replyUID: destination.replyUID)
                    }
                }
                else {
                    let image = try await gallery.uploadCommentImage(data: CommunityWriteMedia.jpeg(), filename: "smoke.jpg")
                    guard !image.mid.isEmpty else { throw URLError(.cannotParseResponse) }
                    try record(image.mid)
                    value = try await Self.submission {
                        try submit()
                        return try await gallery.createComment(objectID: object, text: text,
                            replyObjectID: destination.replyObjectID, replyUID: destination.replyUID, imageMids: [image.mid])
                    }
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
            }, likeComment: { kind, id in
                let result: CommunityLikeResult
                if kind == .course { result = try await courses.like(objectID: "comment\(id)") }
                else { result = try await gallery.like(objectID: "comment\(id)") }
                try await Task.sleep(for: .seconds(1))
                return result.like
            }, verifyImages: verifyImages, followTarget: { followTarget }, following: { id in
                let info = try await mine.fetchUserInfo(id: id)
                guard !info.own, info.user.id == id else { throw URLError(.cannotParseResponse) }
                let identity = AppAccountSession.storage.communityCredentials.identity
                let posts = try await NetworkSmokePaging.arrayPage(currentIdentity: {
                    AppAccountSession.storage.communityCredentials.identity
                }, load: { try await mine.fetchUserPosters(userID: id, page: $0) })
                guard identity == AppAccountSession.storage.communityCredentials.identity,
                      posts.allSatisfy({ $0.user.id == id }) else { throw URLError(.cannotParseResponse) }
                return info.following
            }, follow: { try await mine.followUser(id: $0).following })
        }
    }
    private let operations: Operations
    struct SubmissionNotSent: LocalizedError {
        let underlying: any Error
        var errorDescription: String? { underlying.localizedDescription }
    }
    private let load: () throws -> Data?
    private let save: (Data?) throws -> Void
    private static let journalKey = ReleaseNetworkSmokeReportStore.communityJournalPreferenceKey

    static func loadJournal(files: any AppFileService = AppFileDirectories.files,
        directory: URL = AppFileDirectories.applicationSupport.appendingPathComponent("NetworkSmoke", isDirectory: true),
        legacyData: Data? = AppFileDirectories.defaults.data(forKey: journalKey),
        removeLegacy: () -> Void = { AppFileDirectories.defaults.removeObject(forKey: journalKey) }) throws -> Data? {
        let url = directory.appendingPathComponent(ReleaseNetworkSmokeReportStore.communityJournalFileName)
        let stored: Data?
        do { stored = try files.readData(at: url) }
        catch {
            guard AppFileSystem.isMissingFile(error) else { throw error }
            stored = nil
        }
        if let data = stored {
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
        let url = directory.appendingPathComponent(ReleaseNetworkSmokeReportStore.communityJournalFileName)
        if let data {
            try files.createDirectory(at: directory)
            try files.writeData(data, to: url, options: AppFileSystem.protectedDataWritingOptions)
        } else {
            try files.removeItemIfPresent(at: url)
        }
    }

    init(operations: Operations, load: @escaping () throws -> Data? = {
        try CommunityWriteSmoke.loadJournal()
    }, save: @escaping (Data?) throws -> Void = {
        try CommunityWriteSmoke.saveJournal($0)
    }) {
        self.operations = operations; self.load = load; self.save = save
    }

    func run(marker: String, cleanupOnly: Bool = false, expectedAccount: Int? = nil,
             recoveryConfirmation: CommunityWriteRecoveryConfirmation? = nil) async throws -> [String] {
        guard recoveryConfirmation == nil || cleanupOnly else { throw failure("服务端未创建确认用于 community-cleanup 范围") }
        let owner = self.operations.identity()
        let operations = self.operations.scoped(to: owner)
        let account = try await operations.account()
        if !cleanupOnly {
            guard let expectedAccount, expectedAccount > 0, account == expectedAccount
            else { throw failure("社区写入需要与明确指定的验收账号一致") }
        }
        var recoveredEvidence: [String] = []
        if let data = try load() {
            var previous = try JSONDecoder().decode(Journal.self, from: data)
            guard previous.account == account else { throw failure("请登录创建验收内容的账号以完成清理") }
            try recoveryConfirmation?.validate(for: previous)
            try await cleanup(&previous, operations: operations, owner: owner, confirmation: recoveryConfirmation)
            recoveredEvidence = previous.evidence
        } else if recoveryConfirmation != nil {
            throw failure("服务端未创建确认需要匹配设备中的待恢复记录")
        }
        guard !cleanupOnly else { return recoveredEvidence + ["服务端清理确认完成"] }
        let course = try await operations.course()
        var journal = Journal(marker: "功能验收 " + marker, account: account)
        try journal.validate()
        journal.evidence.append("验收账号 user\(account)")
        var businessError: (any Error)?
        var operation = "创建内容"
        do {
            guard let followTarget = operations.followTarget(), followTarget > 0,
                  try await operations.following(followTarget) else { throw failure("关注探针需要已关注的验收目标") }
            journal.followTarget = followTarget; try persist(journal)
            operation = "取消关注"
            guard try await submitToggle("follow:user\(followTarget)", journal: &journal, operation: { try await operations.follow(followTarget) }) == false,
                  try await operations.following(followTarget) == false else { throw failure("验收取消关注结果异常") }
            operation = "恢复关注"
            guard try await submitToggle("follow:user\(followTarget)", journal: &journal, operation: { try await operations.follow(followTarget) }),
                  try await operations.following(followTarget) else { throw failure("验收关注恢复待完成") }
            journal.evidence.append("关注恢复 user\(followTarget)")
            journal.followTarget = nil; try persist(journal)
            for kind in [Kind.poster, .paper] {
                try Task.checkCancellation()
                operation = "创建 " + kind.rawValue
                var uploadedImage: String?
                let id: Int
                do {
                    id = try await operations.create(kind, journal.marker, { mid in
                        uploadedImage = mid
                        journal.evidence.append("共享验收图片 \(mid)"); try self.persist(journal)
                    }, {
                        var pending = journal
                        pending.attempts.append(kind)
                        try self.persist(pending)
                        journal = pending
                    })
                } catch {
                    if Self.creationWasRejected(error) {
                        journal.attempts.removeAll { $0 == kind }; try persist(journal)
                    }
                    throw error
                }
                guard id > 0 else { throw failure("验收内容标识无效") }
                let target = Target(kind: kind, id: id)
                journal.targets.append(target); journal.evidence.append("创建 \(kind.rawValue)\(id)")
                journal.attempts.removeAll { $0 == kind }
                try persist(journal)
                operation = "读取 " + kind.rawValue
                guard let created = try await operations.read(kind, id), created.owned,
                      created.text == journal.marker, created.anonymous == false,
                      created.publicAccess == false, fieldsMatch(created, kind: kind, text: journal.marker)
                else { throw failure("验收内容创建结果异常") }
                if kind == .poster {
                    guard !created.imageMids.isEmpty,
                          uploadedImage.map({ created.imageMids == [$0] }) ?? true else { throw failure("帖子图片引用验收待完成") }
                    journal.evidence.append("图片提交 poster\(id)")
                    try await operations.verifyImages(created.images)
                }
                let edited = journal.marker + " 编辑"
                operation = "编辑 " + kind.rawValue
                try await operations.edit(kind, id, edited)
                guard let updated = try await operations.read(kind, id), updated.text == edited, updated.owned,
                      updated.anonymous == false, updated.publicAccess == false,
                      fieldsMatch(updated, kind: kind, text: edited),
                      updated.imageMids == created.imageMids else { throw failure("验收编辑结果异常") }
            }
            operation = "选择课程"
            journal.targets.append(Target(kind: .course, id: course)); try persist(journal)
            for target in journal.targets {
                operation = "点赞 " + target.kind.rawValue
                try Task.checkCancellation()
                guard try await operations.account() == account else { throw failure("验收账号已切换") }
                guard let before = try await operations.read(target.kind, target.id) else { throw failure("验收目标缺失") }
                journal.likes.append(Like(target: target, original: before.liked)); try persist(journal)
                guard try await submitToggle("like:\(target.kind.rawValue)\(target.id)", journal: &journal, operation: { try await operations.like(target.kind, target.id) }) != before.liked,
                      try await operations.read(target.kind, target.id)?.liked == !before.liked else { throw failure("验收点赞结果异常") }
                guard try await submitToggle("like:\(target.kind.rawValue)\(target.id)", journal: &journal, operation: { try await operations.like(target.kind, target.id) }) == before.liked,
                      try await operations.read(target.kind, target.id)?.liked == before.liked else { throw failure("验收点赞恢复异常") }
                journal.evidence.append("点赞恢复 \(target.kind.rawValue)\(target.id)")
                let parent = target.kind.rawValue + String(target.id)
                journal.parents.append(parent); try persist(journal)
                operation = "评论 " + target.kind.rawValue
                let comment = try await createComment(.init(kind: target.kind, object: parent), journal: &journal, operations: operations)
                if target.kind == .poster {
                    guard !comment.images.isEmpty else { throw failure("评论图片引用验收待完成") }
                    journal.evidence.append("图片提交 comment\(comment.id)")
                    try await operations.verifyImages(comment.images)
                }
                let replies = "comment\(comment.id)"
                journal.parents.append(replies); try persist(journal)
                try await validateComment(comment, parent: parent, marker: journal.marker, account: account,
                    rate: target.kind == .course ? 6 : 0, operations: operations)
                guard try await operations.likeComment(target.kind, comment.id) != comment.like,
                      try await operations.comments(parent, [comment.id]).first(where: { $0.id == comment.id })?.like == !comment.like,
                      try await operations.likeComment(target.kind, comment.id) == comment.like,
                      try await operations.comments(parent, [comment.id]).first(where: { $0.id == comment.id })?.like == comment.like
                else { throw failure("评论点赞恢复验收待完成") }
                journal.evidence.append("评论点赞恢复 comment\(comment.id)")
                operation = "回复 " + target.kind.rawValue
                let reply = try await createComment(.init(kind: target.kind, object: replies), journal: &journal, operations: operations)
                try await validateComment(reply, parent: replies, marker: journal.marker, account: account, rate: 0, operations: operations)
                if target.kind == .poster { try await operations.verifyImages(reply.images) }
                operation = "定向回复 " + target.kind.rawValue
                let destination = CommentDestination(kind: target.kind, object: replies,
                    replyObjectID: "comment\(reply.id)", replyUID: reply.user.id)
                let directed = try await createComment(destination, journal: &journal, operations: operations)
                try await validateComment(directed, parent: replies, marker: journal.marker, account: account,
                    rate: 0, replyObjectID: destination.replyObjectID, replyUID: destination.replyUID, operations: operations)
                if target.kind == .poster { try await operations.verifyImages(directed.images) }
                journal.evidence.append("定向回复 \(target.kind.rawValue) 目标 comment\(reply.id)")
            }
        } catch { businessError = failure(operation + "：" + error.localizedDescription) }
        let snapshot = journal
        let cleaned = await Task { @MainActor [self] in
            var pending = snapshot
            do { try await cleanup(&pending, operations: operations, owner: owner); return Result<[String], any Error>.success(pending.evidence) }
            catch { return .failure(error) }
        }.value
        let evidence = try cleaned.get()
        if let businessError {
            let images = evidence.filter { $0.hasPrefix("共享验收图片 ") }.joined(separator: "；")
            throw failure("写入验收待完成，服务端清理已确认：" + businessError.localizedDescription + "；" + images)
        }
        return evidence
    }

    private func persist(_ journal: Journal) throws { try save(JSONEncoder().encode(journal)) }

    private func fieldsMatch(_ content: Content, kind: Kind, text: String) -> Bool {
        if kind == .poster { return content.title == "功能验收" && content.tags.isEmpty && content.claimID == 0 }
        return content.title == text && content.intro == text
    }

    private func validateComment(_ submitted: CommunityComment, parent: String, marker: String, account: Int,
        rate: Int, replyObjectID: String? = nil, replyUID: Int? = nil, operations: Operations) async throws {
        guard let readback = try await operations.comments(parent, [submitted.id]).first(where: { $0.id == submitted.id }) else {
            throw failure("验收评论读取结果缺失")
        }
        for value in [submitted, readback] {
            guard value.own, value.user.id == account, value.obj == parent, value.text == marker,
                  value.anonymous == false, value.rate == rate, value.replyObj == (replyObjectID ?? ""),
                  value.replyUser.id == (replyUID ?? 0),
                  value.images.map(\.mid) == submitted.images.map(\.mid) else { throw failure("验收评论与回复字段异常") }
        }
    }

    private static func creationWasRejected(_ error: any Error) -> Bool {
        if error is SubmissionNotSent { return true }
        switch error {
        case GalleryServiceError.notLoggedIn, PaperServiceError.notLoggedIn, CourseServiceError.notLoggedIn: return true
        default: break
        }
        let failure = error as NSError
        return ["BIT101.Gallery", "BIT101.Paper", "BIT101.Course"].contains(failure.domain) && (400..<500).contains(failure.code)
    }

    private func createComment(_ destination: CommentDestination, journal: inout Journal, operations: Operations) async throws -> CommunityComment {
        let parent = destination.object
        do {
            let comment = try await operations.comment(destination, journal.marker, { mid in
                journal.evidence.append("共享验收图片 \(mid)"); try self.persist(journal)
            }, {
                var pending = journal
                pending.commentAttempts.append(parent)
                try self.persist(pending)
                journal = pending
            })
            guard comment.id > 0, !journal.comments.contains(comment.id) else { throw failure("验收评论标识重复或无效") }
            journal.comments.append(comment.id); journal.evidence.append("创建 comment\(comment.id) 目标 \(parent)")
            journal.commentParents[comment.id] = parent
            journal.commentAttempts.removeAll { $0 == parent }
            try persist(journal)
            return comment
        } catch {
            if Self.creationWasRejected(error) {
                journal.commentAttempts.removeAll { $0 == parent }; try persist(journal)
            }
            throw error
        }
    }

    private func submitToggle(_ identifier: String, journal: inout Journal,
                              operation: () async throws -> Bool) async throws -> Bool {
        journal.markSubmission(identifier, pending: true); try persist(journal)
        do {
            let result = try await operation()
            journal.markSubmission(identifier, pending: false); try persist(journal)
            return result
        } catch {
            if Self.creationWasRejected(error) { journal.markSubmission(identifier, pending: false); try persist(journal) }
            throw error
        }
    }

    private func cleanup(_ journal: inout Journal, operations: Operations, owner: CommunitySessionIdentity,
                         confirmation: CommunityWriteRecoveryConfirmation? = nil) async throws {
        var failures: [String] = []
        if let target = journal.followTarget {
            if try await recoverOperation("恢复关注", failures: &failures, operation: {
                let identifier = "follow:user\(target)"
                guard !journal.followSubmissionPending || confirmation?.settledMutations?.contains(identifier) == true
                else { throw failure("关注切换结果待服务端确认") }
                journal.followSubmissionPending = false; try persist(journal)
                if try await operations.following(target) == false {
                    _ = try await submitToggle(identifier, journal: &journal) { try await operations.follow(target) }
                }
                guard try await operations.following(target) else { throw failure("验收关注恢复待完成") }
            }) {
                journal.followTarget = nil
            }
            try persist(journal)
        }
        for kind in Set(journal.attempts) {
            _ = try await recoverOperation("查找 " + kind.rawValue, failures: &failures, operation: {
                let identifiers = try await operations.find(kind, journal.marker)
                if identifiers.isEmpty {
                    guard let confirmation, confirmation.kinds.contains(kind.rawValue) else { throw failure("验收创建结果待服务端确认") }
                    journal.evidence.append("服务端确认未创建 \(kind.rawValue)：\(confirmation.serverReceipt)")
                }
                for id in identifiers {
                    let target = Target(kind: kind, id: id)
                    if !journal.targets.contains(target) { journal.targets.append(target) }
                }
                journal.attempts.removeAll { $0 == kind }
            })
        }
        try persist(journal)
        for like in journal.likes {
            if try await recoverOperation("恢复点赞 " + like.target.kind.rawValue, failures: &failures, operation: {
                guard like.submissionPending != true || confirmation?.settledMutations?.contains(like.recoveryID) == true
                else { throw failure("点赞切换结果待服务端确认") }
                journal.markSubmission(like.recoveryID, pending: false); try persist(journal)
                if let current = try await operations.read(like.target.kind, like.target.id) {
                    guard like.target.kind == .course || current.owned && matches(current.text, marker: journal.marker)
                    else { throw failure("验收点赞目标身份异常") }
                    if current.liked != like.original {
                        _ = try await submitToggle(like.recoveryID, journal: &journal) { try await operations.like(like.target.kind, like.target.id) }
                    }
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
            guard journal.commentAttempts.contains(parent) || journal.comments.contains(where: { journal.commentParents[$0] == nil }) else { continue }
            _ = try await recoverOperation("查找评论 " + parent, failures: &failures, operation: {
                var found = false
                for comment in try await operations.comments(parent, nil) where comment.own && comment.text == journal.marker {
                    if !journal.comments.contains(comment.id) || journal.commentParents[comment.id] == nil { found = true }
                    if !journal.comments.contains(comment.id) { journal.comments.append(comment.id) }
                    journal.commentParents[comment.id] = parent
                    if !parent.hasPrefix("comment") {
                        let replies = "comment\(comment.id)"
                        if !journal.parents.contains(replies) { journal.parents.append(replies) }
                    }
                }
                if found { journal.commentAttempts.removeAll { $0 == parent } }
                else if journal.commentAttempts.contains(parent), let confirmation, confirmation.parents.contains(parent) {
                    journal.commentAttempts.removeAll { $0 == parent }
                    journal.evidence.append("服务端确认未创建评论 \(parent)：\(confirmation.serverReceipt)")
                }
                guard !journal.commentAttempts.contains(parent) else { throw failure("验收评论创建结果待服务端确认") }
            })
        }
        journal.comments = journal.comments.reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
        try persist(journal)
        let commentIDs = journal.comments
        for id in journal.comments.reversed() {
            if try await recoverOperation("删除 comment\(id)", failures: &failures, operation: {
                let replies = "comment\(id)"
                if journal.parents.contains(replies) {
                    guard !journal.commentAttempts.contains(replies) else { throw failure("验收回复创建结果待服务端确认") }
                    guard try await operations.comments(replies, nil).allSatisfy({ !commentIDs.contains($0.id) && !($0.own && $0.text == journal.marker) })
                    else { throw failure("验收回复清理待完成") }
                    retireComments(replies, journal: &journal)
                    try persist(journal)
                }
                guard let parent = journal.commentParents[id] else { throw failure("验收评论缺少所属对象记录") }
                guard let current = try await operations.comments(parent, [id]).first(where: { $0.id == id }) else { return }
                guard current.own, current.user.id == journal.account, current.obj == parent, current.text == journal.marker
                else { throw failure("验收评论清理目标身份异常") }
                try await operations.deleteComment(id)
            }) {
                journal.evidence.append("删除 comment\(id)")
            }
            try persist(journal)
        }
        for parent in journal.parents {
            if try await recoverOperation("确认评论删除 " + parent, failures: &failures, operation: {
                guard !journal.commentAttempts.contains(parent) else { throw failure("验收评论创建结果待服务端确认") }
                guard try await operations.comments(parent, nil).allSatisfy({ !commentIDs.contains($0.id) && !($0.own && $0.text == journal.marker) })
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
                    guard current.owned, matches(current.text, marker: journal.marker) else { throw failure("验收清理目标身份异常") }
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
        if !journal.attempts.isEmpty || !journal.commentAttempts.isEmpty { failures.append("验收创建结果待服务端确认") }
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

    private func matches(_ text: String, marker: String) -> Bool {
        text == marker || text == marker + " 编辑"
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
