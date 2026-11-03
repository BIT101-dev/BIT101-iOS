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
        if let maximumBytes, result.0.count > maximumBytes {
            throw HTTPClientError.responseTooLarge
        }
        return result
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let snapshot = UITestSceneConfiguration.shared.snapshot
        if fixtureRevision != snapshot.revision {
            fixtureRevision = snapshot.revision
            likedObjects = []
            subscriptions =
                AppUITestBootstrap.environment["BIT101_UI_TEST_RESOURCE_ROUTES"] == "1"
                ? ["course1": 1] : [:]
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
        if url.host == "feedback.aihelpme.dev",
            AppUITestBootstrap.environment["BIT101_UI_TEST_CONTENT"] == "1"
        {
            guard let data = request.httpBody,
                let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let id = body["requestID"] as? String, UUID(uuidString: id) != nil
            else {
                throw URLError(.badServerResponse)
            }
            let payload = try JSONSerialization.data(
                withJSONObject: body, options: [.sortedKeys])
            if AppUITestBootstrap.environment["BIT101_UI_TEST_SUGGESTION_RECOVERY"] == "1" {
                guard id != AppUITestBootstrap.recoveredSuggestionID?.uuidString,
                    body["comment"] as? String == "恢复建议草稿",
                    body["contact"] as? String == "测试联系信息",
                    (body["attachments"] as? [[String: Any]])?.count == 1
                else { throw URLError(.badServerResponse) }
            }
            if AppUITestBootstrap.environment["BIT101_UI_TEST_FEEDBACK_HOLD"] == "1" {
                await AppUITestBootstrap.holdRequest("feedback")
            }
            if AppUITestBootstrap.environment["BIT101_UI_TEST_FEEDBACK_RESPONSE_LOST_ONCE"]
                == "1",
                failedPaths.insert("feedback").inserted
            {
                feedbackRetryPayload = payload
                throw URLError(.networkConnectionLost)
            }
            if let accepted = feedbackRetryPayload {
                guard payload == accepted else { throw URLError(.badServerResponse) }
                feedbackRetryPayload = nil
            }
            return try jsonResponse(["id": id], url: url, statusCode: 201)
        }
        if url.host == "itunes.apple.com",
            let fixture = AppUITestBootstrap.environment["BIT101_UI_TEST_UPDATE"]
        {
            return try jsonResponse(
                [
                    "resultCount": 1,
                    "results": [
                        [
                            "version": fixture == "current" ? "0.0" : "999.0",
                            "releaseNotes": "自动化测试更新", "bundleId": "BIT101-dev.BIT101-iOS",
                            "currentVersionReleaseDate": timestamp,
                            "trackViewUrl": BIT101AppStore.url.absoluteString,
                        ]
                    ],
                ], url: url)
        }
        guard AppUITestBootstrap.environment["BIT101_UI_TEST_CONTENT"] == "1",
            url.host == "bit101.flwfdd.xyz"
        else {
            throw URLError(.notConnectedToInternet)
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if AppUITestBootstrap.takeRequest(
            path, query: query, from: &AppUITestBootstrap.failingRequests,
            consuming: !AppUITestBootstrap.persistentFailures.contains(path))
        {
            throw URLError(.networkConnectionLost)
        }
        if AppUITestBootstrap.takeRequest(
            path, query: query, from: &AppUITestBootstrap.holdingRequests)
        {
            await AppUITestBootstrap.holdRequest(path)
        }
        if AppUITestBootstrap.environment["BIT101_UI_TEST_REPORT_FAILURE_ONCE"] == "1",
            path == "manage/report_types", failedPaths.insert(path).inserted
        {
            throw URLError(.networkConnectionLost)
        }
        if AppUITestBootstrap.environment["BIT101_UI_TEST_FAILURE_ONCE"] == "1",
            ["posters", "papers", "courses"].contains(path), failedPaths.insert(path).inserted
        {
            throw URLError(.networkConnectionLost)
        }
        if AppUITestBootstrap.environment["BIT101_UI_TEST_CLAIMS_FAILURE_ONCE"] == "1",
            path == "posters/claims", failedPaths.insert(path).inserted
        {
            throw URLError(.networkConnectionLost)
        }
        if path.hasPrefix("ui-images/") {
            if AppUITestBootstrap.environment["BIT101_UI_TEST_MEDIA_RECOVERY"] == "1",
                path == "ui-images/preview-missing.png"
                    || (path == "ui-images/preview-recovery.png"
                        && AppUITestBootstrap.holdingRequests["media-recovery"] != nil)
            {
                throw URLError(.notConnectedToInternet)
            }
            guard
                let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "image/png"])
            else {
                throw URLError(.badServerResponse)
            }
            return (AppUITestBootstrap.mediaData, response)
        }
        let requestedPage = query.first(where: { $0.name == "page" })?.value ?? "0"
        let repeatedPages =
            AppUITestBootstrap.environment["BIT101_UI_TEST_DUPLICATE_PAGES"] == "1"
        let page = repeatedPages ? String(max(0, (Int(requestedPage) ?? 0) - 1)) : requestedPage
        if repeatedPages, requestedPage == "2" { try await Task.sleep(for: .milliseconds(100)) }
        let userID = query.first { $0.name == "uid" }?.value
        if AppUITestBootstrap.environment["BIT101_UI_TEST_MINE_PAGING_FAILURE_ONCE"] == "1",
            page == "1",
            ["user/followers", "user/followings"].contains(path)
                || (path == "posters" && userID != nil),
            failedPaths.insert("mine-page-" + path + (userID ?? "")).inserted
        {
            throw URLError(.networkConnectionLost)
        }
        let body =
            (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) })
            as? [String: Any] ?? [:]
        let method = request.httpMethod ?? "GET"
        if AppUITestBootstrap.environment["BIT101_UI_TEST_PAGINATION_FAILURE_ONCE"] == "1",
            page == "1",
            method == "GET", ["posters", "papers", "courses"].contains(path),
            failedPaths.insert(
                "page-" + path + (query.first { $0.name == "order" }?.value ?? "")
            ).inserted
        {
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
                    (0...3).contains(level)
                else { throw URLError(.badURL) }
                subscriptions[object] = level
                payload = [:] as [String: String]
            } else {
                if failedPaths.insert(path).inserted { throw URLError(.networkConnectionLost) }
                payload =
                    page == "0"
                    ? subscriptions.sorted { $0.key < $1.key }.filter { $0.value > 0 }
                        .enumerated().map { index, item in
                            [
                                "id": index + 1, "subscription_time": timestamp,
                                "obj": item.key, "level": item.value,
                                "text": item.key == "course1" ? "收藏课程" : "自动化测试话题",
                            ] as [String: Any]
                        } : []
            }
        case "upload/image":
            imageUploads += 1
            if imageUploads == 1 { throw URLError(.networkConnectionLost) }
            payload = mediaImage
        case "messages/unread_nums":
            payload = Dictionary(
                uniqueKeysWithValues: ["comment", "follow", "like", "subscription", "system"]
                    .map { ($0, clearedMessageTypes.contains($0) ? 0 : 1) })
        case "messages":
            let cursor = query.first(where: { $0.name == "last_id" })?.value.flatMap(Int.init)
            if AppUITestBootstrap.environment["BIT101_UI_TEST_MESSAGE_PAGING_FAILURE_ONCE"]
                == "1", cursor == 3,
                failedPaths.insert("message-page").inserted
            {
                throw URLError(.networkConnectionLost)
            }
            if cursor == nil || cursor == 0 {
                clearedMessageTypes.insert(
                    query.first(where: { $0.name == "type" })?.value ?? "comment")
            }
            let resources =
                AppUITestBootstrap.environment["BIT101_UI_TEST_MESSAGE_PAGING_FAILURE_ONCE"]
                    == "1"
                ? [(3, "poster1", "分页首屏消息"), (2, "poster1", "重试后的消息")]
                : AppUITestBootstrap.environment["BIT101_UI_TEST_RESOURCE_ROUTES"] == "1"
                    ? [(2, "course1", "课程更新"), (1, "paper1", "文章更新")]
                    : [(1, "poster1", "自动化测试消息")]
            let pageSize =
                AppUITestBootstrap.environment["BIT101_UI_TEST_MESSAGE_PAGING_FAILURE_ONCE"]
                    == "1" ? 1 : resources.count
            payload = resources.filter { cursor == nil || cursor == 0 || $0.0 < (cursor ?? 0) }
                .prefix(pageSize).map { id, object, text in
                    [
                        "id": id, "from_user": user, "link_obj": object, "obj": object,
                        "text": text, "update_time": timestamp,
                    ] as [String: Any]
                }
        case "reaction/like":
            let object = body["obj"] as? String ?? "poster1"
            if likedObjects.contains(object) {
                likedObjects.remove(object)
            } else {
                likedObjects.insert(object)
            }
            payload = [
                "like": likedObjects.contains(object),
                "like_num": likedObjects.contains(object) ? 2 : 1,
            ]
        case "reaction/comments":
            if method == "GET", query.first(where: { $0.name == "obj" })?.value == "course1",
                AppUITestBootstrap.environment["BIT101_UI_TEST_COURSE_COMMENT_RECOVERY"] == "1",
                failedPaths.insert("course-comments").inserted
            {
                await AppUITestBootstrap.holdRequest("course-comments")
                throw URLError(.networkConnectionLost)
            }
            if method == "POST" {
                var comment = makeComment(
                    id: comments.count + 2, text: body["text"] as? String ?? "测试回复")
                comment["reply_obj"] = body["reply_obj"] ?? ""
                comment["obj"] = body["obj"] ?? "poster1"
                if AppUITestBootstrap.environment["BIT101_UI_TEST_COMMENT_OUTCOME_UNKNOWN_ONCE"]
                    == "1",
                    failedPaths.insert("comment-outcome").inserted
                {
                    comment["id"] = 0
                } else {
                    comments.append(comment)
                }
                payload = comment
            } else {
                let object = query.first { $0.name == "obj" }?.value ?? "poster1"
                payload =
                    page == "0"
                    ? ([makeComment(id: 1, text: "自动化测试评论")]
                        + comments.filter { $0["obj"] as? String == object })
                        .filter { !deletedCommentIDs.contains($0["id"] as? Int ?? 0) }
                        .map { value in
                            var value = value
                            value["obj"] = object
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
                if AppUITestBootstrap.environment[
                    "BIT101_UI_TEST_PUBLICATION_OUTCOME_UNKNOWN_ONCE"] == "1",
                    failedPaths.insert("poster-outcome").inserted
                {
                    throw URLError(.networkConnectionLost)
                }
                payload = ["id": id]
            } else {
                if AppUITestBootstrap.environment["BIT101_UI_TEST_BOT_PAGING"] == "1",
                    query.contains(where: { $0.name == "mode" && $0.value == "search" }),
                    query.contains(where: { $0.name == "order" && $0.value == "new" })
                {
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
                    payload =
                        page == "0"
                        ? ([poster] + createdPosters).filter {
                            !deletedPosterIDs.contains($0["id"] as? Int ?? 0)
                        } : []
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
                if AppUITestBootstrap.environment[
                    "BIT101_UI_TEST_PUBLICATION_OUTCOME_UNKNOWN_ONCE"] == "1",
                    failedPaths.insert("paper-outcome").inserted
                {
                    throw URLError(.networkConnectionLost)
                }
                payload = ["id": id]
            } else if AppUITestBootstrap.environment["BIT101_UI_TEST_PAGINATION"] == "1" {
                payload = paginationItems(paper, page: page, key: "title", title: "分页文章")
            } else {
                payload =
                    page == "0"
                    ? ([paper] + createdPapers).filter {
                        !deletedPaperIDs.contains($0["id"] as? Int ?? 0)
                    } : []
            }
        case "courses":
            var schoolCourse = course
            schoolCourse["id"] = 2
            schoolCourse["name"] = "学校测试课程"
            schoolCourse["number"] = "UI-002"
            if AppUITestBootstrap.environment["BIT101_UI_TEST_PAGINATION"] == "1" {
                payload = paginationItems(course, page: page, key: "name", title: "分页课程")
            } else {
                payload =
                    page == "0"
                    ? (AppUITestBootstrap.environment["BIT101_UI_TEST_SCHOOL"] == "1"
                        ? [course, schoolCourse] : [course]) : []
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
            payload = [
                ["term": "2025-2026-1", "avg_score": 85, "max_score": 98, "student_num": 30],
                ["term": "2025-2026-2", "avg_score": 88, "max_score": 99, "student_num": 35],
            ]
        case "user/followers", "user/followings": payload = page == "0" ? [user] : []
        case "user/info":
            profileChanges.merge(body) { _, new in new }
            payload = [:] as [String: String]
        default:
            if path.hasPrefix("posters/") || path.hasPrefix("papers/") {
                let components = path.split(separator: "/")
                guard components.count == 2, let id = Int(components[1]),
                    ["GET", "PUT", "DELETE"].contains(method)
                else { throw URLError(.unsupportedURL) }
                let records =
                    path.hasPrefix("posters/")
                    ? createdPosters + [poster] : createdPapers + [paper]
                let deletedIDs = path.hasPrefix("posters/") ? deletedPosterIDs : deletedPaperIDs
                guard records.contains(where: { $0["id"] as? Int == id }),
                    !deletedIDs.contains(id)
                else {
                    return try jsonResponse(["error": "not_found"], url: url, statusCode: 404)
                }
                if method == "DELETE" {
                    if path.hasPrefix("posters/") {
                        deletedPosterIDs.insert(id)
                    } else {
                        deletedPaperIDs.insert(id)
                    }
                }
                if path.hasPrefix("posters/") {
                    if method == "PUT", id == 1 { posterChanges.merge(body) { _, new in new } }
                    if method == "PUT",
                        let index = createdPosters.firstIndex(where: { $0["id"] as? Int == id })
                    {
                        for (key, value) in body { createdPosters[index][key] = value }
                    }
                    payload = createdPosters.first(where: { $0["id"] as? Int == id }) ?? poster
                } else {
                    if method == "PUT",
                        AppUITestBootstrap.environment[
                            "BIT101_UI_TEST_PAPER_EDIT_CONFLICT_ONCE"] == "1",
                        failedPaths.insert("paper-edit-conflict").inserted,
                        let index = createdPapers.firstIndex(where: { $0["id"] as? Int == id })
                    {
                        createdPapers[index]["title"] = "远端更新的文章"
                        createdPapers[index]["update_time"] = "2026-10-26T00:00:00Z"
                        return try jsonResponse(
                            ["message": "文章已有更新"], url: url, statusCode: 409)
                    }
                    if method == "PUT",
                        let index = createdPapers.firstIndex(where: { $0["id"] as? Int == id })
                    {
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
                    path.hasPrefix("user/info/")
                        ? method == "GET" && [0, 1].contains(id) : method == "POST" && id == 1
                else { throw URLError(.unsupportedURL) }
                if path.hasPrefix("user/follow/"), method == "POST" { following.toggle() }
                payload = [
                    "user": user, "following_num": 1, "follower_num": 1,
                    "following": following, "follower": false, "own": path == "user/info/0",
                ]
            } else {
                throw URLError(.unsupportedURL)
            }
        }
        return try jsonResponse(payload, url: url)
    }

    private func jsonResponse(_ payload: Any, url: URL, statusCode: Int = 200) throws -> (
        Data, URLResponse
    ) {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard
            let response = HTTPURLResponse(
                url: url, statusCode: statusCode, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])
        else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }

    private var user: [String: Any] {
        var base: [String: Any] = [
            "id": 1, "create_time": timestamp, "nickname": "自动化测试用户", "motto": "测试签名",
        ]
        let emptyAvatar: [String: Any] = ["mid": "", "url": "", "low_url": ""]
        base["avatar"] = mediaEnabled ? mediaImage : emptyAvatar
        base["identity"] =
            [
                "id": 1, "color": "#FF9500", "text": "测试", "create_time": timestamp,
                "update_time": timestamp,
            ] as [String: Any]
        return base.merging(profileChanges) { _, new in new }
    }

    private var poster: [String: Any] {
        let base: [String: Any] = [
            "id": 1, "anonymous": false, "claim": ["id": 1, "text": "日常"],
            "comment_num": commentCount(for: "poster1"),
            "create_time": timestamp, "edit_time": timestamp, "update_time": timestamp,
            "images": mediaEnabled ? posterImages : [],
            "like": likedObjects.contains("poster1"),
            "like_num": likedObjects.contains("poster1") ? 2 : 1, "own": true,
            "plugins": "[]", "public": true,
            "tags": AppUITestBootstrap.environment["BIT101_UI_TEST_LONG_TAGS"] == "1"
                ? (1...8).map { "横向滚动标签\($0)" } : ["测试", "自动化"],
            "text": readingText("自动化测试话题正文", ending: "长帖末尾"), "title": "自动化测试话题", "user": user,
            "subscription": subscriptions["poster1"] ?? 0,
        ]
        return base.merging(posterChanges) { _, new in new }
    }

    private func readingText(_ text: String, ending: String) -> String {
        guard AppUITestBootstrap.environment["BIT101_UI_TEST_LONG_TEXT"] == "1" else {
            return text
        }
        return text + String(repeating: "正文片段 ", count: 8_000) + ending
    }

    private func paginationItems(
        _ item: [String: Any], page: String, key: String, title: String
    ) -> [[String: Any]] {
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
        [
            "id": 1, "title": "自动化测试文章", "intro": "测试文章简介", "content": paperContent,
            "create_time": timestamp, "update_time": timestamp, "update_user": user,
            "anonymous": false,
            "like_num": likedObjects.contains("paper1") ? 2 : 1,
            "comment_num": commentCount(for: "paper1"), "public_edit": true,
            "like": likedObjects.contains("paper1"), "own": true,
        ]
    }

    private var paperContent: String {
        guard mediaEnabled else { return "# 测试文章\n\n自动化测试文章正文" }
        return #"""
            {"blocks":[
              {"id":"ui-header","type":"header","data":{"text":"测试文章","level":1}},
              {"id":"ui-paragraph","type":"paragraph","data":{"text":"自动化测试文章正文"}},
              {"id":"ui-link","type":"paragraph","data":{"text":"<a href=\"https://github.com/\#
            BIT101-dev/BIT101-iOS\">正文链接</a>"}},
              {"id":"ui-image","type":"image","data":{"file":{"url":"https://bit101.flwfdd.xyz\#
            /ui-images/image.png"},"caption":"测试图片"}},
              {"id":"ui-extended","type":"table","data":{"content":[["扩展正文"]]}}
            ]}
            """#
    }

    private var course: [String: Any] {
        [
            "id": 1, "name": "自动化测试课程", "number": "UI-001", "credit": 3,
            "like_num": likedObjects.contains("course1") ? 2 : 1,
            "comment_num": commentCount(for: "course1"), "rate": 4, "teachers_name": "测试教师",
            "teachers_number": "T001",
            "like": likedObjects.contains("course1"),
        ]
    }

    private func commentCount(for object: String) -> Int {
        (deletedCommentIDs.contains(1) ? 0 : 1)
            + comments.filter {
                $0["obj"] as? String == object
                    && !deletedCommentIDs.contains($0["id"] as? Int ?? 0)
            }.count
    }

    private func makeComment(id: Int, text: String) -> [String: Any] {
        let text =
            AppUITestBootstrap.environment["BIT101_UI_TEST_COMMENT_MEDIA_LINKS"] == "1"
                && id == 1
            ? "https://example.com/comment" : text
        var replyUser = user
        replyUser["id"] = 0
        replyUser["nickname"] = ""
        return [
            "id": id, "obj": "comment\(id)", "images": mediaEnabled ? [mediaImage] : [],
            "user": user, "anonymous": false,
            "create_time": timestamp, "update_time": timestamp,
            "like": likedObjects.contains("comment\(id)"),
            "like_num": likedObjects.contains("comment\(id)") ? 1 : 0,
            "comment_num": 0, "own": true, "rate": 4, "reply_user": replyUser, "reply_obj": "",
            "text": readingText(text, ending: "长评末尾"), "sub": [],
        ]
    }
}

extension UITestHTTPTransport {
    private var mediaEnabled: Bool {
        AppUITestBootstrap.environment["BIT101_UI_TEST_MEDIA"] == "1"
    }
    private var posterImages: [[String: Any]] {
        guard AppUITestBootstrap.environment["BIT101_UI_TEST_MEDIA_RECOVERY"] == "1" else {
            return [mediaImage]
        }
        return [
            mediaImage,
            [
                "mid": "preview-recovery",
                "url": "https://bit101.flwfdd.xyz/ui-images/preview-recovery.png",
                "low_url": "https://bit101.flwfdd.xyz/ui-images/preview-missing.png",
            ],
        ]
    }
    private var mediaImage: [String: Any] {
        let name =
            AppUITestBootstrap.environment["BIT101_UI_TEST_PORTRAIT_MEDIA"] == "1"
            ? "portrait" : "image"
        let url = "https://bit101.flwfdd.xyz/ui-images/\(name).png"
        return ["mid": "ui-image", "url": url, "low_url": url]
    }
}

#endif
