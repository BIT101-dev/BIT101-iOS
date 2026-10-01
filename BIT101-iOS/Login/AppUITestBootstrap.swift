#if BIT101_UI_TESTING
import StorageCore
import TransportCore
import Foundation
import UIKit

enum AppUITestBootstrap {
    static func prepareSessionIfNeeded() async {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BIT101_UI_TEST_RESET_STORAGE"] == "1",
              let account = environment["BIT101_UI_TEST_ACCOUNT"], !account.isEmpty else { return }
        do {
            _ = try await UITestLoginService().login(studentID: account, password: "ui-test-password")
        } catch {
            preconditionFailure("UI test session preparation failed: \(error)")
        }
    }

    static func prepareForLaunch() {
        let environment = ProcessInfo.processInfo.environment
        guard AppFileDirectories.isRunningUITest else {
            preconditionFailure("The UI automation App requires its isolated launch configuration")
        }
        UIView.setAnimationsEnabled(environment["BIT101_UI_TEST_ANIMATIONS"] == "1")
        guard environment["BIT101_UI_TEST_RESET_STORAGE"] == "1" else { return }

        AppFileDirectories.defaults.removePersistentDomain(
            forName: AppFileDirectories.uiTestDefaultsSuiteName
        )
        LoginStorage.resetUITestCredentials()

        let supportDirectory = AppFileDirectories.applicationSupportDirectoryURL(named: "BIT101-iOS")
        guard AppFileDirectories.files.fileExists(at: supportDirectory) else { return }
        do {
            let testSession = AppStorageSession(
                accountIdentifier: "__ui_tests__.\(AppFileDirectories.uiTestRunIdentifier)."
            )
            let testAccountPrefixes = [testSession.accountStorageIdentifier, testSession.accountDirectoryName]
            let directories = try AppFileDirectories.files.contentsOfDirectory(at: supportDirectory, options: [])
            for directory in directories where testAccountPrefixes.contains(where: directory.lastPathComponent.hasPrefix) {
                try AppFileDirectories.files.removeItem(at: directory)
            }
        } catch {
            preconditionFailure("UI test account storage cleanup failed: \(error)")
        }
    }
}

/// 固定响应通过生产 Service 解码，交互修改保留到当前 App 会话结束。
final class UITestHTTPTransport: HTTPTransport {
    private var likedObjects: Set<String> = []
    private var comments: [[String: Any]] = []
    private var createdPosters: [[String: Any]] = []
    private var createdPapers: [[String: Any]] = []
    private var deletedIDs: Set<Int> = []
    private var deletedCommentIDs: Set<Int> = []
    private let timestamp = "2026-10-01T10:00:00Z"

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard ProcessInfo.processInfo.environment["BIT101_UI_TEST_CONTENT"] == "1",
              let url = request.url, url.host == "bit101.flwfdd.xyz" else {
            throw URLError(.notConnectedToInternet)
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let page = query.first(where: { $0.name == "page" })?.value ?? "0"
        let body = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
        let method = request.httpMethod ?? "GET"
        let payload: Any
        switch path {
        case "posters/claims": payload = [["id": 1, "text": "日常"]]
        case "manage/report_types": payload = [["id": 1, "text": "其他"]]
        case "manage/reports": payload = [:] as [String: String]
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
                let comment = makeComment(id: comments.count + 2, text: body["text"] as? String ?? "测试回复")
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
        case "courses": payload = page == "0" ? [course] : []
        case "courses/1": payload = course
        case "courses/histories/UI-001":
            payload = [["term": "2025-2026-1", "avg_score": 85, "max_score": 98, "student_num": 30],
                       ["term": "2025-2026-2", "avg_score": 88, "max_score": 99, "student_num": 35]]
        case "user/followers", "user/followings": payload = page == "0" ? [user] : []
        default:
            if path.hasPrefix("posters/") || path.hasPrefix("papers/") {
                let id = Int(url.lastPathComponent) ?? 1
                if method == "DELETE" { deletedIDs.insert(id) }
                if path.hasPrefix("posters/") {
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
                payload = ["user": user, "following_num": 1, "follower_num": 1,
                           "following": method == "POST", "follower": false, "own": path == "user/info/0"]
            } else {
                throw URLError(.unsupportedURL)
            }
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                             headerFields: ["Content-Type": "application/json"]) else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }

    private var user: [String: Any] {
        ["id": 1, "create_time": timestamp, "nickname": "自动化测试用户", "motto": "测试签名",
         "avatar": ["mid": "", "url": "", "low_url": ""],
         "identity": ["id": 1, "color": "#FF9500", "text": "测试", "create_time": timestamp, "update_time": timestamp]]
    }

    private var poster: [String: Any] {
        ["id": 1, "anonymous": false, "claim": ["id": 1, "text": "日常"], "comment_num": 1,
         "create_time": timestamp, "edit_time": timestamp, "update_time": timestamp,
         "images": [], "like": likedObjects.contains("poster1"), "like_num": 1, "own": true,
         "plugins": "[]", "public": true, "tags": ["测试"], "text": "自动化测试话题正文", "title": "自动化测试话题", "user": user]
    }

    private var paper: [String: Any] {
        ["id": 1, "title": "自动化测试文章", "intro": "测试文章简介", "content": "# 测试文章\n\n自动化测试文章正文",
         "create_time": timestamp, "update_time": timestamp, "update_user": user, "anonymous": false,
         "like_num": 1, "comment_num": 1, "public_edit": true, "like": likedObjects.contains("paper1"), "own": true]
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
        return ["id": id, "obj": "comment\(id)", "images": [], "user": user, "anonymous": false,
         "create_time": timestamp, "update_time": timestamp, "like": false, "like_num": 0,
         "comment_num": 0, "own": true, "rate": 4, "reply_user": replyUser, "reply_obj": "", "text": text, "sub": []]
    }
}
#endif
