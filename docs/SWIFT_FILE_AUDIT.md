# Swift 源码审查结论

更新时间：2026-09-22

## 审查范围

审查覆盖主 App、Widget、Watch App、Watch Widget 与测试 target 的 Swift 源码，逐文件阅读实现与注释，重点核对：

- 死代码、重复流程和与当前实现脱节的说明。
- SwiftUI/UIKit/WebKit/MapKit/WidgetKit/WatchConnectivity 的职责边界。
- 设计系统令牌、公共组件、动态字体与跨设备布局。
- 网络、认证、缓存、账号切换、任务取消和跨 target 数据传输。
- 无障碍语义、错误状态与现有测试覆盖。

## 结论

### UI 与平台实现

- 页面以 SwiftUI 原生视图组合为主。
- UIKit 桥接对应系统菜单定位、线性课表缩放、动态字体测量、系统分享、富文本编辑和键盘处理。
- MapKit 提供地图相机、定位和 overlay；Quick Look 提供图片预览；ImageIO 解码 GIF。
- 话廊原生入口与可选 WKWebView 入口分别保留明确页面职责。
- 主 App 公共令牌集中在 `Shared/DesignSystem/AppDesignSystem.swift`；基础刻度位于 `DesignPrimitives.swift`；模块特化参数位于 Course、Schedule、Gallery 目录。

### 客户端工程结构

- `Shared/Client` 集中 HTTP、社区 API、账号存储、取消识别、日期、诊断和错误呈现入口。
- 业务 Service 维护认证上下文与接口规则，ViewModel 管理页面状态，View 承载交互和呈现。
- 账号切换路径按账号代际隔离异步任务、缓存和弹窗。
- Widget、Watch 与 Live Activity 通过共享课表快照和稳定编解码协议读取数据。

### 主要回归覆盖

- 成绩刷新、空数据、缓存复用和验证码续接。
- 课表同步、学期偏移、课程编辑、日历导入和空教室筛选。
- CAS 登录页面解析、Challenge 状态和认证错误分类。
- 社区分页、评论、图像缓存、用户过滤和刷新取消。
- CloudKit 账号隔离、共享快照编解码、Widget/Watch 时间线与 Live Activity 状态。
- 错误报告脱敏、日期格式化、公共组件和代码质量契约。

## 维护入口

- 视觉、组件、触感与错误报告入口：`docs/DESIGN_SYSTEM.md`、`Scripts/check-ui-consistency.sh`。
- 客户端基础能力：`docs/ARCHITECTURE.md`、`docs/NETWORKING.md`、`docs/STATE_AND_STORAGE.md`。
- 全量 Swift 源码维护：`Scripts/check-code-quality.sh`。
- 自动化测试：`docs/TESTING.md` 与 `Scripts/run-extended-tests.sh`。
- 当前文件职责：`docs/FILE_INDEX.md`。
