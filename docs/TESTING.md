# 测试与持续集成

## 网络冒烟测试授权边界

网络侧冒烟测试仅在用户明确指示后执行。构建、静态检查和本地离线验证属于独立操作；执行范围仍按当前任务要求决定。

## 设备使用要求

**验证环境仅使用已连接并受信任的 iOS / watchOS 真机，模拟器保持停用。**

- 验证流程排除 `simctl boot`、Simulator destination 以及任何会隐式启动模拟器的自动化操作。
- 构建、测试、安装和运行验证统一使用当前已连接并受信任的真机。
- 真机可用性是验证前提；真机不可用时停止验证并说明设备状态，验证环境保持真机要求。
- 编译检查使用 generic device destination；执行前确认命令的 destination 指向 generic device。
- 维护者、CI 脚本和自动化代理遵循同一设备要求。

## 本地工具链

工程当前使用 Xcode 27 Beta。Xcode 27 Beta 未设为系统默认开发者目录时，所有命令显式指定开发者目录：

```sh
export DEVELOPER_DIR=/Users/harrybit/Desktop/Xcode-beta.app/Contents/Developer
xcodebuild -version
```

本仓库保留系统 `xcode-select` 原配置。执行任何构建或测试前，先确认 destination 是 generic device 或当前连接的真机。

## 编译测试包

```sh
xcodebuild build-for-testing \
  -project BIT101-iOS.xcodeproj \
  -scheme BIT101-iOS \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/Tests \
  -allowProvisioningUpdates
```

## 运行真机测试

连接并信任真机后，通过 `xcodebuild -showdestinations` 获取设备 ID：

```sh
DEVICE_ID='<xcode-device-id>'

xcodebuild test \
  -project BIT101-iOS.xcodeproj \
  -scheme BIT101-iOS \
  -configuration Debug \
  -destination "platform=iOS,id=$DEVICE_ID" \
  -derivedDataPath build/Tests \
  -collect-test-diagnostics never \
  -allowProvisioningUpdates
```

2026-08-09 的历史基线为 **40 项测试全部通过，0 条编译警告/错误**；当前默认测试 Target 有 **95 项自动化用例**（89 项 Swift Testing、6 项 XCTest）。另有 5 项只在专用条件下运行的 smoke 用例。测试覆盖范围包括：

- 取消错误、页码分页、账号隔离 Codable 快照
- HTTP/社区请求构造和错误映射
- 登录启动状态、CAS HTML 解析、AES/MD5 兼容向量
- 成绩详细模式与排序
- 课程草稿/周次、空教室筛选和文案
- ICS 折行/转义/时区解析
- 课程列表与文章搜索 ViewModel 的成功、失败、取消和分页状态
- widget/watch 共享快照与时间线计算

## 真机验证

连接并信任设备后，先用 `xcodebuild -showdestinations` 获取 Xcode 设备 ID。工程已配置自动签名：

```sh
xcodebuild build \
  -project BIT101-iOS.xcodeproj \
  -scheme BIT101-iOS \
  -configuration Debug \
  -destination 'platform=iOS,id=<xcode-device-id>' \
  -derivedDataPath build/DeviceReview \
  -allowProvisioningUpdates
```

构建后可用 `xcrun devicectl device install app` 和 `device process launch` 安装、启动开发包。真机检查至少确认主 App 与 widget extension 可正常启动；登录、学校接口、通知、Live Activity 或深链场景按 `MODULE_PLAYBOOK.md` 完成人工交互回归。

也可以直接运行免参数的一键脚本：

```sh
Scripts/build-install-device.sh
```

构建后可把当前真机截图覆盖保存到固定路径：

```sh
Scripts/capture-screenshot-device.sh
```

截图固定写入 `.build/screenshot.png`；脚本支持传入设备 ID 和 Developer 目录。

脚本会自动寻找可用的 iPhone 真机；设备未连接或未信任时给出提示并退出。脚本执行内容限于 Debug 构建、安装和启动，Archive 属于脚本执行范围外。

产物路径：同一性质保持一个固定路径；构建、测试、截图和 Smoke 结果都覆盖既有路径，产物目录中每类结果保留一份。文件名格式为类别名，`latest`、设备名、时间、UUID 和序号作为额外修饰语排除；临时的 DerivedData、截图和日志在验证结束后清理。Finder 自动生成的 `.DS_Store` 属于 `.gitignore` 忽略的系统元数据，脚本处理范围外。

### Watch 与 iOS 构建说明

1. 发布使用 Xcode Archive 或 `xcodebuild archive`。
2. Debug 装机使用具体 iPhone 设备 ID。
3. Watch 单独使用 watchOS scheme/destination 构建。
4. 正式发布可行性通过发布构建结果判断；generic iOS Debug 构建结果用于调试验证。

Xcode 27 Beta 在 generic iOS Debug 构建中可能把嵌入的 Watch target 按 iOS SDK 处理，触发 Watch 图标或 watchOS API 报错；当前验证保留现有 Watch 图标和 Watch 代码。

## CI 门禁

发布前网络冒烟按依赖边界提供两个入口：

- `Scripts/release-network-smoke-bit101.sh`：BIT101 自有 API、社区/学业只读接口、网页中转、远程配置，以及自有反馈 Worker 的临时写入/读取/删除；
- `Scripts/release-network-smoke-school.sh`：学校教学中心、WebVPN、乐学、课表、成绩及可信成绩单相关链路。

### 正式 App 网络冒烟说明

`release-network-smoke.sh` 使用 Debug 构建；smoke runner 和触发路由仅编译入 Debug 构建，App Store Release 构建内容排除这两项；
它会先做一次本地构建检查，然后直接向
当前已安装并运行中的正式 App 发送 `bit101://network-smoke/<scope>?run=<uuid>`，
在同一进程内触发探针。BIT101 自有反馈 Worker 的测试数据会在同一请求内写入、读取并删除，
邮件发送量为零，远端报告保留量为零。会话来源为正式 App 当前保存的登录态、Cookie 与缓存。

脚本会把结果写到应用组目录 `group.BIT101-dev.BIT101-iOS.shared/Library/NetworkSmoke/` 下的
`release-network-smoke.json`，再由命令行读取并判断是否通过；每次运行覆盖上一份结果。

默认直接运行对应入口即可，脚本会自动寻找可用的 iPhone 真机：

```sh
Scripts/release-network-smoke-bit101.sh
Scripts/release-network-smoke-school.sh
```

仍可传入设备 ID 和 Developer 目录覆盖自动发现结果。

可信成绩单归入学校链路；当前冒烟范围为 `all`、`bit101` 和 `school` 三个值，重新认证入口归入对应范围。

CI 和其它自动化沿用同一模拟器排除要求。无真机 destination 的环境执行范围限于静态检查，静态检查保持无模拟器依赖；真机构建、测试、Widget 时间线和 Live Activity 时序按 `MODULE_PLAYBOOK.md` 人工验证。

CI 先运行 `Scripts/run-static-audit.sh`，再以 generic iOS 目标执行 `build-for-testing`；Swift 和 Clang 警告均按错误处理，构建 destination 统一为 generic iOS。版本门禁由 `Scripts/validate_versions.py` 提供，检查所有 Target/Configuration 的公开版本与 Build 是否一致、格式是否合法，以及相对 PR 基准是否倒退。在 GitHub Actions 手动运行 `iOS CI` 并打开 `release_check`，流程还会确认准备发布的公开版本高于 App Store 当前版本。

## iCloud 跨设备双向 Smoke

`BIT101-iOSTests/ManualICloudCrossDeviceSmokeTests.swift` 提供“真机 → Mac Catalyst → 真机”的双向验证，该验证仅在显式加入 `ICLOUD_CROSS_DEVICE_SMOKE` 编译条件时编译生成：

- App Target 和 Release 包均排除专用验证用例；
- 默认构建和默认测试的用例集合均排除这些用例；
- 用例通过专用脚本运行，脚本的设备目标限定为真机；
- 两端使用同一 Apple ID 和同一 BIT101 学号，真机处于解锁状态并保存过成绩缓存。

运行方式：

```sh
Scripts/run_icloud_cross_device_smoke.sh
```

脚本默认自动寻找可用的 iPhone 真机；也兼容显式传入设备 ID 和 Developer 目录。

测试会让手机临时切换“自动旋转”偏好并上传成绩缓存，Mac 收到后写回原值，最后由手机确认。正常完成或脚本异常退出时都会尝试恢复原设置、实验开关并清除协调数据；测试期间两端保持相关设置不变。

## App Store 更新提醒真机测试

工程版本号保持原值，验证使用真机。手机重新连接后，用命令行构建参数临时覆盖 Debug 包的公开版本，例如把本机伪装成 `1.7.0`：

```sh
DEVICE_ID='<xcode-device-id>'

xcodebuild build \
  -project BIT101-iOS.xcodeproj \
  -scheme BIT101-iOS \
  -configuration Debug \
  -destination "platform=iOS,id=$DEVICE_ID" \
  -derivedDataPath build/UpdatePromptTest \
  -allowProvisioningUpdates \
  MARKETING_VERSION=1.7.0 \
  CURRENT_PROJECT_VERSION=9001
```

把 `build/UpdatePromptTest/Build/Products/Debug-iphoneos/BIT101-iOS.app` 安装到真机后，依次验证：

首次 smoke 可通过 `devicectl` 仅为该次 Debug 启动传入
`BIT101_UPDATE_PROMPT_SMOKE_RESET=1`，清除更新提醒自身的查询、忽略与展示门禁；该入口受
`#if DEBUG` 保护，Release 构建排除该入口，登录、课表和其它用户数据保持不变。

1. 首次启动显示“发现新版本 1.7.1”，正文与 App Store 的开发者更新内容一致，三个操作均可见。
2. 点击“前往 App Store”，确认打开 BIT101 的中国区 App Store 页面。
3. 点击“本次忽略”，弹窗应立即关闭；强制退出并重新启动后，24 小时内提醒次数和网络查询次数均保持不变。
4. 点击“忽略此版本”，弹窗应立即关闭；超过 24 小时后 `1.7.1` 保持忽略状态，更高版本可以再次出现。
5. 卸载 Debug 包以清除其 `UserDefaults` 后重装，再断网启动；查询失败静默处理，登录和主界面保持可用。
6. 最后安装正常 `1.7.1` Debug 包；线上版本与本地版本相同时，更新提醒状态为不显示。

自动化测试覆盖数字版本比较、24 小时查询节流、24 小时展示冷却、更新内容缓存、失败静默和“忽略此版本”。真机可用性恢复前，验证范围限于 static/generic-device 编译；实际弹窗和 App Store 跳转在真机恢复后执行。

## 学期滚动缓存与手动同步

- App 启动只恢复本地课表/成绩缓存，学校和 WebVPN 请求数为 0；课表同步、DDL、空教室和成绩查询均由用户主动操作触发。
- 课表手动同步仍按 3 月 1 日、9 月 1 日推导当前及下一学期，并保存两份转换后的完整快照（首周、课程、考试）。
- 学校返回的首周日期优先于日历分界；新学期快照尚无课程/考试时，当前课表保持原值。
- 手动同步返回非空但课程数少于本机时，应弹出“本机有 X 节课，获取到 Y 节课，是否替换？”；选择“否”保留原课表，选择“是”才替换。空响应或学校明确未发布时，确认弹窗保持关闭。
- 学校明确返回“课表未发布”时显示状态提示；版本号保持原值，错误上报入口保持关闭。
- 手动选择学期先更新当前学期；随后课表请求失败仍保留该选择并显示错误，已有快照继续展示；没有快照时，旧学期课程保持隐藏。
- 本地缓存可自动切换到已开始的新学期，该切换只读取本地缓存，学校请求数保持为 0；手动周次浏览范围超过课程最后一周，按首周日期定位时结果范围为第 -12 至 +20 周。
- 成绩页进入时恢复本地缓存；认证由点击“查询成绩”、刷新按钮或下拉刷新触发。验证码挑战展示在当前操作链路中，错误报告弹窗保持关闭。
- 点击进入空教室分栏即开始加载；“刷新空教室”、切换校区/教学楼或下拉刷新用于再次查询。认证需要短信时展示验证码面板，重试流程保持显式。
- DDL 同步由用户主动触发，启动和前台阶段的静默同步请求数为 0；用户主动同步遇到学校短信二次验证时，显示“需要短信验证”提示，错误报告入口保持关闭。
- 真机 smoke 应确认冷启动、回前台和切换账号时学校/WebVPN 请求数均为 0；显式同步和验证码续接仍需单独验证。

## 系统日历导入

- 验证入口限定为真机的“我的－设置－课程表设置”，验证设备为真机。
- 首次导入应请求完整日历权限，并创建“BIT101 课表”日历；课程日期、起止时间、地点应与当前学期一致。
- 同一学期连续导入两次，事件数量保持单份；第二次应替换带 `bit101://calendar-course/` 标记的旧事件。
- “删除已导入的日历事件”限定为 BIT101 标记事件，用户自己创建的日程保持不变。
- 拒绝权限、无课表或没有已导入事件时，系统给出可理解的错误提示并继续运行。

## 成绩详细信息缓存

- 每次成绩刷新仍先获取简略列表；比较范围为除“序号、操作栏”外的简略字段，比较方式为无序比较。
- 新增、删除、分数或其它简略字段变化时必须重新获取详细信息。
- 简略列表未变化，且最新学期已知教学班状态全部为“是”时，直接复用详细缓存。
- 简略列表未变化但仍存在“否”时，详细查询按账号限制为 24 小时最多一次。
- 主动下拉刷新优先级最高，直接绕过详细缓存并完整查询简略与详细成绩。

## 错误报告

```sh
Scripts/check-error-report-coverage.sh
Scripts/error-reports.sh list
Scripts/error-reports.sh latest
Scripts/error-reports.sh delete '<report-key>'
Scripts/fetch-issues-and-reports.sh
Scripts/run-static-audit.sh
Scripts/run-extended-tests.sh
```

覆盖检查确保用户可见的错误弹窗和主要失败占位页保留 App Store 与错误报告入口。
报告直接通过当前 Wrangler 登录读取远端 KV，管理网页不参与流程。
`Scripts/fetch-issues-and-reports.sh` 会用当前 GitHub CLI 和 Wrangler 登录状态，一次拉取未关闭的仓库 Issues 与 Cloudflare KV 报告，保存到 `.build/issue-report-inbox` 并输出简要汇总。错误报告按 `本次/上次/上上次` 保留三批，并按 `开发版/正式版/来源未知` 和 `错误报告/用户建议` 分类；Debug 构建提交 `isDevelopmentBuild: true`，Release 构建提交 `false`，旧报告归入来源未知。输出本次详情，只输出上两批数量。本次没有新报告时显示最近一批详情。完整拉取成功后只清理本次已拉取的 Cloudflare 报告，失败时保留远端数据。完整报告仅保存在本机，仓库保持不变。

`run-static-audit.sh` 仅执行静态检查；学校接口连接、网络 smoke 和 Archive 均在执行范围外。它按 Swift、Shell、Python、Worker、Git、文档、UI、触感、组件和源码质量规则输出结果；源码质量报告固定覆盖 `.build/code-quality-report.txt`。CI 强制执行这一入口，并额外阻止警告进入构建门禁。

UI 契约检查由 `check-ui-consistency.py` 统一维护：页面和公共组件按目录模式、页面后缀及公共组件用法自动发现，再套用同类契约；`check-component-consistency.sh` 的职责是转发到统一检查器，业务文件清单由统一检查器维护。新增同类页面沿用现有检查逻辑，契约表登记的必要平台/功能例外可跳过规则。

## 扩展自动化测试

扩展测试使用 `EXTENDED_AUTOMATION` 条件编译，默认测试和 Release 包均排除这些用例。运行：

```sh
Scripts/run-extended-tests.sh
```

脚本在真机上分组执行 27 项课程表策略、基础设施和登录状态测试；未连接真机时直接提示，模拟器保持停用。测试日志保存在 `.build/extended-automation`。
