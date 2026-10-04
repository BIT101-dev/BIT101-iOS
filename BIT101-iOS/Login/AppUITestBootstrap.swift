#if BIT101_UI_TESTING
import StorageCore
import TransportCore
import Foundation
import Network
import UIKit
import ClientCore
import ScheduleDomain
import SchedulePorts
import CommunityCore
import CommunityPersistence
import DesignSystemKit
import SwiftUI
import Combine

/// UI 自动化在本机连接中更新场景夹具，App 进程持续运行。
nonisolated final class UITestControlServer: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "BIT101.UITestControl")

    init(handle: @escaping @Sendable (Data, @escaping @Sendable (Data) -> Void) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 19101)
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
        values = environment
        revision += 1
    }
}

@MainActor
final class UITestSceneState: ObservableObject {
    @Published private(set) var lifecycle: AppAccountLifecycle
    @Published private(set) var revision = 0
    var largeText = false
    var colorScheme: ColorScheme?
    private let makeLifecycle: () -> AppAccountLifecycle
    private var control: UITestControlServer?

    init(makeLifecycle: @escaping () -> AppAccountLifecycle) {
        self.makeLifecycle = makeLifecycle
        lifecycle = makeLifecycle()
        largeText = AppUITestBootstrap.environment["BIT101_UI_TEST_LARGE_TEXT"] == "1"
        colorScheme = AppUITestBootstrap.environment["BIT101_UI_TEST_STYLE"].flatMap { $0 == "Dark" ? .dark : .light }
        do {
            control = try UITestControlServer { [weak self] data, reply in
                Task { @MainActor in
                    guard let self else { return }
                    do {
                        let environment = try JSONDecoder().decode([String: String].self, from: data)
                        self.configure(environment)
                        reply(Data("\(ProcessInfo.processInfo.processIdentifier):\(self.revision)".utf8))
                    } catch {
                        reply(Data("invalid scene configuration: \(error)".utf8))
                    }
                }
            }
        } catch {
            preconditionFailure("UI test control channel failed: \(error)")
        }
    }

    private func configure(_ environment: [String: String]) {
        AppErrorPresenter.shared.reset()
        UITestSceneConfiguration.shared.replace(with: environment)
        largeText = environment["BIT101_UI_TEST_LARGE_TEXT"] == "1"
        colorScheme = environment["BIT101_UI_TEST_STYLE"].flatMap { $0 == "Dark" ? .dark : .light }
        AppUITestBootstrap.prepareForLaunch()
        AppSettingsStore.shared.reloadForCurrentAccount()
        lifecycle = makeLifecycle()
        revision += 1
    }

    func accelerateTransitions() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { window.layer.speed = 10 }
        }
    }
}

enum AppUITestBootstrap {
    static var environment: [String: String] { UITestSceneConfiguration.shared.snapshot.environment }

    static func prepareSessionIfNeeded() async {
        let environment = Self.environment
        guard environment["BIT101_UI_TEST_RESET_STORAGE"] == "1",
              let account = environment["BIT101_UI_TEST_ACCOUNT"], !account.isEmpty else { return }
        do {
            _ = try await UITestLoginService().login(studentID: account, password: "ui-test-password")
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
        LoginStorage.resetUITestCredentials()

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
            AppErrorPresenter.shared.present(AppAlert.informational(title: "打开链接", message: url.absoluteString))
            return .handled
        })
    }
}

/// 固定响应通过生产 Service 解码，交互修改保留到当前测试场景结束。
final class UITestHTTPTransport: HTTPTransport {
    private var fixtureRevision = -1
    private var likedObjects: Set<String> = []
    private var comments: [[String: Any]] = []
    private var createdPosters: [[String: Any]] = []
    private var createdPapers: [[String: Any]] = []
    private var deletedIDs: Set<Int> = []
    private var deletedCommentIDs: Set<Int> = []
    private var profileChanges: [String: Any] = [:]
    private var posterChanges: [String: Any] = [:]
    private var following = false
    private var imageUploads = 0
    private var failedPaths: Set<String> = []
    private let timestamp = "2026-10-01T10:00:00Z"

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let snapshot = UITestSceneConfiguration.shared.snapshot
        if fixtureRevision != snapshot.revision {
            fixtureRevision = snapshot.revision
            likedObjects = []
            comments = []
            createdPosters = []
            createdPapers = []
            deletedIDs = []
            deletedCommentIDs = []
            profileChanges = [:]
            posterChanges = [:]
            following = false
            imageUploads = 0
            failedPaths = []
        }
        guard let url = request.url else { throw URLError(.badURL) }
        if url.host == "feedback.aihelpme.dev", AppUITestBootstrap.environment["BIT101_UI_TEST_CONTENT"] == "1" {
            return try jsonResponse([:] as [String: String], url: url)
        }
        if url.host == "itunes.apple.com", let fixture = AppUITestBootstrap.environment["BIT101_UI_TEST_UPDATE"] {
            return try jsonResponse(["results": [["version": fixture == "current" ? "0.0" : "999.0",
                "releaseNotes": "自动化测试更新", "trackViewUrl": BIT101AppStore.url.absoluteString]]], url: url)
        }
        guard AppUITestBootstrap.environment["BIT101_UI_TEST_CONTENT"] == "1",
              url.host == "bit101.flwfdd.xyz" else {
            throw URLError(.notConnectedToInternet)
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if AppUITestBootstrap.environment["BIT101_UI_TEST_FAILURE_ONCE"] == "1",
           ["posters", "papers", "courses"].contains(path), failedPaths.insert(path).inserted {
            throw URLError(.networkConnectionLost)
        }
        if path.hasPrefix("ui-images/") {
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"]) else {
                throw URLError(.badServerResponse)
            }
            return (AppUITestBootstrap.mediaData, response)
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let page = query.first(where: { $0.name == "page" })?.value ?? "0"
        let body = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
        let method = request.httpMethod ?? "GET"
        let payload: Any
        switch path {
        case "posters/claims": payload = [["id": 1, "text": "日常"]]
        case "manage/report_types": payload = [["id": 1, "text": "其他"]]
        case "manage/reports": payload = [:] as [String: String]
        case "upload/image":
            imageUploads += 1
            if imageUploads == 1 { throw URLError(.networkConnectionLost) }
            payload = mediaImage
        case "messages/unread_nums": payload = ["comment": 1, "follow": 1, "like": 1, "system": 1]
        case "messages":
            payload = query.contains(where: { $0.name == "last_id" }) ? [] : [[
                "id": 1, "from_user": user, "link_obj": "poster1", "obj": "poster1",
                "text": "自动化测试消息", "update_time": timestamp,
            ]]
        case "reaction/like":
            let object = body["obj"] as? String ?? "poster1"
            if likedObjects.contains(object) { likedObjects.remove(object) } else { likedObjects.insert(object) }
            payload = ["like": likedObjects.contains(object), "like_num": likedObjects.contains(object) ? 2 : 1]
        case "reaction/comments":
            if method == "POST" {
                var comment = makeComment(id: comments.count + 2, text: body["text"] as? String ?? "测试回复")
                comment["reply_obj"] = body["reply_obj"] ?? ""
                comment["obj"] = body["obj"] ?? "poster1"
                comments.append(comment)
                payload = comment
            } else {
                payload = page == "0" ? ([makeComment(id: 1, text: "自动化测试评论")] + comments)
                    .filter { !deletedCommentIDs.contains($0["id"] as? Int ?? 0) } : []
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
                payload = page == "0" ? ([poster] + createdPosters).filter { !deletedIDs.contains($0["id"] as? Int ?? 0) } : []
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
            } else {
                payload = page == "0" ? ([paper] + createdPapers).filter { !deletedIDs.contains($0["id"] as? Int ?? 0) } : []
            }
        case "courses":
            var schoolCourse = course
            schoolCourse["id"] = 2
            schoolCourse["name"] = "学校测试课程"
            schoolCourse["number"] = "UI-002"
            payload = page == "0" ? (AppUITestBootstrap.environment["BIT101_UI_TEST_SCHOOL"] == "1" ? [course, schoolCourse] : [course]) : []
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
                let id = Int(url.lastPathComponent) ?? 1
                if method == "DELETE" { deletedIDs.insert(id) }
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
                if let id = Int(url.lastPathComponent) { deletedCommentIDs.insert(id) }
                payload = [:] as [String: String]
            } else if path.hasPrefix("user/info/") || path.hasPrefix("user/follow/") {
                if path.hasPrefix("user/follow/"), method == "POST" { following.toggle() }
                payload = ["user": user, "following_num": 1, "follower_num": 1,
                           "following": following, "follower": false, "own": path == "user/info/0"]
            } else {
                throw URLError(.unsupportedURL)
            }
        }
        return try jsonResponse(payload, url: url)
    }

    private func jsonResponse(_ payload: Any, url: URL) throws -> (Data, URLResponse) {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
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
         "images": mediaEnabled ? [mediaImage] : [], "like": likedObjects.contains("poster1"), "like_num": 1, "own": true,
         "plugins": "[]", "public": true, "tags": ["测试", "自动化"], "text": "自动化测试话题正文", "title": "自动化测试话题", "user": user]
        return base.merging(posterChanges) { _, new in new }
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
          {"id":"ui-image","type":"image","data":{"file":{"url":"https://bit101.flwfdd.xyz/ui-images/image.png"},"caption":"测试图片"}}
        ]}
        """#
    }

    private var course: [String: Any] {
        ["id": 1, "name": "自动化测试课程", "number": "UI-001", "credit": 3, "like_num": 1,
         "comment_num": 1, "rate": 4, "teachers_name": "测试教师", "teachers_number": "T001",
         "like": likedObjects.contains("course1")]
    }

    private func makeComment(id: Int, text: String) -> [String: Any] {
        var replyUser = user
        replyUser["id"] = 0
        replyUser["nickname"] = ""
        return ["id": id, "obj": "comment\(id)", "images": mediaEnabled ? [mediaImage] : [], "user": user, "anonymous": false,
         "create_time": timestamp, "update_time": timestamp, "like": likedObjects.contains("comment\(id)"), "like_num": likedObjects.contains("comment\(id)") ? 1 : 0,
         "comment_num": 0, "own": true, "rate": 4, "reply_user": replyUser, "reply_obj": "", "text": text, "sub": []]
    }
}

extension UITestHTTPTransport {
    private var mediaEnabled: Bool { AppUITestBootstrap.environment["BIT101_UI_TEST_MEDIA"] == "1" }
    private var mediaImage: [String: Any] {
        ["mid": "ui-image", "url": "https://bit101.flwfdd.xyz/ui-images/image.png", "low_url": "https://bit101.flwfdd.xyz/ui-images/image.png"]
    }
}

@MainActor
final class UITestPreferenceCloudStore: PreferenceCloudStoring {
    private(set) var dictionaryRepresentation: [String: Any] = [:]
    func data(forKey key: String) -> Data? { dictionaryRepresentation[key] as? Data }
    func set(_ value: Any?, forKey key: String) { dictionaryRepresentation[key] = value }
    func synchronize() -> Bool { true }
}

/// UI 宿主的文件与缓存目录归固定测试根路径。
nonisolated struct UITestAppFileService: AppFileService {
    private let local = LocalAppFileService()
    private var root: URL {
        guard let support = local.directoryURL(.applicationSupportDirectory) else {
            preconditionFailure("UI test Application Support directory is unavailable")
        }
        return support.appending(path: "BIT101-UITests", directoryHint: .isDirectory)
    }
    func directoryURL(_ directory: FileManager.SearchPathDirectory) -> URL? {
        root.appending(path: String(directory.rawValue), directoryHint: .isDirectory)
    }
    func appGroupContainerURL(identifier: String) -> URL? { root.appending(path: "AppGroup", directoryHint: .isDirectory) }
    var temporaryDirectoryURL: URL { root.appending(path: "Temporary", directoryHint: .isDirectory) }
    func fileExists(at url: URL) -> Bool { local.fileExists(at: url) }
    func readData(at url: URL) throws -> Data { try local.readData(at: url) }
    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws { try local.writeData(data, to: url, options: options) }
    func createDirectory(at url: URL) throws { try local.createDirectory(at: url) }
    func removeItem(at url: URL) throws { try local.removeItem(at: url) }
    func setPrivateFileProtection(at url: URL) throws { try local.setPrivateFileProtection(at: url) }
    func setExcludedFromBackup(at url: URL) throws { try local.setExcludedFromBackup(at: url) }
    func contentsOfDirectory(at url: URL, options: FileManager.DirectoryEnumerationOptions) throws -> [URL] { try local.contentsOfDirectory(at: url, options: options) }
    func regularFileSize(at url: URL) -> Int? { local.regularFileSize(at: url) }
    func isRegularFile(at url: URL) -> Bool { local.isRegularFile(at: url) }
    func modificationDate(at url: URL) -> Date? { local.modificationDate(at: url) }
    func setModificationDate(_ date: Date, at url: URL) throws { try local.setModificationDate(date, at: url) }
    func removeContents(of directory: URL) -> Bool { local.removeContents(of: directory) }
    func totalRegularFileSize(at directory: URL) -> Int64 { local.totalRegularFileSize(at: directory) }
    func canonicalFileURL(_ url: URL) -> URL { local.canonicalFileURL(url) }
}

/// 学校交互场景使用课程、考试和空教室端口的固定响应。
final class UITestSchoolService: ScheduleServicing {
    private var authenticated = AppUITestBootstrap.environment["BIT101_UI_TEST_SCHOOL_SMS"] != "1"
    private let challenge = BITLoginAuthenticationChallenge(challengeID: "ui-school-sms", accessToken: "ui-school-token",
        status: "sms_required", maskedPhone: "138****0000", expiresIn: 600)
    static var payload: CourseSyncPayload { payload(term: "ui-test-term") }

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
                    beginTime: "10:00", endTime: "11:00", examMode: "闭卷", seatID: "1")
            ])
    }

    func syncCourses(term: String?) async throws -> CourseSyncPayload {
        guard authenticated else { throw ScheduleServiceError.secondFactorRequired(challenge) }
        return Self.payload(term: term ?? "ui-test-term")
    }
    func fetchAvailableTerms() async throws -> [String] {
        guard authenticated else { throw ScheduleServiceError.secondFactorRequired(challenge) }
        return ["ui-test-term", "ui-test-term-2"]
    }
    func fetchCurrentTermOnly() async throws -> String { "ui-test-term" }
    func prepareTeachingCenterAccess() async throws {}
    func submitSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge, term: String?) async throws -> CourseSyncPayload {
        try verify(code)
        return try await syncCourses(term: term)
    }
    func submitSMSCodeForTeachingCenterAuthentication(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws { try verify(code) }
    func syncDDLEvents(existingEvents: [DDLEventRecord], storedURL: String, schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws -> DDLSyncPayload {
        if !authenticated, let schoolSMSCodeHandler {
            try verify(await schoolSMSCodeHandler(SchoolSMSCodeRequest(maskedPhone: "138****0000", purpose: "测试学校认证")))
        }
        return DDLSyncPayload(url: "https://lexue.bit.edu.cn/ui-test.ics", events: [
            DDLEventRecord(id: "eclass:ui", group: "eclass", title: "课程中心测试作业", text: "刷新后的学校详情",
                dueAt: Date().addingTimeInterval(86400), done: false)
        ], syncedGroups: ["eclass", "lexue"])
    }
    func refreshLexueCalendarURL(schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws -> String { "https://lexue.bit.edu.cn/ui-test.ics" }
    func fetchCampuses() async throws -> [CampusRecord] {
        [CampusRecord(id: "1", name: "良乡校区", code: "1"), CampusRecord(id: "2", name: "中关村校区", code: "2")]
    }
    func fetchBuildings(campusCode: String?) async throws -> [BuildingRecord] {
        [BuildingRecord(id: "A", name: "文萃楼A", buildingCode: "A", campusName: "良乡校区", campusCode: campusCode ?? "1"),
         BuildingRecord(id: "B", name: "文萃楼B", buildingCode: "B", campusName: "良乡校区", campusCode: campusCode ?? "1")]
    }
    func fetchClassrooms(buildingID: String, term: String) async throws -> [ClassroomRecord] {
        [ClassroomRecord(id: buildingID + "101", name: buildingID + "101", busyTimeCodes: [])]
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
    func enableCloudSync(session: AppStorageSession) async {}
    func enableCourseReminder(session: AppStorageSession) async {}
    func importSystemCalendar(courses: ScheduleCourseSnapshot, term: String) async throws -> Int { imported = true; return 1 }
    func importSystemCalendarEntries(_ content: ScheduleSystemCalendarContent, term: String) async throws -> Int { imported = true; return 1 }
    func deleteSystemCalendarEntries(_ content: ScheduleSystemCalendarContent, term: String) async throws -> ScheduleSystemCalendarMutationResult { remove() }
    func deleteSystemCalendarEntries(markerIDs: Set<String>, term: String) async throws -> ScheduleSystemCalendarMutationResult { remove() }
    func deleteImportedSystemCalendarEvents() async throws -> ScheduleSystemCalendarMutationResult { remove() }
    private func remove() -> ScheduleSystemCalendarMutationResult {
        let result: ScheduleSystemCalendarMutationResult = imported ? .changed(1) : .noOp
        imported = false
        return result
    }
}
#endif
