import XCTest

nonisolated final class CommunityRecoveryUITests: UIAutomationTestCase {
    @MainActor
    @objc func testMessagesAndFavoritesOpenNativeResources() {
        app = configureApp(resetStorage: true, content: true, resourceRoutes: true, initialTab: "gallery")
        tap("消息")
        tap("课程更新")
        assertUI(app.navigationBars["课程详情"].appears(timeout: 5), "课程消息应打开原生课程详情。")
        back()
        tap("文章更新")
        assertUI(app.navigationBars["文章详情"].appears(timeout: 5), "文章消息应打开原生文章详情。")
        back()
        tap("取消")
        tap("我的收藏")
        assertUI(textElement("加载收藏失败").appears(timeout: 5), "收藏首次故障应提供恢复入口。")
        tap("重试")
        tap("收藏课程")
        assertUI(app.navigationBars["课程详情"].appears(timeout: 5), "课程收藏应打开原生课程详情。")
    }

    @MainActor
    @objc func testCommunityPaginationRetriesFromTheVisibleTail() {
        for (tab, section, title) in [("home", "课程", "分页课程"), ("gallery", "文章", "分页文章"),
            ("gallery", "最新", "分页话题")] {
            app = configureApp(resetStorage: true, content: true, pagination: true,
                paginationFailureOnce: true, initialTab: tab)
            tapHeader(app.segmentedControls.buttons[section])
            let retry = app.buttons["community.pagination.retry"]
            let failure = app.alerts["加载更多失败"]
            for _ in 1...8 {
                if failure.exists { break }
                app.swipeUp()
            }
            assertUI(failure.appears(timeout: 5), "分页故障应展示当前请求的失败原因。")
            closeAlertIfPresent()
            reveal(retry, description: "分页原位重试")
            assertUI(retry.appears(timeout: 5), "分页故障应保留当前位置的重试入口。")
            retry.tapBriefly()
            let nextPage = textElement("\(title) 9")
            reveal(nextPage, description: "重试后第二页")
            assertUI(nextPage.isHittable, "重试应继续原游标并展示后续内容。")
        }
    }

    @MainActor
    @objc func testCourseLookupFailureKeepsTheSearchIdentity() {
        app = configureApp(resetStorage: true, content: true, school: true, courseLookupFailureOnce: true)
        tap("学校测试课程")
        tap("查看课程评价")
        assertUI(app.alerts["课程评价加载失败"].appears(timeout: 5), "两路检索故障应展示恢复原因。")
        closeAlertIfPresent()
        app.buttons["course.evaluation.search"].tapBriefly()
        assertUI(app.segmentedControls.buttons["课程"].appears(timeout: 5), "恢复入口应进入原生课程搜索。")
        assertUI(app.textFields["在这里搜索课程哦"].value as? String == "学校测试课程", "搜索应保留原课程名称。")
        assertUI(textElement("学校测试课程").appears(timeout: 5), "恢复后的搜索应展示可选择的课程。")
    }
}
