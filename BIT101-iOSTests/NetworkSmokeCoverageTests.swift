#if DEBUG
import Foundation
import Testing
import UIKit
import CommunityCore
import CommunityTransport
import GalleryFeature
@testable import PaperFeature
import TransportCore
@testable import BIT101_iOS

@Suite("Network smoke coverage")
@MainActor
struct NetworkSmokeCoverageTests {
    @Test func articleUnknownBlocksKeepTheirPositionAndOfferTheOriginal() {
        let raw = #"{"blocks":[{"id":"first","type":"paragraph","data":{"text":"正文"}},{"id":"future","type":"table","data":{"content":[["单元格"]]}},{"id":"last","type":"paragraph","data":{"text":"末段"}}]}"#
        let blocks = PaperContentRenderer.blocks(from: raw)
        #expect(blocks.map(\.id) == ["first", "future", "last"])
        if case .requiresOriginal = blocks[1] {} else { Issue.record("Extended content should keep an original-reading placeholder") }
        #expect(PaperEditorContentBuilder.canEditAsPlainText(raw) == false)
    }

    @Test(arguments: ["body", "blocks", "block"])
    func articleResourceBudgetsStopBeforeRichTextImport(kind: String) throws {
        let raw: String
        switch kind {
        case "body": raw = String(repeating: "x", count: PaperContentResourceLimits.maximumBodyBytes + 1)
        case "blocks":
            let block: [String: Any] = ["type": "paragraph", "data": ["text": "text"]]
            raw = String(decoding: try JSONSerialization.data(withJSONObject: ["blocks": Array(repeating: block,
                count: PaperContentResourceLimits.maximumBlocks + 1)]), as: UTF8.self)
        default:
            raw = String(decoding: try JSONSerialization.data(withJSONObject: ["blocks": [["type": "paragraph",
                "data": ["text": String(repeating: "x", count: PaperContentResourceLimits.maximumBlockBytes + 1)]]]]), as: UTF8.self)
        }
        let blocks = PaperContentRenderer.blocks(from: raw)
        #expect(blocks.count == 1)
        if case .requiresOriginal = blocks[0] {} else { Issue.record("Oversized content should offer original reading") }
    }

    private func user(_ id: Int) -> CommunityUser {
        .init(id: id, createTime: "", nickname: "fixture", avatar: .init(mid: "", url: "", lowUrl: ""), motto: "",
            identity: .init(id: 1, color: "", text: "", createTime: "", updateTime: "", deleteTime: nil))
    }

    @Test func pageFailureAndFilteredSourceCursorRemainPartOfTheProbe() async throws {
        var pages: [Int] = []
        await #expect(throws: URLError.self) {
            _ = try await NetworkSmokePaging.arrayPage { page in
                pages.append(page)
                if page == 1 { throw URLError(.timedOut) }
                return [user(1)]
            }
        }
        #expect(pages == [0, 1])
        pages = []
        let first: GalleryPageBatch<CommunityUser> = try await NetworkSmokePaging.batch { page in
            pages.append(page)
            return .init(items: [], nextSourcePage: page == 0 ? 4 : 5, canLoadMore: page == 0, sourceIDs: [page + 1])
        }
        #expect(first.items.isEmpty && pages == [0, 4])
        await #expect(throws: URLError.self) {
            let _: GalleryPageBatch<CommunityUser> = try await NetworkSmokePaging.batch { page in
                .init(items: [user(1)], nextSourcePage: 1, canLoadMore: true)
            }
        }
    }

    @Test func repeatedPagesFailAndPartialOverlapOrTerminalPagesAdvance() async throws {
        for repeated in [true, false] {
            await #expect(throws: URLError.self) {
                _ = try await NetworkSmokePaging.arrayPage { page in
                    [user(repeated || page == 0 ? 1 : 0)]
                }
            }
            await #expect(throws: URLError.self) {
                let _: GalleryPageBatch<CommunityUser> = try await NetworkSmokePaging.batch { page in
                    .init(items: [], nextSourcePage: page + 1, canLoadMore: true,
                        sourceIDs: [repeated || page == 0 ? 1 : 0])
                }
            }
        }
        for terminal in [false, true] {
            var pages: [Int] = []
            _ = try await NetworkSmokePaging.arrayPage { page in
                pages.append(page)
                return page == 0 ? [user(1), user(2)] : terminal ? [] : [user(2), user(3)]
            }
            #expect(pages == [0, 1])
            pages = []
            let _: GalleryPageBatch<CommunityUser> = try await NetworkSmokePaging.batch { page in
                pages.append(page)
                return .init(items: [], nextSourcePage: page + 1, canLoadMore: page == 0,
                    sourceIDs: page == 0 ? [1, 2] : terminal ? [] : [2, 3])
            }
            #expect(pages == [0, 1])
        }
    }

    @Test func terminalArrayAvoidsAContinuationAndMessagesUseTheirActualCursor() async throws {
        var pages: [Int] = []
        let empty: [CommunityUser] = try await NetworkSmokePaging.arrayPage { page in pages.append(page); return [] }
        #expect(empty.isEmpty && pages == [0])
        let data = Data(#"{"from_user":{},"id":9,"link_obj":"poster1","obj":"poster1","text":"","update_time":""}"#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let message = try decoder.decode(GalleryMessage.self, from: data)
        var cursors: [Int?] = []
        _ = try await NetworkSmokePaging.messages { cursor in cursors.append(cursor); return cursor == nil ? [message] : [] }
        #expect(cursors == [nil, 9])
        await #expect(throws: URLError.self) {
            _ = try await NetworkSmokePaging.messages { _ in [message] }
        }
    }

    private final class MediaRoute: HTTPTransport {
        var calls: [(String, String)] = []
        var referenced: [[String]] = []
        var brokenReference = false
        var onUpload: (() -> Void)?
        private var image: [String: Any] { ["mid": "uploaded", "url": "https://example.invalid/image.jpg", "low_url": ""] }
        private var user: [String: Any] {
            ["id": 1, "create_time": "", "nickname": "fixture", "avatar": image, "motto": "",
                "identity": ["id": 1, "color": "", "text": "", "create_time": "", "update_time": ""]]
        }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            let method = request.httpMethod ?? "GET"
            calls.append((url.path, method))
            let result: [String: Any]
            if url.path == "/upload/image" {
                #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data;") == true)
                let body = try #require(request.httpBody)
                #expect(body.range(of: Data([0xFF, 0xD8])) != nil)
                result = image
                onUpload?()
            } else if method == "POST" {
                let body = try #require(request.httpBody)
                let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                referenced.append(try #require(payload["image_mids"] as? [String]))
                if url.path == "/posters" { result = ["id": 9] }
                else {
                    result = ["id": 10, "obj": "poster9", "images": [image], "user": user, "anonymous": false,
                        "create_time": "", "update_time": "", "like": false, "like_num": 0, "comment_num": 0,
                        "own": true, "rate": 0, "reply_user": user, "reply_obj": "", "text": "fixture", "sub": []]
                }
            } else {
                result = ["id": 9, "title": "fixture", "text": "fixture", "anonymous": false, "claim": ["id": 0, "text": ""],
                    "comment_num": 0, "create_time": "", "edit_time": "", "images": brokenReference ? [] : [image],
                    "like": false, "like_num": 0, "own": true, "plugins": "[]", "public": false, "tags": [],
                    "update_time": "", "user": user]
            }
            return (try JSONSerialization.data(withJSONObject: result),
                try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
    }

    @Test func productionWritesUploadJPEGAndVerifyServerImageReferences() async throws {
        let route = MediaRoute()
        let session = CommunitySession(httpClient: HTTPClient(transport: route, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: { .init(identity: .init(accountIdentifier: "fixture"), cookie: "fixture") }, refresh: { _ in })
        let gallery = GalleryService(session: session, preferences: {
            .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        })
        var operations = CommunityWriteSmoke.Operations.production(gallery: gallery)
        var uploads: [String] = []
        #expect(try await operations.create(.poster, "fixture", { uploads.append($0) }) == 9)
        #expect(try await operations.comment("poster9", "fixture", { uploads.append($0) }).images.map(\.mid) == ["uploaded"])
        #expect(uploads == ["uploaded", "uploaded"])
        let imageData = try CommunityWriteMedia.jpeg()
        #expect(imageData == (try CommunityWriteMedia.jpeg()) && UIImage(data: imageData)?.size == CGSize(width: 1, height: 1))
        #expect(route.referenced == [["uploaded"], ["uploaded"]])
        #expect(route.calls.filter { $0.0 == "/upload/image" }.count == 2)
        route.brokenReference = true
        await #expect(throws: URLError.self) { _ = try await operations.create(.poster, "fixture", { _ in }) }
        let writes = route.calls.filter { $0.1 == "POST" && $0.0 != "/upload/image" }.count
        for comment in [false, true] {
            await #expect(throws: CocoaError.self) {
                let record: CommunityWriteSmoke.Operations.RecordImage = { _ in throw CocoaError(.fileWriteNoPermission) }
                if comment { _ = try await operations.comment("poster9", "fixture", record) }
                else { _ = try await operations.create(.poster, "fixture", record) }
            }
        }
        #expect(route.calls.filter { $0.1 == "POST" && $0.0 != "/upload/image" }.count == writes)
        var identity = CommunitySessionIdentity(accountIdentifier: "fixture")
        operations.identity = { identity }
        let scoped = operations.scoped(to: identity)
        route.onUpload = { identity = .init(accountIdentifier: "other") }
        await #expect(throws: CancellationError.self) {
            _ = try await scoped.create(.poster, "fixture") { _ in Issue.record("上传完成后沿账号归属保存资源") }
        }
        #expect(route.calls.filter { $0.1 == "POST" && $0.0 != "/upload/image" }.count == writes)
    }
}
#endif
