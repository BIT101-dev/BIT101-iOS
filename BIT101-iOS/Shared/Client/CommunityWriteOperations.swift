import ClientCore
import CommunityCore
import CommunityTransport
import CourseFeature
import Foundation
import GalleryFeature
import MineFeature
import PaperFeature
import StorageCore
import TransportCore
import UIKit

#if DEBUG || RELEASE_NETWORK_SMOKE

extension CommunityWriteSmoke {
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
        var comment:
            (CommentDestination, String, RecordImage, RecordSubmission) async throws ->
                CommunityComment
        var deleteComment: (Int) async throws -> Void
        var like: (Kind, Int) async throws -> Bool
        var likeComment: (Kind, Int) async throws -> Bool = { _, _ in
            throw URLError(.unsupportedURL)
        }
        var verifyImages: ([CommunityImage]) async throws -> Void = { _ in
            throw URLError(.unsupportedURL)
        }

        var followTarget: () -> Int? = { nil }
        var following: (Int) async throws -> Bool = { _ in throw URLError(.unsupportedURL) }
        var follow: (Int) async throws -> Bool = { _ in throw URLError(.unsupportedURL) }

        func scoped(to owner: CommunitySessionIdentity) -> Self {
            Self(
                identity: identity,
                account: { try await Self.checked(identity, owner) { try await account() } },
                course: { try await Self.checked(identity, owner) { try await course() } },
                create: { kind, text, record, submit in
                    try await Self.checked(identity, owner) {
                        try await create(
                            kind, text,
                            { mid in
                                guard identity() == owner else { throw CancellationError() }
                                try record(mid)
                            },
                            {
                                try Task.checkCancellation()
                                guard identity() == owner else { throw CancellationError() }
                                try submit()
                            })
                    }
                },
                find: { kind, text in
                    try await Self.checked(identity, owner) { try await find(kind, text) }
                },
                read: { kind, id in
                    try await Self.checked(identity, owner) { try await read(kind, id) }
                },
                edit: { kind, id, text in
                    try await Self.checked(identity, owner) { try await edit(kind, id, text) }
                },
                delete: { kind, id in
                    try await Self.checked(identity, owner) { try await delete(kind, id) }
                },
                comments: { object, identifiers in
                    try await Self.checked(identity, owner) {
                        try await comments(object, identifiers)
                    }
                },
                comment: { object, text, record, submit in
                    try await Self.checked(identity, owner) {
                        try await comment(
                            object, text,
                            { mid in
                                guard identity() == owner else { throw CancellationError() }
                                try record(mid)
                            },
                            {
                                try Task.checkCancellation()
                                guard identity() == owner else { throw CancellationError() }
                                try submit()
                            })
                    }
                },
                deleteComment: { id in
                    try await Self.checked(identity, owner) { try await deleteComment(id) }
                },
                like: { kind, id in
                    try await Self.checked(identity, owner) { try await like(kind, id) }
                },
                likeComment: { kind, id in
                    try await Self.checked(identity, owner) { try await likeComment(kind, id) }
                },
                verifyImages: { images in
                    try await Self.checked(identity, owner) { try await verifyImages(images) }
                }, followTarget: followTarget,
                following: { id in
                    try await Self.checked(identity, owner) { try await following(id) }
                },
                follow: { id in try await Self.checked(identity, owner) { try await follow(id) }
                })
        }

        private static func checked<Value>(
            _ identity: () -> CommunitySessionIdentity, _ owner: CommunitySessionIdentity,
            operation: () async throws -> Value
        ) async throws -> Value {
            guard identity() == owner else { throw CancellationError() }
            let result: Result<Value, any Error>
            do { result = .success(try await operation()) } catch { result = .failure(error) }
            if case .failure(let error) = result, error is SubmissionNotSent { throw error }
            guard identity() == owner else { throw CancellationError() }
            return try result.get()
        }

        static func submission<Value>(_ operation: () async throws -> Value) async throws
            -> Value
        {
            var started = false
            do {
                return try await HTTPRequestEvidenceContext.$willStart.withValue({
                    started = true
                }) {
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
            case .paper:
                if case PaperServiceError.missingPaper = error { return true }
                return false
            case .poster:
                if case GalleryServiceError.missingPoster = error { return true }
                return false
            case .course: return false
            }
        }

        static func production(
            papers: PaperService = PaperService(), courses: CourseService = CourseService(),
            gallery: GalleryService = GalleryService(),
            mine: MineService = ReleaseNetworkSmokeDependencies.mineService(),
            followTarget: Int? = nil, courseFixture: NetworkSmokeFixtures? = nil,
            verifyImages: @escaping ([CommunityImage]) async throws -> Void = { images in
                let urls = NetworkSmokePaging.imageURLs(in: images)
                guard !urls.isEmpty else { throw URLError(.cannotParseResponse) }
                for value in urls {
                    guard let url = URL(string: value) else { throw URLError(.badURL) }
                    _ = try await ReleaseNetworkSmokeDependencies.probeRemoteImage(at: url)
                }
            }
        ) -> Self {
            return Self(
                identity: { AppAccountSession.storage.communityCredentials.identity },
                account: { try await mine.fetchMyInfo().user.id },
                course: {
                    guard let fixture = courseFixture, fixture.isValid else {
                        throw URLError(.badURL)
                    }
                    let course = try await courses.fetchCourse(id: fixture.courseID)
                    guard course.id == fixture.courseID, course.number == fixture.courseNumber
                    else { throw URLError(.cannotParseResponse) }
                    return course.id
                },
                create: { kind, text, record, submit in
                    switch kind {
                    case .poster:
                        let image = try await gallery.uploadImage(
                            data: CommunityWriteMedia.jpeg(), filename: "smoke.jpg")
                        guard !image.mid.isEmpty else { throw URLError(.cannotParseResponse) }
                        try record(image.mid)
                        return try await Self.submission {
                            try submit()
                            return try await gallery.createPoster(
                                title: "功能验收", text: text,
                                imageMids: [image.mid], anonymous: false, tags: [], claimID: 0,
                                isPublic: false)
                        }
                    case .paper:
                        return try await Self.submission {
                            try submit()
                            return try await papers.createPaper(
                                title: text, intro: text,
                                content: PaperEditorContentBuilder.editorJSON(from: text),
                                anonymous: false, publicEdit: false)
                        }
                    case .course: throw URLError(.unsupportedURL)
                    }
                },
                find: { kind, text in
                    var result: Set<Int> = []
                    var scanned: Set<Int> = []
                    var progress = CommunityPageProgress<Int>()
                    var page = 0
                    while true {
                        try NetworkSmokePaging.checkSampleBudget(
                            page: page, items: scanned.count)
                        if kind == .poster {
                            let rows = try await mine.fetchMyPosters(page: page)
                            if rows.isEmpty { return result.sorted() }
                            scanned.formUnion(rows.map(\.id))
                            try NetworkSmokePaging.checkSampleBudget(
                                page: page, items: scanned.count)
                            try progress.record(rows.map(\.id))
                            result.formUnion(rows.filter { $0.text.contains(text) }.map(\.id))
                        } else {
                            let rows = try await papers.fetchPapers(
                                search: text, order: .newest, page: page)
                            if rows.isEmpty { return result.sorted() }
                            scanned.formUnion(rows.map(\.id))
                            try NetworkSmokePaging.checkSampleBudget(
                                page: page, items: scanned.count)
                            try progress.record(rows.map(\.id))
                            let matchingIDs = try await CommunityWriteSmoke.matchingPaperIDs(
                                in: rows, text: text, papers: papers
                            )
                            result.formUnion(matchingIDs)
                        }
                        page += 1
                    }
                },
                read: { kind, id in
                    do {
                        switch kind {
                        case .poster:
                            let value = try await gallery.fetchPoster(id: id)
                            return Content(
                                text: value.text, owned: value.own, liked: value.like,
                                imageMids: value.images.map(\.mid),
                                anonymous: value.anonymous, publicAccess: value.public,
                                title: value.title,
                                tags: value.tags, claimID: value.claim.id, images: value.images)
                        case .paper:
                            let value = try await papers.fetchPaper(id: id)
                            return Content(
                                text: PaperEditorContentBuilder.plainText(from: value.content),
                                owned: value.own, liked: value.like,
                                anonymous: value.anonymous, publicAccess: value.publicEdit,
                                title: value.title, intro: value.intro)
                        case .course:
                            let value = try await courses.fetchCourse(id: id)
                            return Content(text: "", owned: false, liked: value.like)
                        }
                    } catch let error where Self.isMissingContent(error, kind: kind) {
                        return nil
                    }
                },
                edit: { kind, id, text in
                    switch kind {
                    case .poster:
                        let current = try await gallery.fetchPoster(id: id)
                        guard !current.images.isEmpty else {
                            throw URLError(.cannotParseResponse)
                        }
                        try await gallery.updatePoster(
                            id: id, title: "功能验收", text: text,
                            imageMids: current.images.map(\.mid), plugins: "[]",
                            anonymous: false, tags: [], claimID: 0, isPublic: false)
                        for level in [
                            GallerySubscriptionLevel.silent, .update, .comment, .none,
                        ] {
                            try await gallery.setSubscription(
                                objectID: "poster\(id)", level: level)
                            guard try await gallery.fetchPoster(id: id).subscription == level
                            else {
                                throw URLError(.cannotParseResponse)
                            }
                        }
                    case .paper:
                        let current = try await papers.fetchPaper(id: id)
                        try await papers.updatePaper(
                            id: id, title: text, intro: text,
                            content: PaperEditorContentBuilder.editorJSON(from: text),
                            anonymous: false, publicEdit: false,
                            lastUpdatedAt: current.updateTime)
                    case .course: throw URLError(.unsupportedURL)
                    }
                },
                delete: { kind, id in
                    if kind == .poster {
                        let detail = try await gallery.fetchPoster(id: id)
                        if (detail.subscription?.rawValue ?? 0) > 0 {
                            try await gallery.setSubscription(
                                objectID: "poster\(id)", level: .none)
                        }
                        try await gallery.deletePoster(id: id)
                    } else {
                        try await papers.deletePaper(id: id)
                    }
                },
                comments: { object, identifiers in
                    if identifiers?.isEmpty == true { return [] }
                    var result: [Int: CommunityComment] = [:]
                    var progress = CommunityPageProgress<Int>()
                    var page = 0
                    while true {
                        try NetworkSmokePaging.checkSampleBudget(
                            page: page, items: result.count)
                        let rows = try await gallery.fetchRawComments(
                            objectID: object,
                            order: identifiers == nil ? .oldest : .newest, page: page)
                        if rows.isEmpty { return result.values.sorted { $0.id < $1.id } }
                        try progress.record(rows.map(\.id))
                        for row in rows { result[row.id] = row }
                        try NetworkSmokePaging.checkSampleBudget(
                            page: page, items: result.count)
                        if let identifiers, identifiers.isSubset(of: Set(result.keys)) {
                            return result.values.filter { identifiers.contains($0.id) }
                        }
                        page += 1
                    }
                },
                comment: { destination, text, record, submit in
                    let object = destination.object
                    let value: CommunityComment
                    if destination.kind == .course {
                        value = try await Self.submission {
                            try submit()
                            return try await courses.createComment(
                                objectID: object, text: text,
                                replyObjectID: destination.replyObjectID,
                                replyUID: destination.replyUID,
                                rate: object.hasPrefix("course") ? 6 : nil)
                        }
                    } else if destination.kind == .paper {
                        value = try await Self.submission {
                            try submit()
                            return try await papers.createComment(
                                objectID: object, text: text,
                                replyObjectID: destination.replyObjectID,
                                replyUID: destination.replyUID)
                        }
                    } else {
                        let image = try await gallery.uploadCommentImage(
                            data: CommunityWriteMedia.jpeg(), filename: "smoke.jpg")
                        guard !image.mid.isEmpty else { throw URLError(.cannotParseResponse) }
                        try record(image.mid)
                        value = try await Self.submission {
                            try submit()
                            return try await gallery.createComment(
                                objectID: object, text: text,
                                replyObjectID: destination.replyObjectID,
                                replyUID: destination.replyUID, imageMids: [image.mid])
                        }
                        guard !image.mid.isEmpty, value.images.map(\.mid) == [image.mid] else {
                            throw URLError(.cannotParseResponse)
                        }
                    }
                    try await Task.sleep(for: .seconds(1))
                    return value
                }, deleteComment: { try await gallery.deleteComment(id: $0) },
                like: { kind, id in
                    let value: Bool
                    switch kind {
                    case .poster: value = try await gallery.like(objectID: "poster\(id)").like
                    case .paper: value = try await papers.likePaper(id: id).like
                    case .course: value = try await courses.like(objectID: "course\(id)").like
                    }
                    try await Task.sleep(for: .seconds(1))
                    return value
                },
                likeComment: { kind, id in
                    let result: CommunityLikeResult
                    if kind == .course {
                        result = try await courses.like(objectID: "comment\(id)")
                    } else {
                        result = try await gallery.like(objectID: "comment\(id)")
                    }
                    try await Task.sleep(for: .seconds(1))
                    return result.like
                }, verifyImages: verifyImages, followTarget: { followTarget },
                following: { id in
                    let info = try await mine.fetchUserInfo(id: id)
                    guard !info.own, info.user.id == id else {
                        throw URLError(.cannotParseResponse)
                    }
                    let identity = AppAccountSession.storage.communityCredentials.identity
                    let posts = try await NetworkSmokePaging.arrayPage(
                        currentIdentity: {
                            AppAccountSession.storage.communityCredentials.identity
                        }, load: { try await mine.fetchUserPosters(userID: id, page: $0) })
                    guard identity == AppAccountSession.storage.communityCredentials.identity,
                        posts.allSatisfy({ $0.user.id == id })
                    else { throw URLError(.cannotParseResponse) }
                    return info.following
                }, follow: { try await mine.followUser(id: $0).following })
        }
    }
}

#endif
