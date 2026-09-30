import SchedulePorts
import ScoreDomain
import GalleryFeature
@testable import MineFeature
import CommunityTransport
import TransportCore
@testable import ScheduleFeature
@testable import ScheduleInfrastructure
@testable import MediaKit
import CommunityCore
import ScoreFeature
import Combine
import StorageCore
import ClientCore
import ScheduleDomain
import Foundation
import Testing
@testable import BIT101_iOS

@MainActor
final class RecordingSchedulePlatformActions: SchedulePlatformActions {
    var cloudCache: ScheduleCache?
    var cloudSession: AppStorageSession?
    var reminderSession: AppStorageSession?
    var importedCourses: ScheduleCourseSnapshot?
    var importedTerm: String?
    var calendarContent: ScheduleSystemCalendarContent?
    var calendarTerm: String?
    var calendarMarkerIDs: Set<String>?
    var deleteCount = 0
    var importError: Error?
    private var enableContinuation: CheckedContinuation<Void, Never>?

    func enableCloudSync(cache: ScheduleCache, session: AppStorageSession) async {
        cloudCache = cache
        cloudSession = session
        finishEnablingIfReady()
    }

    func enableCourseReminder(session: AppStorageSession) async {
        reminderSession = session
        finishEnablingIfReady()
    }

    func importSystemCalendar(courses: ScheduleCourseSnapshot, term: String) async throws -> Int {
        if let importError { throw importError }
        importedCourses = courses
        importedTerm = term
        return 7
    }

    func deleteImportedSystemCalendarEvents() async throws -> ScheduleSystemCalendarMutationResult {
        deleteCount += 1
        return .changed(3)
    }

    func importSystemCalendarEntries(_ content: ScheduleSystemCalendarContent, term: String) async throws -> Int {
        if let importError { throw importError }
        calendarContent = content
        calendarTerm = term
        return 2
    }

    func deleteSystemCalendarEntries(_ content: ScheduleSystemCalendarContent, term: String) async throws -> ScheduleSystemCalendarMutationResult {
        if let importError { throw importError }
        calendarContent = content
        calendarTerm = term
        return .changed(2)
    }

    func deleteSystemCalendarEntries(markerIDs: Set<String>, term: String) async throws -> ScheduleSystemCalendarMutationResult {
        if let importError { throw importError }
        calendarMarkerIDs = markerIDs
        calendarTerm = term
        return .noOp
    }

    func waitForEnabledActions() async {
        guard cloudSession == nil || reminderSession == nil else { return }
        await withCheckedContinuation { enableContinuation = $0 }
    }

    private func finishEnablingIfReady() {
        guard cloudSession != nil, reminderSession != nil else { return }
        enableContinuation?.resume()
        enableContinuation = nil
    }
}

@MainActor
final class SemesterStartDateService: ScheduleServicing {
    var firstDayString = "2026-09-07"
    var courses: [CourseRecord] = []

    func syncCourses(term: String?) async throws -> CourseSyncPayload {
        CourseSyncPayload(
            term: term ?? "2026-2027-1",
            firstDayString: firstDayString,
            sourceFirstDayString: firstDayString,
            normalizationOffset: 0,
            rawWeeksByCourse: courses.map(\.weeks),
            courses: courses,
            exams: []
        )
    }

    func fetchAvailableTerms() async throws -> [String] { throw ScheduleServiceError.invalidResponse }
    func fetchCurrentTermOnly() async throws -> String { throw ScheduleServiceError.invalidResponse }
    func prepareTeachingCenterAccess() async throws { throw ScheduleServiceError.invalidResponse }
    func fetchCampuses() async throws -> [CampusRecord] { throw ScheduleServiceError.invalidResponse }
    func fetchBuildings(campusCode: String?) async throws -> [BuildingRecord] { throw ScheduleServiceError.invalidResponse }
    func fetchClassrooms(buildingID: String, term: String) async throws -> [ClassroomRecord] { throw ScheduleServiceError.invalidResponse }
    func submitSMSCode(
        _ code: String, for challenge: BITLoginAuthenticationChallenge, term: String?
    ) async throws -> CourseSyncPayload { throw ScheduleServiceError.invalidResponse }
    func submitSMSCodeForTeachingCenterAuthentication(
        _ code: String, for challenge: BITLoginAuthenticationChallenge
    ) async throws { throw ScheduleServiceError.invalidResponse }
    func syncDDLEvents(
        existingEvents: [DDLEventRecord], storedURL: String, schoolSMSCodeHandler: SchoolSMSCodeHandler?
    ) async throws -> DDLSyncPayload { throw ScheduleServiceError.invalidResponse }
    func refreshLexueCalendarURL(schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws -> String {
        throw ScheduleServiceError.invalidResponse
    }
}

@MainActor
struct ScheduleModuleBoundaryTests {
    private func makeRepository(
        session: @escaping () -> AppStorageSession = { AppStorageSession(accountIdentifier: "schedule-boundary-tests") },
        load: @escaping (AppStorageSession) async -> ScheduleCacheLoadResult,
        save: @escaping (ScheduleCache, ScheduleCacheSaveSource, AppStorageSession) async throws -> Void
    ) -> ScheduleRepository {
        ScheduleRepository(session: session, load: load, save: save, cacheDidChange: Notification.Name("schedule-boundary-tests-cache-change"))
    }

    private func makeViewModel(
        service: any ScheduleServicing,
        repository: ScheduleRepository,
        platformActions: any SchedulePlatformActions = RecordingSchedulePlatformActions(),
        newCustomScheduleDraft: @escaping () -> CustomScheduleDraft = { CustomScheduleDraft() }
    ) -> ScheduleViewModel {
        ScheduleViewModel(
            service: service,
            repository: repository,
            ddl: ScheduleDDLViewModel(service: service, repository: repository),
            classroom: ScheduleClassroomViewModel(service: service, repository: repository),
            platformActions: platformActions,
            newCustomScheduleDraft: newCustomScheduleDraft
        )
    }

    @Test func semesterStartDatePreservesCoursesAcrossRefreshAndTermSwitch() async throws {
        let bundle = Bundle(for: ErrorReportAndSchedulePolicyTests.self)
        let fixtureURL = bundle.url(
            forResource: "schedule-service-response", withExtension: "json", subdirectory: "Fixtures"
        ) ?? bundle.url(forResource: "schedule-service-response", withExtension: "json")
        let fixture = try #require(fixtureURL)
        let courses = try JSONDecoder().decode(CourseResponse.self, from: Data(contentsOf: fixture)).courseRecords
        let service = SemesterStartDateService()
        service.courses = courses
        let repository = makeRepository(load: { _ in .missing }, save: { _, _, _ in })
        await repository.loadIfNeeded()
        let viewModel = makeViewModel(service: service, repository: repository)
        let term = "2026-2027-1"

        await viewModel.syncCourses(term: term)
        #expect(viewModel.persistenceSnapshot.firstDayString == "2026-09-07")
        #expect(viewModel.persistenceSnapshot.manualFirstDayStringsByTerm.isEmpty)
        #expect(viewModel.persistenceSnapshot.courses == courses)

        let chosenDate = try #require(ScheduleDateCodec.parseDate("2026-09-23"))
        viewModel.setSemesterStartDate(chosenDate)
        #expect(viewModel.persistenceSnapshot.firstDayString == "2026-09-21")
        #expect(viewModel.persistenceSnapshot.termSchedulesByTerm[term]?.firstDayString == "2026-09-07")
        #expect(viewModel.persistenceSnapshot.courses == courses)
        #expect(viewModel.selectedWeek == viewModel.resolvedAutomaticWeek())

        service.firstDayString = "2026-09-14"
        await viewModel.syncCourses(term: term)
        #expect(viewModel.persistenceSnapshot.firstDayString == "2026-09-21")
        #expect(viewModel.persistenceSnapshot.termSchedulesByTerm[term]?.firstDayString == "2026-09-14")
        #expect(viewModel.persistenceSnapshot.courses == courses)

        await viewModel.syncCourses(term: "2026-2027-2")
        #expect(viewModel.persistenceSnapshot.firstDayString == "2026-09-14")
        await viewModel.syncCourses(term: term)
        #expect(viewModel.persistenceSnapshot.firstDayString == "2026-09-21")

        viewModel.setSemesterStartDate(nil)
        #expect(viewModel.persistenceSnapshot.firstDayString == "2026-09-14")
        #expect(viewModel.persistenceSnapshot.manualFirstDayStringsByTerm.isEmpty)
        #expect(viewModel.persistenceSnapshot.courses == courses)
    }

    @Test func restorationMapsEveryLoginFailureIntoScheduleErrors() async {
        let errors: [LoginServiceError] = [
            .invalidSchoolLoginPage, .schoolLoginFailed, .invalidCredentials,
            .schoolSMSCodeInvalid("验证码错误"), .schoolSMSUnavailable("短信服务暂时繁忙"),
            .unableToRestoreSchoolSession, .invalidServerResponse,
            .keychainWriteFailed(-1), .keychainReadFailed(-1)
        ]
        for original in errors {
            let restorer = AppScheduleSchoolSessionRestorer(restore: { throw original })
            do {
                _ = try await restorer.restoreSchoolSessionIfNeeded()
                Issue.record("Expected a schedule restoration error")
            } catch let mapped as ScheduleServiceError {
                #expect(mapped.localizedDescription == original.localizedDescription)
                switch (original, mapped) {
                case (.schoolSMSCodeInvalid, .schoolSMSCodeInvalid),
                     (.schoolSMSUnavailable, .schoolSMSUnavailable):
                    break
                default:
                    if case .authenticationFailed = mapped { } else {
                        Issue.record("Expected a schedule authentication failure")
                    }
                }
            } catch {
                Issue.record("Expected the schedule error contract: \(error)")
            }
        }
    }

    @Test func restorationPreservesSecondFactorContextAndTransportCancellation() async throws {
        let baseURL = try #require(URL(string: "https://sso.bit.edu.cn/cas/"))
        let context = try #require(SchoolLoginHTMLParser.parseSecondFactorPage(
            html: #"<form action="/cas/login"><input id="login-page-flowkey" value="flow"><input id="user-object-id" value="user"><div id="secondSmsLoginForm">短信验证</div></form>"#,
            baseURL: baseURL
        ))
        let challenged = AppScheduleSchoolSessionRestorer(restore: { throw LoginServiceError.schoolSMSRequired(context) })
        do {
            _ = try await challenged.restoreSchoolSessionIfNeeded()
            Issue.record("Expected a second-factor context")
        } catch let error as SchoolSessionRestorationError {
            if case let .secondFactorRequired(mapped) = error {
                #expect(mapped.execution == context.execution)
                #expect(mapped.userObjectID == context.userObjectID)
                #expect(mapped.formAction == context.formAction)
            }
        }
        let cancelled = AppScheduleSchoolSessionRestorer(restore: { throw CancellationError() })
        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.restoreSchoolSessionIfNeeded()
        }
        let timedOut = AppScheduleSchoolSessionRestorer(restore: { throw URLError(.timedOut) })
        do {
            _ = try await timedOut.restoreSchoolSessionIfNeeded()
            Issue.record("Expected a transport timeout")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        }
    }

    @Test func scoreProjectionPreservesIdentityAndPresentationFields() {
        let course = CourseRecord(
            id: "summary-course", term: "2026-2027-1", name: "高等数学", teacher: "教师",
            classroom: "教学楼101", description: "课程备注", weeks: [1, 2, 3, 5],
            weekday: 1, startSection: 1, endSection: 2, campus: "良乡", number: "MATH",
            credit: 3.5, hour: 48, type: "必修", category: "基础", department: "学院"
        )
        let summary = ScoreCourseSummary(course: course)
        #expect(summary.id == course.id)
        #expect(summary.term == course.term)
        #expect(summary.name == course.name)
        #expect(summary.number == course.number)
        #expect(summary.creditText == "3.5")
        #expect(summary.scheduleText == "星期一 第1-2节")
        #expect(summary.weeksText == ScheduleWeekCodec.formatWeeks(course.weeks).replacingOccurrences(of: ",", with: "、"))
        #expect(summary.teacher == course.teacher)
        #expect(summary.classroom == course.classroom)
        #expect(summary.campus == course.campus)
        #expect(summary.type == course.type)
        #expect(summary.description == course.description)
        #expect(summary.hourText == "48")
    }


    @Test func mineDeletionUsesTheInjectedSession() async throws {
        let transport = RecordingCommunityDeletionTransport()
        let session = CommunitySession(
            httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: try #require(URL(string: "https://example.invalid")), credentials: { CommunityCredentials(identity: CommunitySessionIdentity(accountIdentifier: "test-account"), cookie: "module-cookie") }, refresh: { _ in }
        )
        let defaults = try #require(UserDefaults(suiteName: "BIT101ModulesTests.community"))
        let dependencies = AppCommunityDependencies(
            settings: AppSettingsStore(defaults: defaults, session: { AppStorageSession(accountIdentifier: "module-community") }),
            session: session,
            messages: GalleryMessageReadStore(
                defaults: defaults,
                session: { AppStorageSession(accountIdentifier: "module-community") }, notificationCenter: NotificationCenter()
            ),
            drafts: ComposerDraftStore(
                files: AppFileSystem.files, applicationSupport: URL(fileURLWithPath: "/module-community"),
                session: { AppStorageSession(accountIdentifier: "module-community") }
            )
        )
        try await dependencies.mine.deletePoster(42)
        let requests = transport.requests
        #expect(requests.count == 1)
        #expect(requests.first?.httpMethod == "DELETE")
        #expect(requests.first?.url?.host == "example.invalid")
        #expect(requests.first?.url?.path == "/posters/42")
    }

    @Test func mediaProjectionPreservesOriginalThumbnailAndSingleAddressImages() throws {
        let original = "https://example.com/original.png"
        let thumbnail = "https://example.com/thumbnail.png"
        let images = [
            CommunityImage(mid: "both", url: original, lowUrl: thumbnail),
            CommunityImage(mid: "original", url: original, lowUrl: ""),
            CommunityImage(mid: "thumbnail", url: "", lowUrl: thumbnail)
        ]
        let projected = images.map(\.previewImage)
        #expect(projected[0].originalURL == URL(string: original))
        #expect(projected[0].thumbnailURL == URL(string: thumbnail))
        #expect(projected[1].originalURL == projected[1].thumbnailURL)
        #expect(projected[2].originalURL == projected[2].thumbnailURL)
        let request = ImagePreviewRequest(remoteImages: projected, initialIndex: 2)
        #expect(request.initialIndex == 2)
    }
}

@MainActor
private final class RecordingCommunityDeletionTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (Data(), response)
    }
}
