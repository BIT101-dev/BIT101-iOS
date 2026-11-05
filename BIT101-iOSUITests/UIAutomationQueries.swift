import CoreGraphics
import Network
import XCTest
import os

@MainActor
extension UIAutomationTestCase {
    func captureBrowserScreenshot(_ title: String) {
        let attachment = XCTAttachment(screenshot: app.native.screenshot())
        attachment.name = "界面截图：\(title)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func checkSideToolbar(_ labels: [String]) {
        let window = app.native.windows.firstMatch.frame
        guard let safe = app.scrollGestureFrame(in: window) else { return }
        let navigation = ["日程", "地图", "话廊", "成绩", "我的"].map { app.native.buttons[$0].frame }
            .reduce(CGRect.null) { $0.union($1) }
        var previous: CGRect?
        let buttons = labels.map { app.native.buttons[$0] }
        let visible = buttons.filter { $0.exists && $0.isHittable }
        assertUI(!visible.isEmpty, "侧栏应直接呈现主要操作。")
        for button in visible {
            assertUI(
                button.frame.minX >= safe.maxX - 0.5 && button.frame.maxX <= window.maxX
                    && button.frame.maxY <= navigation.minY,
                "工具应完整排列在主导航上方的系统侧栏：\(button.label)，按钮 \(button.frame)。")
            if let previous { assertUI(button.frame.minY >= previous.maxY, "侧栏工具应按顺序竖向排列。") }
            previous = button.frame
        }
        let hidden = labels.filter {
            !app.native.buttons[$0].exists || !app.native.buttons[$0].isHittable
        }
        if !hidden.isEmpty {
            let overflow = app.native.buttons["BottomOverflowBarButtonItem"]
            assertUI(
                overflow.exists && overflow.isHittable && overflow.frame.minX >= safe.maxX
                    && overflow.frame.maxY <= navigation.minY, "剩余操作应由系统侧栏更多菜单承载。")
            overflow.press(forDuration: 0.01)
            for label in hidden {
                let item = app.native.descendants(matching: .any).matching(
                    NSPredicate(format: "label == %@", label)
                ).firstMatch
                assertUI(
                    item.waitForExistence(timeout: 5) && item.isHittable, "更多菜单应提供原有操作：\(label)。")
            }
            dismissBrowserActionMenu()
        }
    }

    func checkBrowserActionBounds(_ labels: [String]) {
        let window = app.native.windows.firstMatch.frame
        if windowUsesSideToolbar {
            checkSideToolbar(labels)
            return
        }
        let navigation = ["日程", "地图", "话廊", "成绩", "我的"].map { app.mainTab($0).frame }
            .reduce(CGRect.null) { $0.union($1) }
        for label in labels {
            let button = app.native.buttons.matching(NSPredicate(format: "label == %@", label))
                .firstMatch
            assertUI(
                waitUntil(
                    NSPredicate { _, _ in
                        button.exists && window.contains(button.frame)
                            && !button.frame.intersects(navigation)
                    }, on: app),
                "悬浮工具应完整显示在主导航之外：\(label)，按钮 \(button.frame)，窗口 \(window)，导航 \(navigation)。")
        }
    }

    var windowUsesSideToolbar: Bool {
        let window = app.native.windows.firstMatch.frame
        let traits = windowTraits()
        return window.height > window.width && (traits["safeTrailing"] ?? 0) > 0
            && traits["horizontal"] != UIUserInterfaceSizeClass.regular.rawValue
    }

    func selectSystemCalendarDate(_ date: Date, in picker: UIElement) {
        let month = picker.buttons.matching(
            NSPredicate(format: "identifier IN %@", ["DatePicker.Show", "DatePicker.Hide"])
        ).firstMatch
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月"
        guard let shown = formatter.date(from: month.value as? String ?? ""),
            let target = Calendar.current.dateInterval(of: .month, for: date)?.start,
            let distance = Calendar.current.dateComponents([.month], from: shown, to: target).month
        else {
            assertUI(false, "系统日历应提供可读的年月。")
            return
        }
        for _ in 0..<abs(distance) {
            picker.buttons[distance < 0 ? "DatePicker.PreviousMonth" : "DatePicker.NextMonth"]
                .tapBriefly()
        }
        assertUI(month.value as? String == formatter.string(from: date), "系统日历应切换到目标月份。")
        formatter.dateFormat = "M月d日"
        let day = picker.collectionViews.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", formatter.string(from: date))
        ).firstMatch
        assertUI(day.appears(timeout: 5), "目标日期应显示在系统日历中。")
        day.tapBriefly()
    }

    func revealBrowserAction(_ label: String) -> UIElement {
        let button = app.native.buttons[label]
        if !button.exists {
            let overflow = app.native.buttons["BottomOverflowBarButtonItem"]
            assertUI(overflow.exists && overflow.isHittable, "折叠操作应提供系统更多菜单：\(label)。")
            overflow.press(forDuration: 0.01)
        }
        assertUI(
            (button.exists || button.waitForExistence(timeout: 5)) && button.isEnabled,
            "当前操作应可触达：\(label)。")
        return app.buttons[label]
    }

    func dismissBrowserActionMenu() {
        app.native.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.75)).tapBriefly()
    }

    func checkScheduleGeometry() {
        let schedule = app.mainTab("日程")
        guard schedule.exists, schedule.isSelected, let root = try? app.snapshot() else { return }
        let window = root.frame
        let traits = windowTraits()
        if let grid = root.firstSnapshot(where: { $0.identifier == "schedule.calendar" }),
            app.sectionTab("课表").isSelected
        {
            let available = app.scrollGestureFrame(in: window) ?? window
            for day in grid.snapshots(matching: .button)
            where day.label.range(
                of: "^第-?[0-9]+周，周[一二三四五六七]，.*", options: .regularExpression) != nil
            {
                assertUI(
                    day.frame.minX >= available.minX && day.frame.maxX <= available.maxX,
                    "课表日期列应完整位于正文宽度内：日期 \(day.frame)，正文 \(available)。")
            }
            let bar = ["日程", "地图", "话廊", "成绩", "我的"].map { app.mainTab($0).frame }
                .reduce(CGRect.null) { $0.union($1) }
            let hasBottomBar = bar.width > bar.height && bar.minY > window.midY
            func renderedCalendarFrame(in state: any XCUIElementSnapshot) -> CGRect {
                if let cell = state.snapshots(matching: .cell).first(where: {
                    $0.firstSnapshot {
                        $0.elementType == .button && $0.identifier == "schedule.add-content"
                    } != nil
                }) {
                    return cell.frame
                }
                return state.firstSnapshot { $0.identifier == "schedule.calendar" }?.frame
                    ?? grid.frame
            }
            var currentRoot = root
            let ready = NSPredicate { _, _ in
                if let latest = try? self.app.snapshot() { currentRoot = latest }
                let gap =
                    (hasBottomBar ? bar.minY : window.maxY)
                    - renderedCalendarFrame(in: currentRoot).maxY
                return hasBottomBar ? gap >= 8 : abs(gap) <= 1
            }
            assertUI(
                waitUntil(ready, on: app),
                "课表底部应在当前字号布局完成后保留间距：\(grid.frame)，导航 \(bar)。")
            let gap =
                (hasBottomBar ? bar.minY : window.maxY)
                - renderedCalendarFrame(in: currentRoot).maxY
            assertUI(
                hasBottomBar ? gap >= 8 : abs(gap) <= 1,
                "课表底部应按系统导航位置分配空间：课表 \(grid.frame)，导航 \(bar)，间隙 \(gap)。")
            let action = currentRoot.firstSnapshot {
                $0.elementType == .button && $0.identifier == "schedule.add-content"
            }
            let bottom = hasBottomBar ? bar.minY : window.maxY - CGFloat(traits["safeBottom"] ?? 0)
            assertUI(
                action != nil && (action?.frame.maxY ?? .infinity) <= bottom + 0.5,
                "课表操作应保持在系统可触达区域：按钮 \(action?.frame ?? .null)，底部界限 \(bottom)。")
        }
        guard
            let segmented = root.snapshots(matching: .segmentedControl).first,
            segmented.snapshots(matching: .button).contains(where: { $0.label == "空教室" })
        else { return }
        let header = segmented.frame
        let top = CGFloat(traits["safeTop"] ?? 0)
        let side = (traits["safeLeading"] ?? 0) + (traits["safeTrailing"] ?? 0)
        let minimumTop = window.minY + (top == 0 && side > 0 ? 16 : top)
        assertUI(
            header.minY >= minimumTop - 0.5,
            "日程各分区应保留窗口安全距离：分区栏 \(header)，顶部界限 \(minimumTop)。")
        let key = "\(window):\(traits["safeTop"] ?? 0):\(side):\(header.height)"
        if let reference = scheduleHeaderFrames[key] {
            assertUI(
                abs(header.minY - reference.minY) <= 1,
                "日程各分区应共享顶部位置：当前 \(header)，参考 \(reference)。")
        } else {
            scheduleHeaderFrames[key] = header
        }
    }

    func assertRefreshBelowSectionTabs(referenceHeader: CGRect? = nil) {
        let header = app.native.segmentedControls.firstMatch
        guard
            let list = app.native.collectionViews.allElementsBoundByIndex.first(where: {
                $0.frame.width > 0
            })
        else {
            assertUI(false, "当前分区应提供可见的原生列表。")
            return
        }
        if let referenceHeader {
            assertUI(
                abs(header.frame.minY - referenceHeader.minY) <= 1
                    && abs(header.frame.height - referenceHeader.height) <= 1,
                "课表、DDL 与空教室应共享分区栏安全距离：当前 \(header.frame)，参考 \(referenceHeader)。")
        }
        let row = list.cells.containing(.button, identifier: "app.refresh-status.action").firstMatch
        let stamp = row.staticTexts["app.refresh-status.timestamp"]
        assertUI(
            header.exists && row.exists && stamp.exists && row.frame.minY >= header.frame.maxY
                && stamp.frame.minY >= header.frame.maxY && stamp.isHittable,
            "刷新行与时间文字应完整显示在分区栏下方：分区栏 \(header.frame)，刷新行 \(row.frame)，时间 \(stamp.frame)。")
    }

    func windowTraits() -> [String: Int] {
        guard let response = UITestControlClient.request(["command": "window-layout"]),
            let values = try? JSONSerialization.jsonObject(with: Data(response.utf8))
                as? [[String: Any]],
            let traits = values.first
        else {
            XCTFail("当前窗口应提供布局信息。")
            return [:]
        }
        return traits.compactMapValues { ($0 as? NSNumber)?.intValue }
    }

    func requireLandscapeSupport() throws {
        let traits = windowTraits()
        try XCTSkipIf(
            traits["idiom"] == UIUserInterfaceIdiom.phone.rawValue
                && (traits["horizontal"] != UIUserInterfaceSizeClass.regular.rawValue
                    || traits["vertical"] != UIUserInterfaceSizeClass.regular.rawValue),
            "当前手机窗口按 App 方向策略采用竖屏；横屏约定由支持横屏的窗口验收。")
    }

    @MainActor
    func openSettings(_ route: String) {
        let mine = app.mainTab("我的")
        if !mine.isSelected {
            mine.tapBriefly()
            assertUI(waitUntil(NSPredicate(format: "selected == true"), on: mine), "设置入口应先切换到个人页。")
        }
        let entry = app.buttons["settings.route.\(route)"]
        reveal(entry)
        entry.tapBriefly()
    }

    @MainActor
    func interactionScrollFrame(for element: UIElement) -> CGRect? {
        guard let snapshot = try? app.native.snapshot() else { return nil }
        let window = snapshot.frame
        let containers =
            (snapshot.snapshots(matching: .table) + snapshot.snapshots(matching: .collectionView)
            + snapshot.snapshots(matching: .scrollView))
            .filter { !$0.frame.isEmpty && window.intersects($0.frame) }
        var owning: [any XCUIElementSnapshot] = []
        if element.exists {
            let identifier = element.identifier
            let label = element.label
            let type = element.elementType
            owning = containers.filter { container in
                container.firstSnapshot { target in
                    target.elementType == type
                        && (identifier.isEmpty
                            ? target.label == label : target.identifier == identifier)
                } != nil
            }
        }
        for owner in owning.reversed() {
            let frame = owner.frame
            if let response = UITestControlClient.request(["command": "scroll-inventory"]),
                let rows = (try? JSONSerialization.jsonObject(with: Data(response.utf8)))
                    as? [[String: Any]],
                let values = rows.first(where: { row in
                    guard let bounds = row["frame"] as? [Double], bounds.count == 4,
                        row["identifier"] as? String == owner.identifier
                    else { return false }
                    return zip(
                        bounds,
                        [frame.minX, frame.minY, frame.width, frame.height].map(Double.init)
                    )
                    .allSatisfy { abs($0 - $1) <= 0.5 }
                })?["viewport"] as? [Double], values.count == 4
            {
                let viewport = CGRect(
                    x: values[0], y: values[1], width: values[2], height: values[3])
                if viewport.height >= min(element.native.frame.height, owner.frame.height) {
                    return viewport
                }
                continue
            }
            return frame
        }
        let candidates = containers.filter { container in
            let native = app.native.descendants(matching: container.elementType).matching(
                NSPredicate(
                    format: "identifier == %@ AND label == %@", container.identifier,
                    container.label)
            ).firstMatch
            return native.exists && native.isHittable
        }
        return candidates.max(by: {
            let first = $0.frame.intersection(window)
            let second = $1.frame.intersection(window)
            return first.width * first.height < second.width * second.height
        })?.frame
    }
    @MainActor
    func back() {
        guard let state = try? app.snapshot(),
            let bar = state.snapshots(matching: .navigationBar).last(where: {
                !$0.frame.isEmpty && state.frame.intersects($0.frame)
            })
        else {
            assertUI(false, "返回操作应使用当前可见的导航栏。")
            return
        }
        let hasPaneBack =
            state.firstSnapshot {
                $0.elementType == .button && $0.identifier == "app.pane.back"
            } != nil
        let hasBackButton =
            state.firstSnapshot {
                $0.elementType == .button && $0.identifier == "BackButton"
            } != nil
        let paneBack = app.native.buttons["app.pane.back"]
        let button = UIElement(
            hasPaneBack && paneBack.isHittable
                ? paneBack
                : hasBackButton && app.native.buttons["BackButton"].exists
                    ? app.native.buttons["BackButton"]
                    : app.native.navigationBars[bar.identifier].buttons.firstMatch)
        assertUI(button.isHittable, "当前导航栏的返回按钮应可交互。")
        button.tapBriefly()
    }

    @MainActor
    func waitForRequest(_ key: String) {
        assertUI(
            waitUntil(
                NSPredicate { _, _ in
                    UITestControlClient.request(["command": "request-state", "key": key])
                        == "pending"
                }, on: app),
            "请求应进入受控等待状态：\(key)。滚动状态：\(controlDiagnostic("scroll-inventory"))。"
        )
    }

    @MainActor
    func releaseRequest(_ key: String) {
        assertUI(
            UITestControlClient.request(["command": "release-request", "key": key]) == "released",
            "场景应释放原请求。")
    }

    @MainActor
    func tapHeader(_ element: UIElement) {
        element.tapBriefly()
    }

    @MainActor
    func textElement(_ text: String) -> UIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    @MainActor
    func tap(_ title: String) {
        if title == "取消" { dismissKeyboard() }
        let response =
            title == "取消"
            ? nil
            : UITestControlClient.request(["command": "resolve", "label": title], timeout: 5)
        if let response,
            let target = try? JSONDecoder().decode([String: String].self, from: Data(response.utf8))
        {
            let identifier = target["identifier"] ?? ""
            let label = target["label"] ?? ""
            let predicate =
                identifier.isEmpty
                ? (label == title
                    ? NSPredicate(format: "label == %@", title)
                    : NSPredicate(format: "label CONTAINS %@", title))
                : NSPredicate(format: "identifier == %@ AND label CONTAINS %@", identifier, label)
            let button = app.buttons.matching(predicate).firstMatch
            if button.exists {
                button.tapBriefly { self.reveal(button, description: title) }
                return
            }
        }
        let exact = app.buttons.matching(
            NSPredicate(format: "identifier == %@ OR label == %@", title, title))
        let exactExists = exact.firstMatch.exists
        let matches =
            exactExists
            ? exact
            : app.buttons.matching(
                NSPredicate(format: "identifier == %@ OR label CONTAINS %@", title, title))
        let button = matches.firstMatch
        if exactExists || button.exists {
            if UIElement.usesNativeInteraction ? button.native.isHittable : button.isHittable {
                button.tapBriefly()
                return
            }
            if let visible = matches.allElementsBoundByIndex.first(where: {
                UIElement.usesNativeInteraction ? $0.native.isHittable : $0.isHittable
            }) {
                visible.press(forDuration: 0.01)
                return
            }
        }
        let cardTitle = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "community.poster.card.")
        )
        .containing(.staticText, identifier: title).firstMatch.staticTexts[title]
        if cardTitle.exists {
            cardTitle.tapBriefly { self.reveal(cardTitle, description: title) }
            return
        }
        reveal(button, description: title)
        button.press(forDuration: 0.01)
    }

    func renderedLeadingTextInset(_ text: XCUIElement, in cell: XCUIElement) throws -> CGFloat {
        let screenshot = try XCTUnwrap(app.screenshot().image.cgImage)
        let window = app.windows.firstMatch.frame
        let scale = CGFloat(screenshot.width) / window.width
        let rectangle = CGRect(
            x: (cell.frame.minX - window.minX) * scale,
            y: (text.frame.minY - window.minY) * scale, width: cell.frame.width * scale,
            height: text.frame.height * scale
        ).integral
        let glyphs = try XCTUnwrap(screenshot.cropping(to: rectangle))
        let width = glyphs.width
        let height = glyphs.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let column = try pixels.withUnsafeMutableBytes { bytes -> Int in
            let context = try XCTUnwrap(
                CGContext(
                    data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(glyphs, in: CGRect(x: 0, y: 0, width: width, height: height))
            let background = (0..<3).reduce(0) { $0 + Int(bytes[height / 2 * width * 4 + $1]) }
            return try XCTUnwrap(
                (0..<width).first { x in
                    (0..<height).contains { y in
                        let brightness = (0..<3).reduce(0) {
                            $0 + Int(bytes[(y * width + x) * 4 + $1])
                        }
                        return abs(brightness - background) > 3 * 50
                    }
                })
        }
        return CGFloat(column) / scale
    }

    func assertInteractiveLabelUsesPrimaryColor(_ title: String) {
        let label = app.staticTexts[title]
        reveal(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch,
            description: "交互行")
        assertUI(label.appears(timeout: 5), "交互行应展示左侧标题：\(title)")
        guard let screenshot = app.screenshot().image.cgImage else {
            assertUI(false, "标题颜色验收应获取截图像素。")
            return
        }
        let window = app.windows.firstMatch.frame
        let scale = CGFloat(screenshot.width) / window.width
        let bounds = label.frame
        let rectangle = CGRect(
            x: (bounds.minX - window.minX) * scale, y: (bounds.minY - window.minY) * scale,
            width: bounds.width * scale, height: bounds.height * scale
        ).integral
        guard let glyphs = screenshot.cropping(to: rectangle) else {
            assertUI(false, "左侧标题应位于可见截图中：\(title)")
            return
        }
        let width = glyphs.width
        let height = glyphs.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colored = pixels.withUnsafeMutableBytes { bytes -> Int in
            guard
                let context = CGContext(
                    data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else {
                assertUI(false, "标题颜色验收应创建像素绘制上下文。")
                return 0
            }
            context.draw(glyphs, in: CGRect(x: 0, y: 0, width: width, height: height))
            return stride(from: 0, to: bytes.count, by: 4).filter { offset in
                let channels = [Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2])]
                return max(channels[0], max(channels[1], channels[2]))
                    - min(channels[0], min(channels[1], channels[2])) > 50
            }.count
        }
        assertUI(colored < 10, "\(title)的左侧字形应使用系统主文字色，当前彩色像素：\(colored)。")
    }

    @nonobjc func focusedAccessibilitySnapshot(
        _ application: UIElement,
        matching terms: [String]
    ) -> String {
        focusedAccessibilitySnapshot(application.native.debugDescription, matching: terms)
    }

    @nonobjc nonisolated func focusedAccessibilitySnapshot(
        _ description: String, matching terms: [String]
    ) -> String {
        let lines = description.split(separator: "\n")
        var seen = Set<Substring>()
        let matches = terms.flatMap { term in
            lines.filter { $0.contains(term) && seen.insert($0).inserted }
        }.prefix(24)
        return matches.isEmpty ? "界面元素树中未检索到目标文案。" : matches.joined(separator: " | ")
    }
}
