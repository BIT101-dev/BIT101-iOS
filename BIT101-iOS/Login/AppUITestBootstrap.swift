#if BIT101_UI_TESTING
import StorageCore
import TransportCore
import Foundation
import Network
import UIKit
import PhotosUI
import QuickLook
import MediaKit
import ClientCore
import ScheduleDomain
import SchedulePorts
import CommunityCore
import CommunityPersistence
import DesignSystemKit
import SwiftUI

/// UI 自动化在本机连接中更新场景测试数据，App 进程持续运行。
nonisolated final class UITestControlServer: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "BIT101.UITestControl")

    init(handle: @escaping @Sendable (Data, @escaping @Sendable (Data) -> Void) -> Void) throws {
        let parameters = NWParameters.tcp
        guard
            let rawPort = ProcessInfo.processInfo.environment["BIT101_UI_TEST_CONTROL_PORT"]
                .flatMap(UInt16.init),
            let port = NWEndpoint.Port(rawValue: rawPort)
        else { throw URLError(.badURL) }
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
            data, _, complete, error in
            var content = buffer
            if let data { content.append(data) }
            if let end = content.firstIndex(of: 10) {
                handle(Data(content[..<end])) { response in
                    connection.send(
                        content: response + Data([10]),
                        completion: .contentProcessed { _ in connection.cancel() })
                }
            } else if error != nil || complete || content.count > 16_384 {
                connection.cancel()
            } else {
                receive(connection, buffer: content, handle: handle)
            }
        }
    }
}

/// 场景参数在同一个进程中更新，传输测试数据与页面共同读取这份配置。
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
        values = environment
        AppUITestBootstrap.configureFailures(environment)
        UIView.setAnimationsEnabled(environment["BIT101_UI_TEST_ANIMATIONS"] == "1")
        revision += 1
    }
}

enum AppUITestBootstrap {
    nonisolated static let usesProductionComposition =
        ProcessInfo.processInfo.environment["BIT101_UI_TEST_PRODUCTION_COMPOSITION"] == "1"
    static var environment: [String: String] {
        UITestSceneConfiguration.shared.snapshot.environment
    }
    private static var injectedScheduleConflictScene: Int?
    static var pendingRequests: [String: [CheckedContinuation<Void, Never>]] = [:]
    static var failingRequests: [String: [String: String]] = [:]
    static var persistentFailures: Set<String> = []
    static var holdingRequests: [String: [String: String]] = [:]
    static var completedRequests: Set<String> = []
    static var recoveredSuggestionID: UUID?

    static func configureFailures(_ environment: [String: String]) {
        let paths = (environment["BIT101_UI_TEST_PERSISTENT_FAILURES"] ?? "").split(
            separator: ","
        ).map(String.init)
        failingRequests = Dictionary(uniqueKeysWithValues: paths.map { ($0, [:]) })
        persistentFailures = Set(paths)
    }

    static func holdRequest(_ key: String) async {
        await withCheckedContinuation { pendingRequests[key, default: []].append($0) }
    }

    static func takeRequest(
        _ path: String, query: [URLQueryItem], from requests: inout [String: [String: String]],
        consuming: Bool = true
    ) -> Bool {
        guard let conditions = requests[path],
            conditions.allSatisfy({ name, value in
                query.contains(where: { $0.name == name && $0.value == value })
            })
        else { return false }
        if consuming { requests[path] = nil }
        return true
    }

    static func releaseRequest(_ key: String) {
        failingRequests.removeValue(forKey: key)
        persistentFailures.remove(key)
        holdingRequests.removeValue(forKey: key)
        pendingRequests.removeValue(forKey: key)?.forEach { $0.resume() }
    }

    static func releaseRequests() {
        holdingRequests.removeAll()
        completedRequests.removeAll()
        let requests = pendingRequests.values.flatMap { $0 }
        pendingRequests.removeAll()
        requests.forEach { $0.resume() }
    }

    static func prepareScheduleConflictIfRequested(
        cache: ScheduleCache, session: AppStorageSession
    ) async throws {
        let scene = UITestSceneConfiguration.shared.snapshot
        guard scene.environment["BIT101_UI_TEST_SCHEDULE_CONFLICT"] == "1",
            cache.primaryScheduleTitle == "本机标题",
            injectedScheduleConflictScene != scene.revision
        else { return }
        injectedScheduleConflictScene = scene.revision
        var remote =
            await ScheduleCacheStore.loadResultAsync(for: session).cacheIfReadable
            ?? ScheduleCache()
        remote.primaryScheduleTitle = "同步标题"
        remote.cloudSyncBaselineRecordTag = "ui-test-cloud-version"
        remote.syncData.cloudSyncBaselineUserState = try ScheduleCloudStateMerge.baseline(
            for: remote)
        guard
            await ScheduleCacheStore.saveAndWait(
                remote, source: .cloud,
                expectedAccountIdentifier: session.accountDirectoryName)
        else { throw CocoaError(.fileWriteUnknown) }
    }

    static func prepareSessionIfNeeded() async {
        let environment = Self.environment
        defer {
            if environment["BIT101_UI_TEST_SCORE_RECOVERY"] == "1" {
                AppFileDirectories.defaults.set(
                    Data("damaged-ui-score-filters".utf8),
                    forKey: AppFileDirectories.currentSession.key("score.filter.preferences"))
            }
            if environment["BIT101_UI_TEST_SETTINGS_RECOVERY"] == "1" {
                let key = AppFileDirectories.currentSession.key(
                    AppSettingsStore.storageKeyPrefix,
                    guestIdentifier: AppSettingsStore.defaultAccountIdentifier)
                AppFileDirectories.defaults.set(Data("damaged-ui-settings".utf8), forKey: key)
                AppSettingsStore.shared.reloadForCurrentAccount()
            }
        }
        guard environment["BIT101_UI_TEST_RESET_STORAGE"] == "1",
            let account = environment["BIT101_UI_TEST_ACCOUNT"], !account.isEmpty
        else { return }
        do {
            if environment["BIT101_UI_TEST_MEDIA_RECOVERY"] == "1" {
                guard await AppMedia.environment.clearCaches() else {
                    throw CocoaError(.fileWriteUnknown)
                }
                holdingRequests["media-recovery"] = [:]
            }
            _ = try await UITestLoginService().login(
                studentID: account, password: "ui-test-password")
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
                guard
                    var root = try JSONSerialization.jsonObject(
                        with: JSONEncoder().encode(cache)) as? [String: Any],
                    var course = root["courseData"] as? [String: Any]
                else { throw CocoaError(.coderInvalidValue) }
                course["customSchedules"] = [7]
                root["courseData"] = course
                let url = AppFileDirectories.accountSupportFileURL(
                    accountDirectoryName: AppFileDirectories.currentSession
                        .accountStorageIdentifier, named: "schedule-cache.json")
                try AppFileDirectories.files.createDirectory(
                    at: url.deletingLastPathComponent())
                try AppFileDirectories.files.writeData(
                    JSONSerialization.data(withJSONObject: root), to: url, options: .atomic)
            }
            if environment["BIT101_UI_TEST_MEDIA"] == "1" {
                let image = ComposerImageDraftSnapshot(
                    filename: "ui-image.png", previewData: mediaData, uploadData: mediaData)
                let drafts = AppAccountStores.shared.composerDrafts
                guard
                    await drafts.saveGallery(
                        GalleryComposerDraftSnapshot(
                            title: "图片测试草稿", text: "图片草稿正文",
                            selectedTags: [], customTags: [], anonymous: false, isPublic: true,
                            selectedClaimID: 0, images: [image])),
                    await drafts.saveSuggestion(
                        DeveloperSuggestionDraftSnapshot(
                            text: "图片建议草稿", images: [image], contact: "测试联系信息"))
                else {
                    throw URLError(.cannotWriteToFile)
                }
            }
        } catch {
            preconditionFailure("UI test session preparation failed: \(error)")
        }
    }

    private static func prepareDamagedAccountFile(_ name: String) throws {
        let url = AppFileDirectories.accountSupportFileURL(
            accountDirectoryName: AppFileDirectories.currentSession.accountStorageIdentifier,
            named: name)
        try AppFileDirectories.files.createDirectory(at: url.deletingLastPathComponent())
        try AppFileDirectories.files.writeData(Data("{damaged".utf8), to: url, options: .atomic)
    }

    static func prepareForLaunch() {
        let environment = Self.environment
        configureFailures(environment)
        guard AppFileDirectories.isRunningUITest else {
            preconditionFailure(
                "The UI automation App requires its isolated launch configuration")
        }
        UIView.setAnimationsEnabled(environment["BIT101_UI_TEST_ANIMATIONS"] == "1")
        UIApplication.shared.isIdleTimerDisabled = true
        guard environment["BIT101_UI_TEST_RESET_STORAGE"] == "1" else { return }

        AppFileDirectories.defaults.removePersistentDomain(
            forName: AppFileDirectories.uiTestDefaultsSuiteName
        )
        if environment["BIT101_UI_TEST_UPDATE"] != nil {
            AppFileDirectories.defaults.set(
                false, forKey: AppSettingsStore.automaticUpdateChecksEnabledKey)
        }
        AppAccountSession.resetUITestCredentials()

        let supportDirectory = AppFileDirectories.appSupportURL(named: "BIT101-iOS")
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
            ComposerImageDraftSnapshot(
                filename: $0, previewData: mediaData, uploadData: mediaData)
        }
        let draft = DeveloperSuggestionDraftSnapshot(
            text: "恢复建议草稿", images: images, contact: "测试联系信息")
        let context = FeedbackDeviceContext.current
        let payload = DeveloperSuggestionPayload(
            comment: draft.text, contact: draft.contact, appVersion: "test", build: "test",
            systemVersion: "test", deviceModel: "test", networkStatus: context.networkStatus,
            submittedAt: Date(), context: context,
            attachments: images.map {
                .init(
                    filename: $0.filename, contentType: "image/jpeg",
                    data: mediaData.base64EncodedString())
            })
        recoveredSuggestionID = payload.requestID
        let saved = DeveloperSuggestionDraftSnapshot(
            text: draft.text, images: images, contact: draft.contact,
            pendingSubmissionMetadata: try payload.draftMetadata(matching: draft))
        guard await AppAccountStores.shared.composerDrafts.saveSuggestion(saved) else {
            throw URLError(.cannotWriteToFile)
        }
        let url = AppFileDirectories.accountSupportFileURL(
            accountDirectoryName: AppFileDirectories.currentSession.accountStorageIdentifier,
            named: "composer-suggestion.json")
        let data = try AppFileDirectories.files.readData(at: url)
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let revision = body["assetRevision"] as? String
        else { throw CocoaError(.coderInvalidValue) }
        try AppFileDirectories.files.removeItem(
            at: url.appendingPathExtension("assets").appending(path: revision).appending(
                path: "image-1.jpg"))
    }

    static var mediaData: Data {
        let size = CGSize(
            width: 80, height: environment["BIT101_UI_TEST_PORTRAIT_MEDIA"] == "1" ? 160 : 80)
        return UIGraphicsImageRenderer(size: size).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}

extension View {
    /// 外部链接的 UI 场景读取页面实际发出的地址。
    func uiTestExternalURLs() -> some View {
        environment(
            \.openURL,
            OpenURLAction { url in
                UITestAccessibilityActions.openedExternalURL = url.absoluteString
                return .handled
            })
    }
}

/// 学校交互场景使用课程、考试和空教室端口的固定响应。
final class UITestSchoolService: ScheduleServicing {
    private var authenticated =
        AppUITestBootstrap.environment["BIT101_UI_TEST_SCHOOL_SMS"] != "1"
        && AppUITestBootstrap.environment["BIT101_UI_TEST_SCHOOL_CAPTCHA"] != "1"
    private var needsCaptcha =
        AppUITestBootstrap.environment["BIT101_UI_TEST_SCHOOL_CAPTCHA"] == "1"
    private var classroomAuthenticated =
        AppUITestBootstrap.environment["BIT101_UI_TEST_CLASSROOM_SMS"] != "1"
    private var challenge: BITLoginAuthenticationChallenge {
        let image =
            needsCaptcha
            ? UIGraphicsImageRenderer(size: CGSize(width: 160, height: 48)).pngData { context in
                UIColor.systemBackground.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 160, height: 48))
                ("aB12" as NSString).draw(
                    at: CGPoint(x: 8, y: 8),
                    withAttributes: [
                        .font: UIFont.preferredFont(forTextStyle: .title2),
                        .foregroundColor: UIColor.label,
                    ])
            } : nil
        return BITLoginAuthenticationChallenge(
            challengeID: "ui-school-sms", accessToken: "ui-school-token",
            status: needsCaptcha ? "waiting_captcha" : "waiting_sms",
            maskedPhone: "138****0000", expiresIn: 600,
            captchaImage: image.map { "data:image/png;base64," + $0.base64EncodedString() })
    }
    static var payload: CourseSyncPayload { payload(term: "ui-test-term") }

    private func requireSchoolAvailability() throws {
        guard AppUITestBootstrap.environment["BIT101_UI_TEST_SCHOOL"] == "1" else {
            throw URLError(.notConnectedToInternet)
        }
    }

    private static func payload(term: String) -> CourseSyncPayload {
        let firstDay = ScheduleDateCodec.formatDate(
            ScheduleDateCodec.monday(containing: Date()))
        return CourseSyncPayload(
            term: term, firstDayString: firstDay, sourceFirstDayString: firstDay,
            normalizationOffset: 0, rawWeeksByCourse: [[1, 2, 3]],
            courses: [
                CourseRecord(
                    id: "ui-school", term: term, name: "学校测试课程", teacher: "测试教师",
                    classroom: "文萃A101", description: "学校课程详情", weeks: [1, 2, 3], weekday: 1,
                    startSection: 1, endSection: 2, campus: "良乡校区", number: "UI-002", credit: 2,
                    hour: 32, type: "必修", category: "专业", department: "测试学院")
            ],
            exams: [
                ExamRecord(
                    id: "ui-exam", term: term, name: "测试考试", courseID: "UI-002",
                    teacher: "测试教师", classroom: "文萃A101", dateString: firstDay,
                    beginTime: "10:00", endTime: "11:00", examMode: "闭卷", seatID: "1"),
                ExamRecord(
                    id: "ui-outside-exam", term: term, name: "课间测试考试", courseID: "UI-003",
                    teacher: "测试教师", classroom: "文萃A102", dateString: firstDay,
                    beginTime: "12:30", endTime: "12:45", examMode: "开卷", seatID: "2"),
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
    func fetchCurrentTermOnly() async throws -> String {
        try requireSchoolAvailability()
        return "ui-test-term"
    }
    func prepareTeachingAccess() async throws { try requireSchoolAvailability() }
    func submitTeachingCode(_ code: String, for challenge: BITLoginAuthenticationChallenge)
        async throws
    {
        if needsCaptcha {
            guard code == "aB12" else {
                throw ScheduleServiceError.challengeInvalid("图形验证码验证失败，请重新发起验证。")
            }
            needsCaptcha = false
            throw ScheduleServiceError.secondFactorRequired(self.challenge)
        }
        try verify(code)
    }
    func syncDDLEvents(
        existingEvents: [DDLEventRecord], storedURL: String,
        schoolSMSCodeHandler: SchoolSMSCodeHandler?, onSource: DDLSyncSourceDelivery?
    ) async throws -> DDLSyncPayload {
        try requireSchoolAvailability()
        if !authenticated, let schoolSMSCodeHandler {
            try verify(
                await schoolSMSCodeHandler(
                    SchoolSMSCodeRequest(maskedPhone: "138****0000", purpose: "测试学校认证")))
        }
        return DDLSyncPayload(
            url: "https://lexue.bit.edu.cn/ui-test.ics",
            events: [
                DDLEventRecord(
                    id: "eclass:23", group: "eclass", title: "课程中心测试作业", text: "刷新后的学校详情",
                    dueAt: Date().addingTimeInterval(86400), done: false, sourceCourseIDs: [42])
            ], syncedGroups: ["eclass", "lexue"])
    }
    func refreshLexueCalendarURL(schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws
        -> String
    {
        try requireSchoolAvailability()
        return "https://lexue.bit.edu.cn/ui-test.ics"
    }
    func fetchCampuses() async throws -> [CampusRecord] {
        try requireSchoolAvailability()
        if AppUITestBootstrap.environment["BIT101_UI_TEST_CLASSROOM_LOADING"] == "1" {
            try await Task.sleep(for: .seconds(30))
        }
        return [
            CampusRecord(id: "1", name: "良乡校区", code: "1"),
            CampusRecord(id: "2", name: "中关村校区", code: "2"),
        ]
    }
    func fetchBuildings(campusCode: String?) async throws -> [BuildingRecord] {
        try requireSchoolAvailability()
        guard classroomAuthenticated else {
            throw ScheduleServiceError.secondFactorRequired(challenge)
        }
        return Self.buildings(campusCode: campusCode)
    }
    static func buildings(campusCode: String?) -> [BuildingRecord] {
        return [
            BuildingRecord(
                id: "A", name: "文萃楼A", buildingCode: "A", campusName: "良乡校区",
                campusCode: campusCode ?? "1"),
            BuildingRecord(
                id: "B", name: "文萃楼B", buildingCode: "B", campusName: "良乡校区",
                campusCode: campusCode ?? "1"),
        ]
    }
    func fetchClassrooms(buildingID: String, term: String, date: Date) async throws
        -> [ClassroomRecord]
    {
        try requireSchoolAvailability()
        guard classroomAuthenticated else {
            throw ScheduleServiceError.secondFactorRequired(challenge)
        }
        let prefix =
            AppUITestBootstrap.environment["BIT101_UI_TEST_CLASSROOM_SMS"] == "1" ? "已验证" : ""
        return [
            ClassroomRecord(
                id: buildingID + "101", name: prefix + buildingID + "101", busyTimeCodes: [])
        ]
    }
    private func verify(_ code: String) throws {
        guard code == "123456" else {
            throw ScheduleServiceError.schoolSMSCodeInvalid("测试学校验证码错误。")
        }
        authenticated = true
        classroomAuthenticated = true
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
    func importCalendarEntries(_ content: ScheduleSystemCalendarContent, term: String)
        async throws -> Int
    {
        imported = true
        return 1
    }
    func deleteCalendarEntries(_ content: ScheduleSystemCalendarContent, term: String)
        async throws -> ScheduleSystemCalendarMutationResult
    { remove() }
    func deleteCalendarEntries(markerIDs: Set<String>, term: String) async throws
        -> ScheduleSystemCalendarMutationResult
    { remove() }
    func deleteImportedEvents() async throws -> ScheduleSystemCalendarMutationResult {
        remove()
    }
    func rebuildSystemHistory() async throws -> Int {
        recoveredHistory = true
        return 1
    }
    private func remove() -> ScheduleSystemCalendarMutationResult {
        let result: ScheduleSystemCalendarMutationResult = imported ? .changed(1) : .noOp
        imported = false
        return result
    }
}
#endif
