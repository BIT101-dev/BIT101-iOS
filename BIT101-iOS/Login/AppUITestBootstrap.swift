#if BIT101_UI_TESTING
import StorageCore
import TransportCore
import Foundation
import Network
import UIKit
import PhotosUI
import QuickLook
import ClientCore
import ScheduleDomain
import SchedulePorts
import CommunityCore
import CommunityPersistence
import DesignSystemKit
import SwiftUI

/// UI 自动化在本机连接中更新场景夹具，App 进程持续运行。
nonisolated final class UITestControlServer: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "BIT101.UITestControl")

    init(handle: @escaping @Sendable (Data, @escaping @Sendable (Data) -> Void) -> Void) throws {
        let parameters = NWParameters.tcp
        guard let rawPort = ProcessInfo.processInfo.environment["BIT101_UI_TEST_CONTROL_PORT"].flatMap(UInt16.init),
              let port = NWEndpoint.Port(rawValue: rawPort) else { throw URLError(.badURL) }
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            Self.receive(connection, buffer: Data(), handle: handle)
        }
        listener.start(queue: queue)
    }

    deinit { listener.cancel() }

    private static func receive(
        _ connection: NWConnection, buffer: Data,
        handle: @escaping @Sendable (Data, @escaping @Sendable (Data) -> Void) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, complete, error in
            var content = buffer
            if let data { content.append(data) }
            if let end = content.firstIndex(of: 10) {
                handle(Data(content[..<end])) { response in
                    connection.send(content: response + Data([10]), completion: .contentProcessed { _ in connection.cancel() })
                }
            } else if error != nil || complete || content.count > 16_384 {
                connection.cancel()
            } else {
                receive(connection, buffer: content, handle: handle)
            }
        }
    }
}

/// 场景参数在同一个进程中更新，传输夹具与页面共同读取这份配置。
@MainActor
final class UITestSceneConfiguration {
    static let shared = UITestSceneConfiguration()
    private var values = ProcessInfo.processInfo.environment
    private var revision = 0

    var snapshot: (environment: [String: String], revision: Int) {
        return (values, revision)
    }

    func replace(with environment: [String: String]) {
        AppUITestBootstrap.releaseRequests()
        AppUITestBootstrap.failingRequests.removeAll()
        values = environment
        revision += 1
    }
}


enum AppUITestBootstrap {
    nonisolated static let usesProductionComposition = ProcessInfo.processInfo.environment["BIT101_UI_TEST_PRODUCTION_COMPOSITION"] == "1"
    static var environment: [String: String] { UITestSceneConfiguration.shared.snapshot.environment }
    private static var injectedScheduleConflictScene: Int?
    static var pendingRequests: [String: [CheckedContinuation<Void, Never>]] = [:]
    static var failingRequests: [String: [String: String]] = [:]
    static var holdingRequests: [String: [String: String]] = [:]
    static var recoveredSuggestionID: UUID?

    static func holdRequest(_ key: String) async {
        await withCheckedContinuation { pendingRequests[key, default: []].append($0) }
    }

    static func takeRequest(_ path: String, query: [URLQueryItem], from requests: inout [String: [String: String]]) -> Bool {
        guard let conditions = requests[path], conditions.allSatisfy({ name, value in
            query.contains(where: { $0.name == name && $0.value == value })
        }) else { return false }
        requests[path] = nil
        return true
    }

    static func releaseRequest(_ key: String) {
        holdingRequests.removeValue(forKey: key)
        pendingRequests.removeValue(forKey: key)?.forEach { $0.resume() }
    }

    static func releaseRequests() {
        holdingRequests.removeAll()
        let requests = pendingRequests.values.flatMap { $0 }
        pendingRequests.removeAll()
        requests.forEach { $0.resume() }
    }

    static func prepareScheduleConflictIfRequested(cache: ScheduleCache, session: AppStorageSession) async throws {
        let scene = UITestSceneConfiguration.shared.snapshot
        guard scene.environment["BIT101_UI_TEST_SCHEDULE_CONFLICT"] == "1",
              cache.primaryScheduleTitle == "本机标题", injectedScheduleConflictScene != scene.revision else { return }
        injectedScheduleConflictScene = scene.revision
        var remote = await ScheduleCacheStore.loadResultAsync(for: session).cacheIfReadable ?? ScheduleCache()
        remote.primaryScheduleTitle = "同步标题"
        remote.cloudSyncBaselineRecordTag = "ui-test-cloud-version"
        remote.syncData.cloudSyncBaselineUserState = try ScheduleCloudStateMerge.baseline(for: remote)
        guard await ScheduleCacheStore.saveAndWait(remote, source: .cloud,
            expectedAccountIdentifier: session.accountDirectoryName) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func prepareSessionIfNeeded() async {
        let environment = Self.environment
        defer {
            if environment["BIT101_UI_TEST_SCORE_RECOVERY"] == "1" {
                AppFileDirectories.defaults.set(Data("damaged-ui-score-filters".utf8),
                    forKey: AppFileDirectories.currentSession.key("score.filter.preferences"))
            }
            if environment["BIT101_UI_TEST_SETTINGS_RECOVERY"] == "1" {
                let key = AppFileDirectories.currentSession.key(AppSettingsStore.storageKeyPrefix,
                    guestIdentifier: AppSettingsStore.defaultAccountIdentifier)
                AppFileDirectories.defaults.set(Data("damaged-ui-settings".utf8), forKey: key)
                AppSettingsStore.shared.reloadForCurrentAccount()
            }
        }
        guard environment["BIT101_UI_TEST_RESET_STORAGE"] == "1",
              let account = environment["BIT101_UI_TEST_ACCOUNT"], !account.isEmpty else { return }
        do {
            _ = try await UITestLoginService().login(studentID: account, password: "ui-test-password")
            recoveredSuggestionID = nil
            if environment["BIT101_UI_TEST_MESSAGE_STORAGE_RECOVERY"] == "1" {
                try prepareDamagedAccountFile("message-read-snapshot.json")
                AppAccountStores.shared.communityMessages.invalidateSnapshot()
            }
            if environment["BIT101_UI_TEST_SCHEDULE_ROOT_DAMAGE"] == "1" {
                try prepareDamagedAccountFile("schedule-cache.json")
            }
            if environment["BIT101_UI_TEST_PAPER_DRAFT_RECOVERY"] == "1" {
                try prepareDamagedAccountFile("composer-paper.json")
            }
            if environment["BIT101_UI_TEST_SUGGESTION_RECOVERY"] == "1" {
                try await prepareRecoveredSuggestion()
            }
            if environment["BIT101_UI_TEST_BOT_PAGING"] == "1" {
                AppSettingsStore.shared.updateGallerySettings(hideBotPosterInSearch: false)
            }
            if environment["BIT101_UI_TEST_SCHEDULE_RECOVERY"] == "1" {
                var cache = ScheduleCache()
                cache.primaryScheduleTitle = "恢复课表"
                guard var root = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cache)) as? [String: Any],
                      var course = root["courseData"] as? [String: Any] else { throw CocoaError(.coderInvalidValue) }
                course["customSchedules"] = [7]
                root["courseData"] = course
                let url = AppFileDirectories.accountSupportFileURL(
                    accountDirectoryName: AppFileDirectories.currentSession.accountStorageIdentifier, named: "schedule-cache.json")
                try AppFileDirectories.files.createDirectory(at: url.deletingLastPathComponent())
                try AppFileDirectories.files.writeData(JSONSerialization.data(withJSONObject: root), to: url, options: .atomic)
            }
            if environment["BIT101_UI_TEST_MEDIA"] == "1" {
                let image = ComposerImageDraftSnapshot(filename: "ui-image.png", previewData: mediaData, uploadData: mediaData)
                let drafts = AppAccountStores.shared.composerDrafts
                guard await drafts.saveGallery(GalleryComposerDraftSnapshot(title: "图片测试草稿", text: "图片草稿正文",
                    selectedTags: [], customTags: [], anonymous: false, isPublic: true, selectedClaimID: 0, images: [image])),
                      await drafts.saveSuggestion(DeveloperSuggestionDraftSnapshot(text: "图片建议草稿", images: [image], contact: "测试联系信息")) else {
                    throw URLError(.cannotWriteToFile)
                }
            }
        } catch {
            preconditionFailure("UI test session preparation failed: \(error)")
        }
    }

    private static func prepareDamagedAccountFile(_ name: String) throws {
        let url = AppFileDirectories.accountSupportFileURL(
            accountDirectoryName: AppFileDirectories.currentSession.accountStorageIdentifier, named: name)
        try AppFileDirectories.files.createDirectory(at: url.deletingLastPathComponent())
        try AppFileDirectories.files.writeData(Data("{damaged".utf8), to: url, options: .atomic)
    }

    static func prepareForLaunch() {
        let environment = Self.environment
        guard AppFileDirectories.isRunningUITest else {
            preconditionFailure("The UI automation App requires its isolated launch configuration")
        }
        UIView.setAnimationsEnabled(environment["BIT101_UI_TEST_ANIMATIONS"] == "1")
        UIApplication.shared.isIdleTimerDisabled = true
        guard environment["BIT101_UI_TEST_RESET_STORAGE"] == "1" else { return }

        AppFileDirectories.defaults.removePersistentDomain(
            forName: AppFileDirectories.uiTestDefaultsSuiteName
        )
        if environment["BIT101_UI_TEST_UPDATE"] != nil {
            AppFileDirectories.defaults.set(false, forKey: AppSettingsStore.automaticUpdateChecksEnabledKey)
        }
        AppAccountSession.resetUITestCredentials()

        let supportDirectory = AppFileDirectories.applicationSupportDirectoryURL(named: "BIT101-iOS")
        guard AppFileDirectories.files.fileExists(at: supportDirectory) else { return }
        do {
            try AppFileDirectories.files.removeItem(at: supportDirectory)
        } catch {
            preconditionFailure("UI test account storage cleanup failed: \(error)")
        }
    }
}

extension AppUITestBootstrap {
    private static func prepareRecoveredSuggestion() async throws {
        let images = ["ui-image.png", "missing-image.png"].map {
            ComposerImageDraftSnapshot(filename: $0, previewData: mediaData, uploadData: mediaData)
        }
        let draft = DeveloperSuggestionDraftSnapshot(text: "恢复建议草稿", images: images, contact: "测试联系信息")
        let context = FeedbackDeviceContext.current
        let payload = DeveloperSuggestionPayload(comment: draft.text, contact: draft.contact, appVersion: "test", build: "test",
            systemVersion: "test", deviceModel: "test", networkStatus: context.networkStatus, submittedAt: Date(), context: context,
            attachments: images.map { .init(filename: $0.filename, contentType: "image/jpeg", data: mediaData.base64EncodedString()) })
        recoveredSuggestionID = payload.requestID
        let saved = DeveloperSuggestionDraftSnapshot(text: draft.text, images: images, contact: draft.contact,
            pendingSubmissionMetadata: try payload.draftMetadata(matching: draft))
        guard await AppAccountStores.shared.composerDrafts.saveSuggestion(saved) else { throw URLError(.cannotWriteToFile) }
        let url = AppFileDirectories.accountSupportFileURL(
            accountDirectoryName: AppFileDirectories.currentSession.accountStorageIdentifier, named: "composer-suggestion.json")
        let data = try AppFileDirectories.files.readData(at: url)
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let revision = body["assetRevision"] as? String else { throw CocoaError(.coderInvalidValue) }
        try AppFileDirectories.files.removeItem(at: url.appendingPathExtension("assets").appending(path: revision).appending(path: "image-1.jpg"))
    }

    static var mediaData: Data {
        UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80)).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }
    }
}

extension View {
    /// 外部链接的 UI 场景读取页面实际发出的地址。
    func uiTestExternalURLs() -> some View {
        environment(\.openURL, OpenURLAction { url in
            UITestAccessibilityActions.openedExternalURL = url.absoluteString
            return .handled
        })
    }
}

/// 固定响应通过生产 Service 解码，交互修改保留到当前测试场景结束。
final class UITestHTTPTransport: HTTPTransport {
    private var fixtureRevision = -1
    private var likedObjects: Set<String> = []
    private var subscriptions: [String: Int] = [:]
    private var comments: [[String: Any]] = []
    private var createdPosters: [[String: Any]] = []
    private var createdPapers: [[String: Any]] = []
    private var deletedPosterIDs: Set<Int> = []
    private var deletedPaperIDs: Set<Int> = []
    private var deletedCommentIDs: Set<Int> = []
    private var profileChanges: [String: Any] = [:]
    private var posterChanges: [String: Any] = [:]
    private var following = false
    private var imageUploads = 0
    private var failedPaths: Set<String> = []
    private var clearedMessageTypes: Set<String> = []
    private var feedbackRetryPayload: Data?
    private let timestamp = "2026-10-01T10:00:00Z"

    func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
        let result = try await data(for: request)
        if let maximumBytes, result.0.count > maximumBytes { throw HTTPClientError.responseTooLarge }
        return result
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let snapshot = UITestSceneConfiguration.shared.snapshot
        if fixtureRevision != snapshot.revision {
            fixtureRevision = snapshot.revision
            likedObjects = []
            subscriptions = AppUITestBootstrap.environment["BIT101_UI_TEST_RESOURCE_ROUTES"] == "1" ? ["course1": 1] : [:]
            comments = []
            createdPosters = []
            createdPapers = []
            deletedPosterIDs = []
            deletedPaperIDs = []
            deletedCommentIDs = []
            profileChanges = [:]
            posterChanges = [:]
            following = false
            imageUploads = 0
            failedPaths = []
            clearedMessageTypes = []
            feedbackRetryPayload = nil
        }
        guard let url = request.url else { throw URLError(.badURL) }
        if url.host == "feedback.aihelpme.dev", AppUITestBootstrap.environment["BIT101_UI_TEST_CONTENT"] == "1" {
            guard let data = request.httpBody,
                  let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = body["requestID"] as? String, UUID(uuidString: id) != nil else {
                throw URLError(.badServerResponse)
            }
            let payload = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            if AppUITestBootstrap.environment["BIT101_UI_TEST_SUGGESTION_RECOVERY"] == "1" {
                guard id != AppUITestBootstrap.recoveredSuggestionID?.uuidString,
                      body["comment"] as? String == "恢复建议草稿",
                      body["contact"] as? String == "测试联系信息",
                      (body["attachments"] as? [[String: Any]])?.count == 1 else { throw URLError(.badServerResponse) }
            }
            if AppUITestBootstrap.environment["BIT101_UI_TEST_FEEDBACK_HOLD"] == "1" {
                await AppUITestBootstrap.holdRequest("feedback")
            }
            if AppUITestBootstrap.environment["BIT101_UI_TEST_FEEDBACK_RESPONSE_LOST_ONCE"] == "1",
               failedPaths.insert("feedback").inserted {
                feedbackRetryPayload = payload
                throw URLError(.networkConnectionLost)
            }
            if let accepted = feedbackRetryPayload {
                guard payload == accepted else { throw URLError(.badServerResponse) }
                feedbackRetryPayload = nil
            }
            return try jsonResponse(["id": id], url: url, statusCode: 201)
        }
        if url.host == "itunes.apple.com", let fixture = AppUITestBootstrap.environment["BIT101_UI_TEST_UPDATE"] {
            return try jsonResponse(["resultCount": 1, "results": [["version": fixture == "current" ? "0.0" : "999.0",
                "releaseNotes": "自动化测试更新", "bundleId": "BIT101-dev.BIT101-iOS",
                "currentVersionReleaseDate": timestamp,
                "trackViewUrl": BIT101AppStore.url.absoluteString]]], url: url)
        }
        guard AppUITestBootstrap.environment["BIT101_UI_TEST_CONTENT"] == "1",
              url.host == "bit101.flwfdd.xyz" else {
            throw URLError(.notConnectedToInternet)
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if AppUITestBootstrap.takeRequest(path, query: query, from: &AppUITestBootstrap.failingRequests) { throw URLError(.networkConnectionLost) }
        if AppUITestBootstrap.takeRequest(path, query: query, from: &AppUITestBootstrap.holdingRequests) { await AppUITestBootstrap.holdRequest(path) }
        if AppUITestBootstrap.environment["BIT101_UI_TEST_REPORT_FAILURE_ONCE"] == "1",
           path == "manage/report_types", failedPaths.insert(path).inserted {
            throw URLError(.networkConnectionLost)
        }
        if AppUITestBootstrap.environment["BIT101_UI_TEST_FAILURE_ONCE"] == "1",
           ["posters", "papers", "courses"].contains(path), failedPaths.insert(path).inserted {
            throw URLError(.networkConnectionLost)
        }
        if AppUITestBootstrap.environment["BIT101_UI_TEST_CLAIMS_FAILURE_ONCE"] == "1",
           path == "posters/claims", failedPaths.insert(path).inserted {
            throw URLError(.networkConnectionLost)
        }
        if path.hasPrefix("ui-images/") {
            if AppUITestBootstrap.environment["BIT101_UI_TEST_MEDIA_RECOVERY"] == "1",
               path == "ui-images/preview-missing.png" ||
                (path == "ui-images/preview-recovery.png" && failedPaths.insert(path).inserted) {
                throw URLError(.notConnectedToInternet)
            }
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"]) else {
                throw URLError(.badServerResponse)
            }
            return (AppUITestBootstrap.mediaData, response)
        }
        let requestedPage = query.first(where: { $0.name == "page" })?.value ?? "0"
        let repeatedPages = AppUITestBootstrap.environment["BIT101_UI_TEST_DUPLICATE_PAGES"] == "1"
        let page = repeatedPages ? String(max(0, (Int(requestedPage) ?? 0) - 1)) : requestedPage
        if repeatedPages, requestedPage == "2" { try await Task.sleep(for: .milliseconds(100)) }
        let userID = query.first { $0.name == "uid" }?.value
        if AppUITestBootstrap.environment["BIT101_UI_TEST_MINE_PAGING_FAILURE_ONCE"] == "1", page == "1",
           ["user/followers", "user/followings"].contains(path) || (path == "posters" && userID != nil),
           failedPaths.insert("mine-page-" + path + (userID ?? "")).inserted {
            throw URLError(.networkConnectionLost)
        }
        let body = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
        let method = request.httpMethod ?? "GET"
        if AppUITestBootstrap.environment["BIT101_UI_TEST_PAGINATION_FAILURE_ONCE"] == "1", page == "1",
           method == "GET", ["posters", "papers", "courses"].contains(path),
           failedPaths.insert("page-" + path + (query.first { $0.name == "order" }?.value ?? "")).inserted {
            throw URLError(.networkConnectionLost)
        }
        if AppUITestBootstrap.environment["BIT101_UI_TEST_COURSE_LOOKUP_FAILURE_ONCE"] == "1", path == "courses",
           let search = query.first(where: { $0.name == "search" })?.value, !search.isEmpty,
           failedPaths.insert("lookup-" + search).inserted {
            throw URLError(.networkConnectionLost)
        }
        let payload: Any
        switch path {
        case "user/check": payload = [:] as [String: String]
        case "user/login": payload = ["fake_cookie": "ui-test-cookie"]
        case "posters/claims": payload = [["id": 1, "text": "日常"]]
        case "manage/report_types": payload = [["id": 1, "text": "其他"]]
        case "manage/reports": payload = [:] as [String: String]
        case "subscriptions":
            if method == "POST" {
                guard let object = body["obj"] as? String, let level = body["level"] as? Int,
                    (0...3).contains(level) else { throw URLError(.badURL) }
                subscriptions[object] = level
                payload = [:] as [String: String]
            } else {
                if failedPaths.insert(path).inserted { throw URLError(.networkConnectionLost) }
                payload = page == "0" ? subscriptions.sorted { $0.key < $1.key }.filter { $0.value > 0 }.enumerated().map { index, item in
                    ["id": index + 1, "subscription_time": timestamp, "obj": item.key, "level": item.value,
                        "text": item.key == "course1" ? "收藏课程" : "自动化测试话题"] as [String: Any]
                } : []
            }
        case "upload/image":
            imageUploads += 1
            if imageUploads == 1 { throw URLError(.networkConnectionLost) }
            payload = mediaImage
        case "messages/unread_nums": payload = Dictionary(uniqueKeysWithValues:
            ["comment", "follow", "like", "subscription", "system"].map { ($0, clearedMessageTypes.contains($0) ? 0 : 1) })
        case "messages":
            let cursor = query.first(where: { $0.name == "last_id" })?.value.flatMap(Int.init)
            if AppUITestBootstrap.environment["BIT101_UI_TEST_MESSAGE_PAGING_FAILURE_ONCE"] == "1", cursor == 3,
               failedPaths.insert("message-page").inserted { throw URLError(.networkConnectionLost) }
            if cursor == nil || cursor == 0 { clearedMessageTypes.insert(query.first(where: { $0.name == "type" })?.value ?? "comment") }
            let resources = AppUITestBootstrap.environment["BIT101_UI_TEST_MESSAGE_PAGING_FAILURE_ONCE"] == "1"
                ? [(3, "poster1", "分页首屏消息"), (2, "poster1", "重试后的消息")]
                : AppUITestBootstrap.environment["BIT101_UI_TEST_RESOURCE_ROUTES"] == "1"
                ? [(2, "course1", "课程更新"), (1, "paper1", "文章更新")] : [(1, "poster1", "自动化测试消息")]
            let pageSize = AppUITestBootstrap.environment["BIT101_UI_TEST_MESSAGE_PAGING_FAILURE_ONCE"] == "1" ? 1 : resources.count
            payload = resources.filter { cursor == nil || cursor == 0 || $0.0 < (cursor ?? 0) }.prefix(pageSize).map { id, object, text in
                ["id": id, "from_user": user, "link_obj": object, "obj": object,
                    "text": text, "update_time": timestamp] as [String: Any]
            }
        case "reaction/like":
            let object = body["obj"] as? String ?? "poster1"
            if likedObjects.contains(object) { likedObjects.remove(object) } else { likedObjects.insert(object) }
            payload = ["like": likedObjects.contains(object), "like_num": likedObjects.contains(object) ? 2 : 1]
        case "reaction/comments":
            if method == "GET", query.first(where: { $0.name == "obj" })?.value == "course1",
               AppUITestBootstrap.environment["BIT101_UI_TEST_COURSE_COMMENT_RECOVERY"] == "1",
               failedPaths.insert("course-comments").inserted {
                await AppUITestBootstrap.holdRequest("course-comments")
                throw URLError(.networkConnectionLost)
            }
            if method == "POST" {
                var comment = makeComment(id: comments.count + 2, text: body["text"] as? String ?? "测试回复")
                comment["reply_obj"] = body["reply_obj"] ?? ""
                comment["obj"] = body["obj"] ?? "poster1"
                if AppUITestBootstrap.environment["BIT101_UI_TEST_COMMENT_OUTCOME_UNKNOWN_ONCE"] == "1",
                   failedPaths.insert("comment-outcome").inserted { comment["id"] = 0 }
                else { comments.append(comment) }
                payload = comment
            } else {
                payload = page == "0" ? ([makeComment(id: 1, text: "自动化测试评论")] + comments)
                    .filter { !deletedCommentIDs.contains($0["id"] as? Int ?? 0) }
                    .map { value in
                        var value = value
                        value["obj"] = query.first { $0.name == "obj" }?.value ?? "poster1"
                        return value
                    } : []
            }
        case "posters":
            if method == "POST" {
                var poster = self.poster
                let id = createdPosters.count + 10
                poster["id"] = id
                poster["title"] = body["title"]
                poster["text"] = body["text"]
                poster["tags"] = body["tags"]
                poster["anonymous"] = body["anonymous"]
                poster["public"] = body["public"]
                createdPosters.append(poster)
                payload = ["id": id]
            } else {
                if AppUITestBootstrap.environment["BIT101_UI_TEST_BOT_PAGING"] == "1",
                   query.contains(where: { $0.name == "mode" && $0.value == "search" }),
                   query.contains(where: { $0.name == "order" && $0.value == "new" }) {
                    try await Task.sleep(for: .milliseconds(100))
                    let sourcePage = Int(page) ?? 0
                    var item = poster
                    item["id"] = sourcePage + 100
                    item["tags"] = sourcePage == 10 ? ["bot"] : ["测试"]
                    item["title"] = sourcePage == 10 ? "机器人分页话题" : "普通分页话题"
                    payload = sourcePage <= 10 ? [item] : []
                } else if AppUITestBootstrap.environment["BIT101_UI_TEST_PAGINATION"] == "1" {
                    payload = paginationItems(poster, page: page, key: "title", title: "分页话题")
                } else {
                    payload = page == "0" ? ([poster] + createdPosters).filter { !deletedPosterIDs.contains($0["id"] as? Int ?? 0) } : []
                }
            }
        case "papers":
            if method == "POST" {
                var paper = self.paper
                let id = createdPapers.count + 10
                paper["id"] = id
                paper["title"] = body["title"]
                paper["intro"] = body["intro"]
                paper["content"] = body["content"]
                createdPapers.append(paper)
                payload = ["id": id]
            } else if AppUITestBootstrap.environment["BIT101_UI_TEST_PAGINATION"] == "1" {
                payload = paginationItems(paper, page: page, key: "title", title: "分页文章")
            } else {
                payload = page == "0" ? ([paper] + createdPapers).filter { !deletedPaperIDs.contains($0["id"] as? Int ?? 0) } : []
            }
        case "courses":
            var schoolCourse = course
            schoolCourse["id"] = 2
            schoolCourse["name"] = "学校测试课程"
            schoolCourse["number"] = "UI-002"
            if AppUITestBootstrap.environment["BIT101_UI_TEST_PAGINATION"] == "1" {
                payload = paginationItems(course, page: page, key: "name", title: "分页课程")
            } else {
                payload = page == "0" ? (AppUITestBootstrap.environment["BIT101_UI_TEST_SCHOOL"] == "1" ? [course, schoolCourse] : [course]) : []
            }
        case "courses/1": payload = course
        case "courses/2":
            var schoolCourse = course
            schoolCourse["id"] = 2
            schoolCourse["name"] = "学校测试课程"
            schoolCourse["number"] = "UI-002"
            payload = schoolCourse
        case "courses/histories/UI-002": payload = []
        case "courses/histories/UI-001":
            payload = [["term": "2025-2026-1", "avg_score": 85, "max_score": 98, "student_num": 30],
                       ["term": "2025-2026-2", "avg_score": 88, "max_score": 99, "student_num": 35]]
        case "user/followers", "user/followings": payload = page == "0" ? [user] : []
        case "user/info":
            profileChanges.merge(body) { _, new in new }
            payload = [:] as [String: String]
        default:
            if path.hasPrefix("posters/") || path.hasPrefix("papers/") {
                let components = path.split(separator: "/")
                guard components.count == 2, let id = Int(components[1]),
                      ["GET", "PUT", "DELETE"].contains(method) else { throw URLError(.unsupportedURL) }
                let records = path.hasPrefix("posters/") ? createdPosters + [poster] : createdPapers + [paper]
                let deletedIDs = path.hasPrefix("posters/") ? deletedPosterIDs : deletedPaperIDs
                guard records.contains(where: { $0["id"] as? Int == id }), !deletedIDs.contains(id)
                else { return try jsonResponse(["error": "not_found"], url: url, statusCode: 404) }
                if method == "DELETE" {
                    if path.hasPrefix("posters/") { deletedPosterIDs.insert(id) } else { deletedPaperIDs.insert(id) }
                }
                if path.hasPrefix("posters/") {
                    if method == "PUT", id == 1 { posterChanges.merge(body) { _, new in new } }
                    if method == "PUT", let index = createdPosters.firstIndex(where: { $0["id"] as? Int == id }) {
                        for (key, value) in body { createdPosters[index][key] = value }
                    }
                    payload = createdPosters.first(where: { $0["id"] as? Int == id }) ?? poster
                } else {
                    if method == "PUT", let index = createdPapers.firstIndex(where: { $0["id"] as? Int == id }) {
                        for (key, value) in body { createdPapers[index][key] = value }
                    }
                    payload = createdPapers.first(where: { $0["id"] as? Int == id }) ?? paper
                }
            } else if path.hasPrefix("reaction/comments/") {
                let components = path.split(separator: "/")
                guard components.count == 3, let id = Int(components[2]), method == "DELETE",
                      id == 1 || comments.contains(where: { $0["id"] as? Int == id })
                else { throw URLError(.unsupportedURL) }
                deletedCommentIDs.insert(id)
                payload = [:] as [String: String]
            } else if path.hasPrefix("user/info/") || path.hasPrefix("user/follow/") {
                let components = path.split(separator: "/")
                guard components.count == 3, let id = Int(components[2]),
                      path.hasPrefix("user/info/") ? method == "GET" && [0, 1].contains(id) : method == "POST" && id == 1
                else { throw URLError(.unsupportedURL) }
                if path.hasPrefix("user/follow/"), method == "POST" { following.toggle() }
                payload = ["user": user, "following_num": 1, "follower_num": 1,
                           "following": following, "follower": false, "own": path == "user/info/0"]
            } else {
                throw URLError(.unsupportedURL)
            }
        }
        return try jsonResponse(payload, url: url)
    }

    private func jsonResponse(_ payload: Any, url: URL, statusCode: Int = 200) throws -> (Data, URLResponse) {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil,
                                             headerFields: ["Content-Type": "application/json"]) else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }

    private var user: [String: Any] {
        var base: [String: Any] = ["id": 1, "create_time": timestamp, "nickname": "自动化测试用户", "motto": "测试签名"]
        let emptyAvatar: [String: Any] = ["mid": "", "url": "", "low_url": ""]
        base["avatar"] = mediaEnabled ? mediaImage : emptyAvatar
        base["identity"] = ["id": 1, "color": "#FF9500", "text": "测试", "create_time": timestamp, "update_time": timestamp] as [String: Any]
        return base.merging(profileChanges) { _, new in new }
    }

    private var poster: [String: Any] {
        let base: [String: Any] = ["id": 1, "anonymous": false, "claim": ["id": 1, "text": "日常"], "comment_num": 1,
         "create_time": timestamp, "edit_time": timestamp, "update_time": timestamp,
         "images": mediaEnabled ? posterImages : [], "like": likedObjects.contains("poster1"), "like_num": 1, "own": true,
         "plugins": "[]", "public": true, "tags": AppUITestBootstrap.environment["BIT101_UI_TEST_LONG_TAGS"] == "1"
            ? (1...8).map { "横向滚动标签\($0)" } : ["测试", "自动化"],
         "text": readingText("自动化测试话题正文", ending: "长帖末尾"), "title": "自动化测试话题", "user": user,
         "subscription": subscriptions["poster1"] ?? 0]
        return base.merging(posterChanges) { _, new in new }
    }

    private func readingText(_ text: String, ending: String) -> String {
        guard AppUITestBootstrap.environment["BIT101_UI_TEST_LONG_TEXT"] == "1" else { return text }
        return text + String(repeating: "正文片段 ", count: 8_000) + ending
    }

    private func paginationItems(_ item: [String: Any], page: String, key: String, title: String) -> [[String: Any]] {
        guard let page = Int(page), (0...1).contains(page) else { return [] }
        return (1...8).map { offset in
            var copy = item
            let id = page * 8 + offset
            copy["id"] = id
            copy[key] = "\(title) \(id)"
            return copy
        }
    }

    private var paper: [String: Any] {
        ["id": 1, "title": "自动化测试文章", "intro": "测试文章简介", "content": paperContent,
         "create_time": timestamp, "update_time": timestamp, "update_user": user, "anonymous": false,
         "like_num": 1, "comment_num": 1, "public_edit": true, "like": likedObjects.contains("paper1"), "own": true]
    }

    private var paperContent: String {
        guard mediaEnabled else { return "# 测试文章\n\n自动化测试文章正文" }
        return #"""
        {"blocks":[
          {"id":"ui-header","type":"header","data":{"text":"测试文章","level":1}},
          {"id":"ui-paragraph","type":"paragraph","data":{"text":"自动化测试文章正文"}},
          {"id":"ui-link","type":"paragraph","data":{"text":"<a href=\"https://github.com/BIT101-dev/BIT101-iOS\">正文链接</a>"}},
          {"id":"ui-image","type":"image","data":{"file":{"url":"https://bit101.flwfdd.xyz/ui-images/image.png"},"caption":"测试图片"}},
          {"id":"ui-extended","type":"table","data":{"content":[["扩展正文"]]}}
        ]}
        """#
    }

    private var course: [String: Any] {
        ["id": 1, "name": "自动化测试课程", "number": "UI-001", "credit": 3, "like_num": 1,
         "comment_num": 1, "rate": 4, "teachers_name": "测试教师", "teachers_number": "T001",
         "like": likedObjects.contains("course1")]
    }

    private func makeComment(id: Int, text: String) -> [String: Any] {
        let text = AppUITestBootstrap.environment["BIT101_UI_TEST_COMMENT_MEDIA_LINKS"] == "1" && id == 1
            ? "https://example.com/comment" : text
        var replyUser = user
        replyUser["id"] = 0
        replyUser["nickname"] = ""
        return ["id": id, "obj": "comment\(id)", "images": mediaEnabled ? [mediaImage] : [], "user": user, "anonymous": false,
         "create_time": timestamp, "update_time": timestamp, "like": likedObjects.contains("comment\(id)"), "like_num": likedObjects.contains("comment\(id)") ? 1 : 0,
         "comment_num": 0, "own": true, "rate": 4, "reply_user": replyUser, "reply_obj": "", "text": readingText(text, ending: "长评末尾"), "sub": []]
    }
}

extension UITestHTTPTransport {
    private var mediaEnabled: Bool { AppUITestBootstrap.environment["BIT101_UI_TEST_MEDIA"] == "1" }
    private var posterImages: [[String: Any]] {
        guard AppUITestBootstrap.environment["BIT101_UI_TEST_MEDIA_RECOVERY"] == "1" else { return [mediaImage] }
        return [mediaImage, ["mid": "preview-recovery", "url": "https://bit101.flwfdd.xyz/ui-images/preview-recovery.png",
            "low_url": "https://bit101.flwfdd.xyz/ui-images/preview-missing.png"]]
    }
    private var mediaImage: [String: Any] {
        ["mid": "ui-image", "url": "https://bit101.flwfdd.xyz/ui-images/image.png", "low_url": "https://bit101.flwfdd.xyz/ui-images/image.png"]
    }
}

/// 学校交互场景使用课程、考试和空教室端口的固定响应。
final class UITestSchoolService: ScheduleServicing {
    private var authenticated = AppUITestBootstrap.environment["BIT101_UI_TEST_SCHOOL_SMS"] != "1"
    private let challenge = BITLoginAuthenticationChallenge(challengeID: "ui-school-sms", accessToken: "ui-school-token",
        status: "sms_required", maskedPhone: "138****0000", expiresIn: 600)
    static var payload: CourseSyncPayload { payload(term: "ui-test-term") }

    private func requireSchoolAvailability() throws {
        guard AppUITestBootstrap.environment["BIT101_UI_TEST_SCHOOL"] == "1" else { throw URLError(.notConnectedToInternet) }
    }

    private static func payload(term: String) -> CourseSyncPayload {
        let firstDay = ScheduleDateCodec.formatDate(ScheduleDateCodec.monday(containing: Date()))
        return CourseSyncPayload(term: term, firstDayString: firstDay, sourceFirstDayString: firstDay,
            normalizationOffset: 0, rawWeeksByCourse: [[1, 2, 3]], courses: [
                CourseRecord(id: "ui-school", term: term, name: "学校测试课程", teacher: "测试教师",
                    classroom: "文萃A101", description: "学校课程详情", weeks: [1, 2, 3], weekday: 1,
                    startSection: 1, endSection: 2, campus: "良乡校区", number: "UI-002", credit: 2,
                    hour: 32, type: "必修", category: "专业", department: "测试学院")
            ], exams: [
                ExamRecord(id: "ui-exam", term: term, name: "测试考试", courseID: "UI-002",
                    teacher: "测试教师", classroom: "文萃A101", dateString: firstDay,
                    beginTime: "10:00", endTime: "11:00", examMode: "闭卷", seatID: "1"),
                ExamRecord(id: "ui-outside-exam", term: term, name: "课间测试考试", courseID: "UI-003",
                    teacher: "测试教师", classroom: "文萃A102", dateString: firstDay,
                    beginTime: "12:30", endTime: "12:45", examMode: "开卷", seatID: "2")
            ])
    }

    func syncCourses(term: String?) async throws -> CourseSyncPayload {
        try requireSchoolAvailability()
        guard authenticated else { throw ScheduleServiceError.secondFactorRequired(challenge) }
        return Self.payload(term: term ?? "ui-test-term")
    }
    func fetchAvailableTerms() async throws -> [String] {
        try requireSchoolAvailability()
        guard authenticated else { throw ScheduleServiceError.secondFactorRequired(challenge) }
        return ["ui-test-term", "ui-test-term-2"]
    }
    func fetchCurrentTermOnly() async throws -> String { try requireSchoolAvailability(); return "ui-test-term" }
    func prepareTeachingCenterAccess() async throws { try requireSchoolAvailability() }
    func submitSMSCodeForTeachingCenterAuthentication(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws { try verify(code) }
    func syncDDLEvents(existingEvents: [DDLEventRecord], storedURL: String, schoolSMSCodeHandler: SchoolSMSCodeHandler?, onSource: DDLSyncSourceDelivery?) async throws -> DDLSyncPayload {
        try requireSchoolAvailability()
        if !authenticated, let schoolSMSCodeHandler {
            try verify(await schoolSMSCodeHandler(SchoolSMSCodeRequest(maskedPhone: "138****0000", purpose: "测试学校认证")))
        }
        return DDLSyncPayload(url: "https://lexue.bit.edu.cn/ui-test.ics", events: [
            DDLEventRecord(id: "eclass:ui", group: "eclass", title: "课程中心测试作业", text: "刷新后的学校详情",
                dueAt: Date().addingTimeInterval(86400), done: false)
        ], syncedGroups: ["eclass", "lexue"])
    }
    func refreshLexueCalendarURL(schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws -> String {
        try requireSchoolAvailability()
        return "https://lexue.bit.edu.cn/ui-test.ics"
    }
    func fetchCampuses() async throws -> [CampusRecord] {
        try requireSchoolAvailability()
        return [CampusRecord(id: "1", name: "良乡校区", code: "1"), CampusRecord(id: "2", name: "中关村校区", code: "2")]
    }
    func fetchBuildings(campusCode: String?) async throws -> [BuildingRecord] {
        try requireSchoolAvailability()
        return [BuildingRecord(id: "A", name: "文萃楼A", buildingCode: "A", campusName: "良乡校区", campusCode: campusCode ?? "1"),
         BuildingRecord(id: "B", name: "文萃楼B", buildingCode: "B", campusName: "良乡校区", campusCode: campusCode ?? "1")]
    }
    func fetchClassrooms(buildingID: String, term: String, date: Date) async throws -> [ClassroomRecord] {
        try requireSchoolAvailability()
        return [ClassroomRecord(id: buildingID + "101", name: buildingID + "101", busyTimeCodes: [])]
    }
    private func verify(_ code: String) throws {
        guard code == "123456" else { throw ScheduleServiceError.schoolSMSCodeInvalid("测试学校验证码错误。") }
        authenticated = true
    }
}

/// 日历确认分支通过应用层端口记录测试场景的导入及移除状态。
@MainActor
final class UITestSchedulePlatformActions: SchedulePlatformActions {
    private var imported = false
    private var recoveredHistory = false
    private let historyNeedsRecovery: Bool
    init(historyNeedsRecovery: Bool) { self.historyNeedsRecovery = historyNeedsRecovery }
    func enableCloudSync(session: AppStorageSession) async {}
    func enableCourseReminder(session: AppStorageSession) async {}
    func importSystemCalendar(courses: ScheduleCourseSnapshot, term: String) async throws -> Int {
        if historyNeedsRecovery, !recoveredHistory {
            throw ScheduleSystemCalendarError.importHistoryUnreadable
        }
        imported = true
        return 1
    }
    func importSystemCalendarEntries(_ content: ScheduleSystemCalendarContent, term: String) async throws -> Int { imported = true; return 1 }
    func deleteSystemCalendarEntries(_ content: ScheduleSystemCalendarContent, term: String) async throws -> ScheduleSystemCalendarMutationResult { remove() }
    func deleteSystemCalendarEntries(markerIDs: Set<String>, term: String) async throws -> ScheduleSystemCalendarMutationResult { remove() }
    func deleteImportedSystemCalendarEvents() async throws -> ScheduleSystemCalendarMutationResult { remove() }
    func rebuildSystemCalendarImportHistory() async throws -> Int { recoveredHistory = true; return 1 }
    private func remove() -> ScheduleSystemCalendarMutationResult {
        let result: ScheduleSystemCalendarMutationResult = imported ? .changed(1) : .noOp
        imported = false
        return result
    }
}
#endif
