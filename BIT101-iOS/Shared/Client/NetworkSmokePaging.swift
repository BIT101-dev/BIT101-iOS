import Foundation
import TransportCore
import CommunityCore
import CommunityTransport
import GalleryFeature
import PaperFeature
import CourseFeature
import ScoreDomain
import ScheduleDomain
import ScheduleContracts
import ScheduleInfrastructure

#if DEBUG || RELEASE_NETWORK_SMOKE
@MainActor
enum NetworkSmokePaging {
    static let maximumSamplePages = 100
    static let maximumSampleItems = 4_096
    nonisolated enum SamplingError: LocalizedError {
        case budgetExceeded
        case insufficientSample(String)
        var errorDescription: String? {
            switch self {
            case .budgetExceeded: "维护样本扫描达到预算，请核对维护样本身份与所在页。"
            case let .insufficientSample(message): message
            }
        }
    }
    static func checkSampleBudget(page: Int, items: Int) throws {
        guard page < maximumSamplePages, items <= maximumSampleItems else { throw SamplingError.budgetExceeded }
    }
    static func checkedReportTypes(_ types: [GalleryReportType]) throws -> [GalleryReportType] {
        guard !types.isEmpty, Set(types.map(\.id)).count == types.count,
              types.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw URLError(.cannotParseResponse) }
        return types
    }

    nonisolated static func validateEntityIdentity(expected: Int, actual: Int) throws {
        guard expected > 0, actual == expected else { throw URLError(.badServerResponse) }
    }

    static func checkBuildings(_ buildings: [BuildingRecord], campusCode: String) throws {
        guard !campusCode.isEmpty, buildings.allSatisfy({ $0.campusCode == campusCode })
        else { throw URLError(.badServerResponse) }
    }

    static func checkPaperContent(_ raw: String) throws -> [String] {
        let blocks = PaperContentRenderer.blocks(from: raw)
        guard !blocks.isEmpty else { throw URLError(.cannotParseResponse) }
        var images: [String] = []
        var readable = false
        for block in blocks {
            switch block {
            case .requiresOriginal: throw URLError(.cannotParseResponse)
            case let .image(_, image):
                let urls = imageURLs(in: [image.asCommunityImage])
                guard !urls.isEmpty else { throw URLError(.cannotParseResponse) }
                images.append(contentsOf: urls)
            case let .header(_, text, _), let .paragraph(_, text), let .quote(_, text, _):
                readable = readable || !String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case let .list(_, items, _):
                readable = readable || items.contains { !String($0.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }
        }
        guard readable, !images.isEmpty else { throw URLError(.cannotParseResponse) }
        return Array(Set(images)).sorted()
    }

    static func imageURLs(in images: [CommunityImage]) -> [String] {
        Array(Set(images.flatMap { [$0.lowUrl, $0.url] }.filter { !$0.isEmpty })).sorted()
    }

    static func imageResourceParameters(_ urls: [String]) -> [String: String] {
        ["resourceDigests": urls.compactMap { URL(string: $0) }.map(HTTPRequestEvidence.urlDigest).sorted().joined(separator: ",")]
    }

    static func arrayPage<Value: Identifiable>(requiresContent: Bool = false, matchingID: Int? = nil, currentIdentity: () -> CommunitySessionIdentity, load: (Int) async throws -> [Value]) async throws -> [Value] where Value.ID == Int {
        let identity = currentIdentity()
        let first = try await load(0)
        guard !requiresContent || !first.isEmpty else { throw URLError(.cannotParseResponse) }
        try checkIdentity(identity, current: currentIdentity())
        try checkIDs(first.map(\.id))
        try checkSampleBudget(page: 0, items: first.count)
        var sampled = CommunityPagedItems<Value>()
        sampled.replace(with: first)
        var progress = CommunityPageProgress<Int>(knownIDs: sampled.ids)
        var page = 1
        while true {
            try checkSampleBudget(page: page, items: sampled.ids.count)
            let next = try await load(page)
            try checkIdentity(identity, current: currentIdentity())
            let ids = next.map(\.id)
            try checkIDs(ids)
            guard !first.isEmpty || next.isEmpty else { throw URLError(.badServerResponse) }
            try progress.record(ids)
            let added = Set(ids).subtracting(sampled.ids)
            try checkSampleBudget(page: page, items: sampled.ids.count + added.count)
            let advances = !added.isEmpty
            sampled.append(next)
            if ids.isEmpty || advances && (matchingID.map { sampled.ids.contains($0) } ?? true) { return sampled.items }
            page += 1
        }
    }

    static let excludedSearchText = "bit101smokeexclusioncontrolqzxjkv"

    static func searchPage<Value: Identifiable>(matching id: Int, keyword: String, currentIdentity: () -> CommunitySessionIdentity,
                           load: (String, Int) async throws -> [Value]) async throws -> [Value] where Value.ID == Int {
        let result = try await arrayPage(requiresContent: true, matchingID: id, currentIdentity: currentIdentity) { try await load(keyword, $0) }
        guard result.contains(where: { $0.id == id }) else { throw URLError(.badServerResponse) }
        let excluded = try await arrayPage(matchingID: id, currentIdentity: currentIdentity) { try await load(excludedSearchText, $0) }
        guard !excluded.contains(where: { $0.id == id }) else { throw URLError(.badServerResponse) }
        return result
    }

    static func posterSearch(matching id: Int, keyword: String, currentIdentity: () -> CommunitySessionIdentity,
                             load: (GallerySearchOrder, String, Int) async throws -> GalleryPageBatch<CommunityPoster>) async throws {
        guard id > 0, !keyword.isEmpty else { throw SamplingError.insufficientSample("帖子搜索验收需要维护对象及关键词。") }
        for order in GallerySearchOrder.allCases {
            let result = try await batch(matchingID: id, currentIdentity: currentIdentity) { try await load(order, keyword, $0) }
            guard result.items.contains(where: { $0.id == id }) else { throw URLError(.badServerResponse) }
            let excluded = try await batch(matchingID: id, currentIdentity: currentIdentity) { try await load(order, excludedSearchText, $0) }
            guard !excluded.items.contains(where: { $0.id == id }) else { throw URLError(.badServerResponse) }
        }
        for order in [GallerySearchOrder.like, .newest] {
            _ = try await posterPage(order: order, requiresOrderingEvidence: true, currentIdentity: currentIdentity) { try await load(order, "", $0) }
        }
    }

    static func paperPage(order: PaperSortOrder, requiresContent: Bool = false, requiresOrderingEvidence: Bool = false, currentIdentity: () -> CommunitySessionIdentity,
                          load: (Int) async throws -> [PaperSummary]) async throws -> [PaperSummary] {
        var hasOrderingSample = false
        let sampled = try await arrayPage(requiresContent: requiresContent, currentIdentity: currentIdentity) { page in
            let papers = try await load(page)
            try checkPapers(papers, order: order)
            switch order {
            case .like: hasOrderingSample = hasOrderingSample || Set(papers.map(\.likeNum)).count > 1
            case .comment: hasOrderingSample = hasOrderingSample || Set(papers.map(\.commentNum)).count > 1
            case .newest: hasOrderingSample = hasOrderingSample || Set(papers.compactMap { AppDateText.date(from: $0.updateTime) }).count > 1
            }
            return papers
        }
        guard !requiresOrderingEvidence || hasOrderingSample else {
            throw SamplingError.insufficientSample("排序验收需要同一响应中至少两项排序值不同的样本，请维护验收数据。")
        }
        return sampled
    }

    static func commentPage(for objectID: String, order: CommunityCommentOrder,
                            currentIdentity: () -> CommunitySessionIdentity,
                            load: (Int) async throws -> [CommunityComment]) async throws -> [CommunityComment] {
        var hasOrderingSample = false
        let result = try await arrayPage(currentIdentity: currentIdentity) { page in
            let comments = try await load(page)
            try checkComments(comments, for: objectID, order: order)
            hasOrderingSample = hasOrderingSample || commentsHaveOrderingSample(comments, order: order)
            return comments
        }
        try requireCommentOrderingSample(hasOrderingSample)
        if order != .like { try checkComments(result, for: objectID, order: order) }
        return result
    }

    static func commentBatch(for objectID: String, order: CommunityCommentOrder,
                             currentIdentity: () -> CommunitySessionIdentity,
                             load: (Int) async throws -> GalleryPageBatch<CommunityComment>) async throws -> GalleryPageBatch<CommunityComment> {
        var hasOrderingSample = false
        let result = try await batch(currentIdentity: currentIdentity) { page in
            let result = try await load(page)
            try checkComments(result.items, for: objectID, order: order)
            hasOrderingSample = hasOrderingSample || commentsHaveOrderingSample(result.items, order: order)
            return result
        }
        try requireCommentOrderingSample(hasOrderingSample)
        if order != .like { try checkComments(result.items, for: objectID, order: order) }
        return result
    }

    private static func commentsHaveOrderingSample(_ comments: [CommunityComment], order: CommunityCommentOrder) -> Bool {
        order == .like ? Set(comments.map(\.likeNum)).count > 1
            : Set(comments.compactMap { AppDateText.date(from: $0.createTime) }).count > 1
    }

    private static func requireCommentOrderingSample(_ hasSample: Bool) throws {
        guard hasSample else {
            throw SamplingError.insufficientSample("评论排序验收需要同一响应中至少两项排序值不同的样本，请维护验收数据。")
        }
    }

    static func posterPage(order: GallerySearchOrder, requiresOrderingEvidence: Bool = false,
                           currentIdentity: () -> CommunitySessionIdentity,
                           load: (Int) async throws -> GalleryPageBatch<CommunityPoster>) async throws -> GalleryPageBatch<CommunityPoster> {
        var hasOrderingSample = false
        let sampled = try await batch(currentIdentity: currentIdentity) { page in
            let result = try await load(page)
            hasOrderingSample = try checkPosterOrder(result.items, order: order) || hasOrderingSample
            return result
        }
        guard !requiresOrderingEvidence || hasOrderingSample else {
            throw SamplingError.insufficientSample("帖子排序验收需要同一响应中排序值不同的样本，请维护验收数据。")
        }
        if order == .newest { _ = try checkPosterOrder(sampled.items, order: order) }
        return sampled
    }

    private static func checkPosterOrder(_ posters: [CommunityPoster], order: GallerySearchOrder) throws -> Bool {
        if order == .like {
            guard zip(posters, posters.dropFirst()).allSatisfy({ $0.likeNum >= $1.likeNum }) else {
                throw URLError(.badServerResponse)
            }
            return Set(posters.map(\.likeNum)).count > 1
        } else if order == .newest {
            let dates = try posters.map { poster in
                guard let date = AppDateText.date(from: poster.createTime) else { throw URLError(.badServerResponse) }
                return date
            }
            guard zip(dates, dates.dropFirst()).allSatisfy({ $0 >= $1 }) else { throw URLError(.badServerResponse) }
            return Set(dates).count > 1
        }
        return false
    }

    static func checkCourseHistories(_ grades: [CourseHistoryGrade]) throws {
        guard grades.allSatisfy(\.hasValidStatistics), Set(grades.map(\.term)).count == grades.count else {
            throw URLError(.badServerResponse)
        }
        guard grades.contains(where: { ($0.avgScore != nil || $0.maxScore != nil) && ($0.studentNum ?? 0) > 0 }) else {
            throw SamplingError.insufficientSample("课程历史验收需要包含成绩与人数的学期样本，请维护验收数据。")
        }
    }

    static func checkScores(brief: [ScoreRow], detailed: [ScoreRow]) throws {
        guard !brief.isEmpty || !detailed.isEmpty else {
            throw SamplingError.insufficientSample("成绩验收需要包含课程与成绩的账号样本，请维护验收数据。")
        }
        guard (brief + detailed).allSatisfy({ $0.hasValidCourseIdentity && ScoreRow.requiredHeaderNames.isSubset(of: Set($0.values.map(\.key))) })
        else { throw URLError(.cannotParseResponse) }
        guard ScoreRowComparison.briefRowsMatchCache(brief, cachedRows: detailed)
        else { throw URLError(.cannotParseResponse) }
    }

    static func batch<Value: Identifiable>(matchingID: Int? = nil, currentIdentity: () -> CommunitySessionIdentity, load: (Int) async throws -> GalleryPageBatch<Value>) async throws -> GalleryPageBatch<Value> where Value.ID == Int {
        let identity = currentIdentity()
        let first = try await load(0)
        try checkIdentity(identity, current: currentIdentity())
        try checkIDs(first.items.map(\.id))
        guard first.sourceIDs.allSatisfy({ $0 > 0 }), first.nextSourcePage > 0, !first.canLoadMore || !first.sourceIDs.isEmpty
        else { throw URLError(.cannotParseResponse) }
        var sampled = CommunityPagedItems<Value>()
        sampled.replace(with: first.items)
        var sourceIDs = Set(first.sourceIDs)
        var progress = CommunityPageProgress<Int>(knownIDs: sourceIDs)
        var page = first.nextSourcePage
        try checkSampleBudget(page: 0, items: sourceIDs.count)
        while true {
            try checkSampleBudget(page: page, items: sourceIDs.count)
            let next = try await load(page)
            try checkIdentity(identity, current: currentIdentity())
            try checkIDs(next.items.map(\.id))
            guard next.sourceIDs.allSatisfy({ $0 > 0 }), next.nextSourcePage > page, !next.canLoadMore || !next.sourceIDs.isEmpty
            else { throw URLError(.cannotParseResponse) }
            guard !first.sourceIDs.isEmpty || next.sourceIDs.isEmpty else { throw URLError(.badServerResponse) }
            try progress.record(next.sourceIDs)
            let advances = !Set(next.sourceIDs).subtracting(sourceIDs).isEmpty
            sampled.append(next.items)
            sourceIDs.formUnion(next.sourceIDs)
            try checkSampleBudget(page: page, items: sourceIDs.count)
            if !next.canLoadMore || advances && (matchingID.map { sampled.ids.contains($0) } ?? true) {
                return .init(items: sampled.items, nextSourcePage: next.nextSourcePage,
                    canLoadMore: next.canLoadMore, sourceIDs: sourceIDs.sorted())
            }
            page = next.nextSourcePage
        }
    }

    static func messages(currentIdentity: () -> CommunitySessionIdentity, load: (Int?) async throws -> [GalleryMessage]) async throws -> [GalleryMessage] {
        let identity = currentIdentity()
        let first = try await load(Int.max)
        try checkIdentity(identity, current: currentIdentity())
        guard first.allSatisfy({ $0.id > 0 }),
              zip(first, first.dropFirst()).allSatisfy({ $0.id > $1.id }) else { throw URLError(.cannotParseResponse) }
        guard let cursor = first.last?.id else {
            throw SamplingError.insufficientSample("消息分页验收需要专用账号中至少一条消息，请维护验收数据。")
        }
        guard cursor > 0 else { throw URLError(.cannotParseResponse) }
        let second = try await load(cursor)
        try checkIdentity(identity, current: currentIdentity())
        guard !second.isEmpty else {
            throw SamplingError.insufficientSample("消息分页验收需要跨两页的历史消息，请维护专用账号数据。")
        }
        guard second.allSatisfy({ $0.id > 0 && $0.id < cursor }),
              zip(second, second.dropFirst()).allSatisfy({ $0.id > $1.id }) else { throw URLError(.cannotParseResponse) }
        return first
    }

    private static func checkIdentity(_ identity: CommunitySessionIdentity, current: CommunitySessionIdentity) throws {
        try Task.checkCancellation()
        guard identity == current else { throw CancellationError() }
    }

    private static func checkIDs(_ ids: [Int]) throws {
        guard ids.allSatisfy({ $0 > 0 }), Set(ids).count == ids.count
        else { throw URLError(.badServerResponse) }
    }

    static func checkComments(_ comments: [CommunityComment], for objectID: String, order: CommunityCommentOrder? = nil) throws {
        guard CommunityComment.validatesResponse(comments, for: objectID) else { throw URLError(.badServerResponse) }
        guard let order else { return }
        let sorted: Bool
        if order == .like {
            sorted = zip(comments, comments.dropFirst()).allSatisfy { $0.likeNum >= $1.likeNum }
        } else {
            let dates = try comments.map { comment in
                guard let date = AppDateText.date(from: comment.createTime) else { throw URLError(.badServerResponse) }
                return date
            }
            sorted = zip(dates, dates.dropFirst()).allSatisfy { order == .newest ? $0 >= $1 : $0 <= $1 }
        }
        guard sorted else { throw URLError(.badServerResponse) }
    }

    static func checkPosters(_ posters: [CommunityPoster], for userID: Int) throws {
        guard userID > 0, posters.allSatisfy({ $0.user.id == userID }) else { throw URLError(.badServerResponse) }
    }

    static func checkBotPosters(_ posters: [CommunityPoster]) throws {
        guard posters.allSatisfy({ GalleryBotClassifier.matches(tags: $0.tags) })
        else { throw URLError(.badServerResponse) }
    }

    static func checkPapers(_ papers: [PaperSummary], order: PaperSortOrder) throws {
        let sorted: Bool
        switch order {
        case .like: sorted = zip(papers, papers.dropFirst()).allSatisfy { $0.likeNum >= $1.likeNum }
        case .comment: sorted = zip(papers, papers.dropFirst()).allSatisfy { $0.commentNum >= $1.commentNum }
        case .newest:
            let dates = try papers.map { paper in
                guard let date = AppDateText.date(from: paper.updateTime) else { throw URLError(.badServerResponse) }
                return date
            }
            sorted = zip(dates, dates.dropFirst()).allSatisfy { $0 >= $1 }
        }
        guard sorted else { throw URLError(.badServerResponse) }
    }
}
#endif

#if DEBUG || RELEASE_NETWORK_SMOKE
extension ReleaseNetworkSmokeRunner {
    nonisolated static func validateCourseSyncPayload(_ payload: CourseSyncPayload) throws {
        guard payload.courses.allSatisfy({ $0.hasValidPlacement
            && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.id.isEmpty }),
              Set(payload.courses.map(\.id)).count == payload.courses.count,
              payload.exams.allSatisfy(\.hasValidPlacement)
        else { throw URLError(.cannotParseResponse) }
        guard payload.rawWeeksByCourse.count == payload.courses.count,
              payload.sourceDisplayWeeksByCourse.count == payload.courses.count else { throw URLError(.cannotParseResponse) }
        for (index, course) in payload.courses.enumerated() {
            let raw = payload.rawWeeksByCourse[index]
            let sourceDisplay = SmallTermWeekNormalizer.weeksDescribed(in: payload.sourceDisplayWeeksByCourse[index] ?? "")
            let described = SmallTermWeekNormalizer.weeksDescribed(in: course.description)
            let displayed = Set(course.weeks)
            guard displayed == (sourceDisplay.isEmpty ? Set(raw) : sourceDisplay),
                  described.isEmpty || displayed.isSubset(of: described)
            else { throw URLError(.cannotParseResponse) }
        }
        let expectedOffset = expectedSmallTermOffset(payload)
        guard payload.normalizationOffset == expectedOffset else {
            throw NSError(
                domain: "BIT101.NetworkSmoke",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "课表周次偏移证据与归一化结果不一致。"]
            )
        }

        let calendar = ScheduleSharedDateCodec.calendar
        guard let sourceDate = ScheduleSharedDateCodec.parseDate(payload.sourceFirstDayString),
              let normalizedDate = ScheduleSharedDateCodec.parseDate(payload.firstDayString)
        else { throw URLError(.cannotParseResponse) }
        let dayDelta = calendar.dateComponents([.day], from: sourceDate, to: normalizedDate).day ?? 0
        guard dayDelta == expectedOffset * 7 else {
            throw NSError(
                domain: "BIT101.NetworkSmoke",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "课表首周日期与周次偏移结果不一致。"]
            )
        }
    }

    private nonisolated static func expectedSmallTermOffset(_ payload: CourseSyncPayload) -> Int {
        guard payload.term.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("-1") else { return 0 }
        var groups: [String: (raw: Set<Int>, described: Set<Int>)] = [:]
        for (index, course) in payload.courses.enumerated() {
            let described = SmallTermWeekNormalizer.weeksDescribed(in: course.description)
            guard !described.isEmpty else { continue }
            let key = "\(course.number)|\(course.name)|\(course.description)"
            var group = groups[key] ?? ([], [])
            group.raw.formUnion(payload.rawWeeksByCourse[index])
            group.described.formUnion(described)
            groups[key] = group
        }
        let offsets = groups.values.compactMap { group -> Int? in
            let raw = group.raw.sorted(), described = group.described.sorted()
            guard raw.count == described.count, raw.count >= 2, described.allSatisfy({ $0 > 0 }) else { return nil }
            let differences = Set(zip(raw, described).map { $0 - $1 })
            return differences.count == 1 ? differences.first : nil
        }
        return offsets.count >= 2 && Set(offsets) == [3] ? 3 : 0
    }
}
#endif
