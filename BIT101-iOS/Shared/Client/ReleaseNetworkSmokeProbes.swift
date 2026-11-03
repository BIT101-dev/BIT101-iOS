import ClientCore
import CommunityCore
import CourseFeature
import Foundation
import GalleryFeature
import MediaKit
import MineFeature
import PaperFeature
import ScheduleContracts
import ScheduleDomain
import ScheduleInfrastructure
import SchedulePorts
import ScoreDomain
import ScoreFeature
import ScoreInfrastructure
import ScorePorts
import TransportCore

#if DEBUG || RELEASE_NETWORK_SMOKE

nonisolated struct EmergencyUpdateSmokeEnvelope: Decodable {
    let schemaVersion: Int
    let enabled: Bool

    enum CodingKeys: String, CodingKey {
        case enabled
        case schemaVersion = "schema_version"
    }
}

extension ReleaseNetworkSmokeRunner {
    func finishReport(runID: String, scope: NetworkSmokeScope, startedAt: Date) async
        -> ReleaseNetworkSmokeReport
    {
        let missingSMSPurposes = scope.requiredSMSPurposes.subtracting(
            authenticatedSchoolProbes.map(\.purpose)
        )
        .union(Set(requestedSMSPurposes).subtracting(verifiedSMSProbes.map(\.purpose)))
        if schoolSMSHandler != nil {
            coverageGaps += missingSMSPurposes.sorted().map { "短信专项需要完成认证与业务继续：" + $0 }
        }
        for name in scope.requiredProbes where !executedProbes.contains(name) {
            if !coverageGaps.contains(where: { $0.hasPrefix(name + "（") }) {
                coverageGaps.append("必需探针缺失：" + name)
            }
        }

        let schoolSMSCoverage: String
        if schoolSMSHandler != nil {
            schoolSMSCoverage =
                missingSMSPurposes.isEmpty
                ? (smsSubmissions > 0 ? "verified" : "not_required") : "pending"
        } else {
            switch scope {
            case .all, .school, .ddl:
                schoolSMSCoverage = "preflight_only"
            default:
                schoolSMSCoverage = "not_run"
            }
        }
        var report = ReleaseNetworkSmokeReport(
            runID: runID,
            scope: scope,
            startedAt: startedAt,
            finishedAt: Date(),
            passed: failures.isEmpty && authenticationBlockers.isEmpty,
            failures: failures,
            authenticationBlockers: authenticationBlockers,
            scheduleCache: scheduleCache,
            executedProbes: executedProbes,
            skippedProbes: skippedProbes,
            coverageGaps: coverageGaps,
            schoolSMSCoverage: schoolSMSCoverage
        )
        report.eclassDDL = eclassDDL
        report.requiredProbes = scope.requiredProbes
        report.verifiedSMSProbes = verifiedSMSProbes
        report.authenticatedSchoolProbes = authenticatedSchoolProbes
        report.requestedSMSPurposes = requestedSMSPurposes
        report.communityWriteEvidence = communityWriteEvidence
        report.productionSessionEvidence = productionSessionEvidence
        report.requestedTerm = requestedScheduleTerm
        report.currentTerm = currentScheduleTerm
        report.validatedTerm = validatedScheduleTerm
        report.requestEvidence = requestEvidence
        report.diagnostics = await NetworkDiagnosticStore.shared.recent().map { record in
            NetworkDiagnosticRecord(
                id: record.id, occurredAt: record.occurredAt, method: record.method,
                url: ErrorReportRedactor.sanitized(record.url), statusCode: record.statusCode,
                elapsedMilliseconds: record.elapsedMilliseconds,
                error: record.error.map(ErrorReportRedactor.sanitized),
                responseHeaders: ErrorReportRedactor.redactHeaders(record.responseHeaders),
                responseBody: record.responseBody.map(ErrorReportRedactor.sanitized),
                finalURL: record.finalURL.map(ErrorReportRedactor.sanitized),
                finalMethod: record.finalMethod)
        }
        report.exemptedProbes = scope.exemptedProbes
        report.requestEvidenceRequired = dependencies.requiresRequestEvidence
        return ReleaseNetworkSmokeReportStore.complete(report, writer: dependencies.writeReport)
    }

    func captureScheduleCache(from payload: CourseSyncPayload)
        -> ScheduleCacheAuditSnapshot
    {
        let courses = payload.courses.map {
            ScheduleCacheAuditCourse(
                id: $0.id,
                name: $0.name,
                number: $0.number,
                teacher: $0.teacher,
                classroom: $0.classroom,
                weeks: $0.weeks,
                weekday: $0.weekday,
                startSection: $0.startSection,
                endSection: $0.endSection
            )
        }
        return ScheduleCacheAuditSnapshot(
            currentTerm: payload.term,
            firstDayString: payload.firstDayString,
            sourceFirstDayString: payload.sourceFirstDayString,
            normalizationOffset: payload.normalizationOffset,
            courseCount: courses.count,
            courses: courses
        )
    }

    static func freshEclassService() throws -> ScheduleService {
        freshSchoolService(rawCourseResponseHandler: nil)
    }

    static func freshScoreService() -> ScoreService {
        let state = AppSchoolSession.isolatedState()
        return ScoreService(
            authenticationHTTPClient: HTTPClient(
                transport: NetworkSessionPool.scoreAuthTransport(
                    state: state, productionPolicy: true)),
            nativeAuthenticator: AppNativeSchoolAuthentication.make(
                state: state, productionPolicy: true),
            schoolHTTPClient: HTTPClient(
                transport: NetworkSessionPool.schoolCASTransport(
                    state: state, followsRedirects: true, productionPolicy: true)))
    }

    static func freshSchoolService(rawCourseResponseHandler: ((Data) -> Void)?)
        -> ScheduleService
    {
        let state = AppSchoolSession.isolatedState()
        let api = BIT101APIClient(
            httpClient: HTTPClient(
                transport: NetworkSessionPool.schoolCASTransport(
                    state: state, followsRedirects: true, productionPolicy: true)),
            noRedirectHTTPClient: HTTPClient(
                transport: NetworkSessionPool.schoolCASTransport(
                    state: state, followsRedirects: false, productionPolicy: true)))
        let restorer = AppScheduleSchoolSessionRestorer {
            try await LoginService(storage: AppAccountSession.storage, apiClient: api)
                .restoreSchoolSession()
        }
        return ScheduleService(
            credentials: AppAccountSession.storage, crypto: AppScheduleServiceCrypto(),
            schoolSessionRestorer: restorer, teachingCenterState: state,
            rawCourseResponseHandler: rawCourseResponseHandler,
            transport: NetworkSessionPool.teachingCenter(state: state, productionPolicy: true),
            observer: HTTPClient.appObserver,
            nativeAuthenticator: AppNativeSchoolAuthentication.make(
                state: state, productionPolicy: true))
    }

    func probe<Value>(
        _ kind: NetworkSmokeProbe,
        area: NetworkSmokeArea,
        scope: NetworkSmokeScope,
        expectedParameters: [String: String] = [:],
        operation: () async throws -> Value
    ) async -> Value? {
        guard scope.includes(area), area.probeKinds.contains(kind) else { return nil }
        let name = kind.rawValue
        guard
            communitySessionAvailable || scope == .communityCleanup
                || !kind.requiresCommunitySession
        else {
            recordSkip(name, "社区登录探针已失败", area: area, scope: scope)
            return nil
        }
        executedProbes.append(name)
        emit("NETWORK_SMOKE_START name=\(name) label=\(kind.displayName)")
        let startedAt = Date()
        let smsStart = submittedSMSPurposes.count
        do {
            let value = try await captureNetworkRequests(
                name, required: scope != .communityCleanup,
                expectedParameters: expectedParameters
            ) {
                try await self.withSchoolAuth(operation)
            }
            verifiedSMSProbes += submittedSMSPurposes.dropFirst(smsStart).map {
                SchoolSMSProbeEvidence(purpose: $0, probe: name)
            }
            let canonicalPurposes = [
                "schedule.current-term": "webvpn", "school.session": "webvpn",
                "lexue.calendar": "webvpn",
                "eclass.authentication": "school_sso_second_factor",
                "score.authentication": "jwb", "score.transcript": "jwb_cjd",
            ]
            let purposes = Set(submittedSMSPurposes.dropFirst(smsStart)).union(
                canonicalPurposes[name].map { [$0] } ?? [])
            for purpose in purposes
            where !authenticatedSchoolProbes.contains(where: { $0.purpose == purpose }) {
                authenticatedSchoolProbes.append(
                    SchoolSMSProbeEvidence(purpose: purpose, probe: name))
            }
            emit(
                """
                NETWORK_SMOKE_PASS name=\(name) label=\(kind.displayName) elapsed=\
                \(Self.duration(Date().timeIntervalSince(startedAt)))
                """
            )
            return value
        } catch {
            let elapsed = Date().timeIntervalSince(startedAt)
            if error is NetworkSmokePaging.SamplingError {
                recordSkip(name, error.localizedDescription, area: area, scope: scope)
            } else if Self.isAuthenticationBlocked(error) {
                recordAuthBlocker(
                    name, error.localizedDescription, area: area, scope: scope, elapsed: elapsed
                )
            } else {
                recordFailure(
                    name, error.localizedDescription, area: area, scope: scope, elapsed: elapsed
                )
            }
            return nil
        }
    }

    func withSchoolAuth<Value>(_ operation: () async throws -> Value) async throws
        -> Value
    {
        do { return try await operation() } catch ScheduleServiceError.secondFactorRequired(
            let challenge)
        {
            guard !challenge.isCaptcha, let handler = schoolSMSHandler,
                let schedule = schoolSMSSchedule
            else {
                throw ScheduleServiceError.secondFactorRequired(challenge)
            }
            let code = try await handler(
                SchoolSMSCodeRequest(
                    maskedPhone: challenge.maskedPhone ?? "", purpose: "webvpn"))
            try await schedule.submitTeachingCode(code, for: challenge)
            return try await operation()
        }
    }

    func captureNetworkRequests<Value>(
        _ name: String, required: Bool, expectedParameters: [String: String] = [:],
        operation: () async throws -> Value
    ) async throws -> Value {
        let collector = NetworkSmokeRequestCollector()
        defer {
            requestEvidence.append(
                NetworkSmokeRequestEvidence(
                    probe: name, requests: collector.requests,
                    expectedParameters: expectedParameters))
        }
        return try await collector.perform(
            operation, required: required && dependencies.requiresRequestEvidence,
            expectedParameters: expectedParameters)
    }

    func recordFailure(
        _ name: String,
        _ message: String,
        area: NetworkSmokeArea,
        scope: NetworkSmokeScope,
        elapsed: TimeInterval? = nil
    ) {
        guard scope.includes(area) else { return }
        let timing = elapsed.map { " elapsed=\(Self.duration($0))" } ?? ""
        let line = "[\(name)] \(ErrorReportRedactor.sanitized(message))\(timing)"
        failures.append(line)
        emit("NETWORK_SMOKE_FAIL \(line)")
    }

    func recordSkip(
        _ name: String,
        _ reason: String,
        area: NetworkSmokeArea,
        scope: NetworkSmokeScope
    ) {
        guard scope.includes(area) else { return }
        let entry = "\(name)（\(reason)）"
        skippedProbes.append(entry)
        coverageGaps.append(entry)
        emit("NETWORK_SMOKE_SKIP name=\(name) reason=\(reason) scope=\(scope.rawValue)")
    }

    func recordAuthBlocker(
        _ name: String,
        _ message: String,
        area: NetworkSmokeArea,
        scope: NetworkSmokeScope,
        elapsed: TimeInterval
    ) {
        guard scope.includes(area) else { return }
        let line =
            """
            [\(name)] \(ErrorReportRedactor.sanitized(message)) elapsed=\
            \(Self.duration(elapsed))
            """
        authenticationBlockers.append(line)
        emit("NETWORK_SMOKE_AUTH_BLOCKED \(line)")
    }

    func runInParallel(_ operations: [@MainActor () async -> Void]) async {
        await withTaskGroup(of: Void.self) { group in
            for operation in operations {
                group.addTask {
                    await operation()
                }
            }
        }
    }

    nonisolated static func isAuthenticationBlocked(_ error: Error) -> Bool {
        switch error {
        case ScheduleServiceError.secondFactorRequired,
            ScheduleServiceError.eclassAuthenticationFailed,
            ScheduleServiceError.schoolSecondFactorRequired,
            ScoreServiceError.secondFactorRequired:
            return true
        default:
            return false
        }
    }

    func fetchImageCount(urlString: String) async throws -> Int {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        return try await dependencies.imageProbe(url)
    }

    nonisolated static func validateImageData(_ data: Data) throws {
        guard BoundedStillImageDecoder.image(from: data) != nil
        else {
            throw URLError(.cannotDecodeContentData)
        }
    }

    func fetchHTMLCount(
        urlString: String,
        expectedHost: String,
        initialHost: String? = nil
    ) async throws -> Int {
        guard let url = URL(string: urlString),
            url.host?.lowercased() == (initialHost ?? expectedHost).lowercased()
        else {
            throw URLError(.badURL)
        }
        let response = try await fetchResponse(url)
        return try Self.validateHTMLResponse(
            response.data,
            finalURL: response.response.url,
            expectedHost: expectedHost,
            expectedPath: initialHost == nil ? url.path : "/gallery/",
            expectedAppURL: expectedHost == "open.aihelpme.dev" ? "bit101:/" + url.path : nil
        )
    }

    nonisolated static func validateHTMLResponse(
        _ data: Data,
        finalURL: URL?,
        expectedHost: String,
        expectedPath: String? = nil,
        expectedAppURL: String? = nil
    ) throws -> Int {
        guard finalURL?.host?.lowercased() == expectedHost else {
            throw URLError(.badServerResponse)
        }
        if let expectedPath,
            finalURL?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                != expectedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        {
            throw URLError(.badServerResponse)
        }
        try NetworkSmokeHTML.validate(
            String(decoding: data, as: UTF8.self), appURL: expectedAppURL)
        return data.count
    }

    nonisolated static let aasaURL = AppURL.required(
        "https://open.aihelpme.dev/.well-known/apple-app-site-association")

    nonisolated static func validateAASA(_ response: HTTPResponse) throws -> Int {
        guard response.statusCode == 200, response.response.url == aasaURL,
            response.response.mimeType?.lowercased() == "application/json",
            response.data.count <= 128 * 1024,
            let root = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
            let appLinks = root["applinks"] as? [String: Any],
            let details = appLinks["details"] as? [[String: Any]],
            let entry = details.first(where: {
                $0["appID"] as? String == "Y2T72736G3.BIT101-dev.BIT101-iOS"
            }),
            let paths = entry["paths"] as? [String],
            paths.count == 3, Set(paths) == Set(["/gallery/*", "/course/*", "/paper/*"])
        else { throw URLError(.cannotParseResponse) }
        return paths.count
    }

    nonisolated static func validateAppStoreLookup(_ data: Data) throws -> Int {
        try AppStoreLookup.parse(data).count
    }

    nonisolated static func validateEmergencyUpdate(_ data: Data) throws -> Bool {
        let envelope = try JSONDecoder().decode(EmergencyUpdateSmokeEnvelope.self, from: data)
        guard envelope.schemaVersion == 1 else { throw URLError(.cannotParseResponse) }
        guard envelope.enabled else { return false }

        let notice = try JSONDecoder().decode(EmergencyUpdateNotice.self, from: data)
        guard !notice.noticeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !notice.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !notice.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw URLError(.cannotParseResponse)
        }
        return true
    }

    nonisolated static func validateTranscriptPages(_ pages: [Data]) throws -> Int {
        guard !pages.isEmpty else { throw URLError(.zeroByteResource) }
        for page in pages {
            try Self.validateImageData(page)
        }
        return pages.count
    }

    func fetchAppStoreLookup() async throws -> Int {
        let request = try AppStoreLookup.makeRequest()
        let response = try await dependencies.externalHTTPClient.send(request)
        guard AppURL.isSameOrigin(response.response.url, as: request.url) else {
            throw URLError(.badServerResponse)
        }
        return try Self.validateAppStoreLookup(response.data)
    }

    func fetchEmergencyUpdate() async throws -> Bool {
        let url = AppURL.required("https://update.aihelpme.dev/emergency-update.json")
        let response = try await fetchResponse(url)
        guard AppURL.isSameOrigin(response.response.url, as: url) else {
            throw URLError(.badServerResponse)
        }
        return try Self.validateEmergencyUpdate(response.data)
    }

    func fetch(_ url: URL) async throws -> Data {
        try await fetchResponse(url).data
    }

    func fetchResponse(_ url: URL, maximumBytes: Int? = nil) async throws
        -> HTTPResponse
    {
        var request = URLRequest(
            url: HTTPSURLUpgrade.upgradedURL(from: url),
            cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("BIT101-iOS release network smoke", forHTTPHeaderField: "User-Agent")
        let response = try await self.dependencies.externalHTTPClient.send(
            request, accepting: 200..<300, maximumBytes: maximumBytes)
        guard !response.data.isEmpty else { throw URLError(.zeroByteResource) }
        return response
    }

    static func failureArea(for scope: NetworkSmokeScope) -> NetworkSmokeArea {
        if scope.includes(.authentication) { return .authentication }
        if scope.includes(.schedule) { return .schedule }
        if scope.includes(.ddl) { return .ddl }
        return .transcript
    }

    func fetchAllImages(urls: [String]) async throws {
        for value in urls {
            _ = try await self.fetchImageCount(urlString: value)
        }
    }

    func verifyGalleryImages(_ images: [String]) async throws {
        guard !images.isEmpty else { throw URLError(.resourceUnavailable) }
        for url in images {
            _ = try await self.fetchImageCount(urlString: url)
        }
    }

    func fetchAllComments(
        gallery: any NetworkSmokeGalleryServicing, objectID: String
    ) async throws {
        for order in CommunityCommentOrder.allCases {
            _ = try await NetworkSmokePaging.commentBatch(
                for: objectID, order: order,
                currentIdentity: self.dependencies.communityIdentity
            ) {
                let page = $0 == 0 ? nil : $0
                return try await gallery.fetchComments(
                    objectID: objectID, order: order, page: page
                )
            }
        }
    }

    func fetchCourseComments(
        courses: any NetworkSmokeCourseServicing, courseID: Int, objectID: String
    ) async throws {
        _ = try await NetworkSmokePaging.commentPage(
            for: objectID, order: .newest,
            currentIdentity: self.dependencies.communityIdentity
        ) {
            let page = $0 == 0 ? nil : $0
            return try await courses.fetchComments(
                courseID: courseID, page: page
            )
        }
    }

    func searchPaperPage(
        papers: any NetworkSmokePaperServicing, paperID: Int, keyword: String
    ) async throws -> [PaperSummary] {
        guard !keyword.isEmpty else { throw URLError(.cannotParseResponse) }
        return try await NetworkSmokePaging.searchPage(
            matching: paperID, keyword: keyword,
            currentIdentity: self.dependencies.communityIdentity
        ) { text, page in
            let result = try await papers.fetchPapers(
                search: text, order: .newest, page: page
            )
            try NetworkSmokePaging.checkPapers(result, order: .newest)
            return result
        }
    }

    func fetchAllPaperComments(
        papers: any NetworkSmokePaperServicing, paperID: Int, objectID: String
    ) async throws {
        for order in CommunityCommentOrder.allCases {
            _ = try await NetworkSmokePaging.commentPage(
                for: objectID, order: order,
                currentIdentity: self.dependencies.communityIdentity
            ) {
                let page = $0 == 0 ? nil : $0
                return try await papers.fetchComments(
                    paperID: paperID, order: order,
                    page: page
                )
            }
        }
    }

    func fetchAndVerifyClassrooms(
        schedule: any NetworkSmokeScheduleServicing,
        buildingID: String,
        term: String,
        queryDate: Date
    ) async throws -> [ClassroomRecord] {
        let classrooms = try await schedule.fetchClassrooms(
            buildingID: buildingID, term: term, date: queryDate
        )
        guard
            let prefetched = try await schedule.prefetchClassrooms(
                buildingID: buildingID, term: term, date: queryDate
            ),
            classrooms.allSatisfy(\.hasValidOccupancy),
            prefetched.allSatisfy(\.hasValidOccupancy)
        else { throw URLError(.cannotParseResponse) }
        return classrooms
    }

    nonisolated static func duration(_ interval: TimeInterval) -> String {
        String(format: "%.2fs", interval)
    }
}

#endif
