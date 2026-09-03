# BIT101-iOS 维护手册

这份文档面向“准备继续维护这个仓库的人”，重点不是介绍功能，而是说明：

- 如何构建
- 哪些 target 需要一起看
- 哪些数据是按账号隔离的
- 小组件、锁屏组件和 Live Activity 的维护边界是什么
- 遇到问题时，应该先从哪一层排查

## 1. 工程组成

当前工程包含四个 target：

- 主 App：`BIT101-iOS`
- iOS 扩展：`BIT101ScheduleWidget`
- Watch App：`BIT101Watch`
- Watch 扩展：`BIT101WatchWidgets`

相关 bundle identifier：

- 主 App：`BIT101-dev.BIT101-iOS`
- Widget 扩展：`BIT101-dev.BIT101-iOS.ScheduleWidget`
- Watch App：`BIT101-dev.BIT101-iOS.watchkitapp`
- Watch Widget：`BIT101-dev.BIT101-iOS.watchkitapp.widgets`

相关共享容器：

- `group.BIT101-dev.BIT101-iOS.shared`

相关 URL Scheme：

- `bit101`

## 2. 构建与运行

### 2.1 日常开发建议

如果只是改主 App 内部逻辑，可以先做一次主工程构建确认。

如果改动涉及下面这些内容，必须连扩展一起看：

- 课表数据结构
- 小组件快照导出
- 锁屏组件
- Live Activity / 灵动岛
- App Group 相关路径

### 2.2 命令行构建

当前仓库常用的命令行构建方式是：

```bash
xcodebuild \
  -project BIT101-iOS.xcodeproj \
  -scheme BIT101-iOS \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  build
```

如果命令行看不到可用真机，`generic/platform=iOS` 是更稳的兜底方案。

当前工程使用 Xcode 27 的单 Watch App target 结构。完整构建 `BIT101-iOS` scheme 时，
依赖图会同时构建并嵌入 iOS widget、Watch App 和 Watch widget；旧式
`BIT101WatchExtension` target 已删除。

### 2.3 真机调试

真机调试经常还要同时注意：

- 签名是否有效
- 扩展 target 是否也签上了
- App Group entitlement 是否仍然一致
- Live Activities 是否还在 Info.plist / target settings 中启用

## 3. 本地状态与持久化

项目当前本地状态来源主要有四类。

### 3.1 Keychain

用于保存：

- 学校统一认证账号密码
- 与登录恢复相关的敏感信息

相关入口：

- `Login/LoginStorage.swift`
- `Login/LoginService.swift`

其中学号和密码存入 Keychain，`fake-cookie` 和安装标记存入 `UserDefaults`，学校认证
cookie 由系统 `HTTPCookieStorage` 管理。不要把这三类状态笼统地当成 Keychain 数据。

bit-login 返回的 `challenge_id`、access token、短信状态和教学中心准备状态不属于长期凭据：
它们只保存在对应 `Service` / `ViewModel` 的内存中，退出、切号、过期或收到明确失效响应后即丢弃。

### 3.2 UserDefaults

用于保存：

- 全局设置
- 账号隔离设置快照
- 话廊相关偏好
- 一些查询筛选偏好

相关入口：

- `Settings/AppSettingsStore.swift`

### 3.3 本地缓存文件

用于保存：

- 课表
- DDL
- 考试
- 自定义日程

基础成绩列表另存于按学号分桶的 `UserDefaults`；可信成绩单图片不落盘。

相关入口：

- `Schedule/ScheduleCacheStore.swift`
- `Schedule/ScheduleModels.swift`

课表缓存可按用户开关同步到 CloudKit 私有数据库，记录仍按当前学号隔离。实验性的偏好同步则
使用 iCloud Key-Value Store，覆盖设置、成绩筛选与缓存、话廊消息已读状态；两套同步机制不要混用。

相关入口：

- `Schedule/ScheduleCloudSyncManager.swift`
- `Shared/Infrastructure/ExperimentalPreferenceCloudSync.swift`

### 3.4 App Group 共享快照

用于保存：

- 提供给 widget / 锁屏组件 / Live Activity 的精简课表快照

相关入口：

- `Schedule/ScheduleWidgetSupport.swift`
- `BIT101ScheduleWidget/BIT101ScheduleWidget.swift`

### 3.5 覆盖更新与本地数据保留

如果用户只是从旧版本直接升级到新版本，当前实现里下面这些本地数据默认都应保留：

- `Application Support` 里的日程缓存
- `UserDefaults` 里的设置快照
- Keychain 里的账号密码

其中和“别人分享的课表”最相关的是日程缓存：

- 分享课表会进入 `ScheduleCache.sharedSchedules`
- 缓存文件按账号写到 `Application Support/BIT101-iOS/<account>/schedule-cache.json`
- 升级不会主动清这一层

所以正常覆盖更新后，分享课表理论上仍应存在。

### 3.6 哪些操作会清掉本地数据

下面这些行为才会真的把本地数据打掉：

1. 卸载再安装（首次启动会根据安装标记清理 Keychain 中可能残留的旧账号密码）
2. 设置页执行“删除所有文稿与数据”
3. 开发时手动清空 App 沙盒
4. 某次版本升级引入了破坏性迁移 bug

如果你改动了下面这些内容，发版前最好专门验证一次升级路径：

- `ScheduleCache`
- `AppSettingsSnapshot`
- 登录恢复相关本地状态
- 分享课表导入 / 删除 / 重命名逻辑

最简单的验证方式不是看代码，而是：

1. 用旧版本造一份真实本地数据
2. 包括主课表、至少一份分享课表、DDL 和设置项
3. 直接覆盖安装新版本
4. 真机确认这些数据是否都还在

## 4. 账号隔离的维护原则

当前项目已经做了账号隔离，但这部分非常容易在后续修改时被破坏。

新增设置或缓存前，先问自己：

- 这是设备级偏好，还是账号级偏好
- 切换账号后，它应该跟着变吗
- 退出登录后，这个状态应该保留吗

如果答案偏向“跟账号走”，就不要把它写成全局唯一 key。

目前至少这几类已经按账号隔离：

- 课表 / DDL 缓存
- 一部分查询和筛选偏好

## 5. 小组件、锁屏组件与 Live Activity

### 5.1 修改课表模型时要注意什么

如果你改了主 App 内部的课表结构，不代表 widget 会自动跟上。

因为当前链路是：

1. 主 App 维护完整课表缓存
2. `ScheduleWidgetSupport` 导出精简快照
3. Widget 和 Live Activity 只读快照

所以任何课表结构变化，都要同步检查：

- `ScheduleWidgetSupport.swift`
- `BIT101ScheduleWidget.swift`
- `ScheduleLiveActivityManager.swift`

### 5.2 修改灵动岛提醒时要注意什么

灵动岛不是“独立的数据系统”，而是“基于当前课表和自定义日程计算出的当前项 / 下一项提醒”。

当前提醒逻辑依赖：

- 当前账号的课表缓存
- 自定义日程
- 提前显示阈值

所以如果你看到灵动岛显示异常，不要只盯 widget 代码，先确认：

- 当前账号的课表缓存是否正确
- 快照是否同步出去
- 提前显示阈值是不是把提醒压掉了

### 5.3 锁屏组件与桌面组件

它们虽然共享同一批快照，但展示目标不同：

- 桌面组件强调“下一节 / 后续几节”
- 锁屏组件强调高密度、低字数

后续如果要继续改排版，不要试图用一套视图硬凑所有 family。

## 6. 话廊模块维护建议

### 6.1 分页与刷新

话廊最容易出体验问题的地方不是卡片 UI，而是：

- 刷新后丢位置
- 预取时机不对
- 推荐流去重和过滤
- 可见列表与原始列表错位

维护分页时要区分三个概念：

- 原始服务端返回列表
- 本地过滤后的可见列表
- 当前屏幕上真正处于尾部的触发项

### 6.2 消息中心

消息中心当前的“新消息”不是服务端逐条已读，而是客户端根据分类未读数做的本地近似表现。

这意味着：

- 不要把它误当成强一致的消息系统
- 跨设备同步不保证完全准确
- 但本地体验可以通过“全部已读”“单条点开即清除”保持顺手

## 7. 地图维护建议

地图页由 SwiftUI 页面和原生 MapKit 桥接层组成，目前不依赖 `MKMapView` 的私有子视图层级。
出现问题时按职责检查：

- 页面状态、校区切换：`Map/CampusMapScreen.swift`
- 地图相机、用户定位、下一节课标记：`Map/CampusNativeMapView.swift`
- 校区坐标和地点别名：`Map/CampusMapLocations.swift`
- 下一节课地点解析：`Map/UpcomingCourseMapResolver.swift`

系统升级后不要通过隐藏或改写 attribution、legal label、logo 等内部子视图来修显示问题；
这类实现依赖私有层级，容易随 MapKit 版本失效。

## 8. 常见排查路径

### 8.1 登录失败

先区分两条链路：

1. App 登录：BIT101 / bit-login 的登录、注册与 `fake-cookie` 获取是否失败
2. 学校 SSO 恢复：本地凭据、学校 CAS 参数或 cookie 恢复是否失败

学校 CAS 不是每次 App 登录都必经的前台步骤，主要用于需要学校身份时的静默恢复。

排查登录态检查时，要先区分“明确失效”和“暂时无法确认”：

- 明确失效：例如 BIT101 `/user/check` 返回 401，或学校 CAS 静默重登明确失败，可以清本地 session。
- 暂时无法确认：例如网络错误、学校登录页结构异常、临时拿不到 `salt` / `execution`、本地缺少静默恢复凭据，不应直接清 `fake-cookie`。

原因是 `fake-cookie` 为空会触发共享课表快照导出为未登录，进而让 widget / Apple Watch 一起显示未登录。

如果 App/BIT101 登录正常，但课表、成绩或空教室要求短信验证码，应转到 bit-login 链路排查：

1. 普通成绩是否请求 `jwb`
2. 可信成绩单是否请求独立的 `jwb_cjd`
3. 课表与空教室的教学中心 session 是否绑定当前学号
4. challenge 是否已过期、被重复提交，或仍停在 `running/processing`

### 8.2 课表 / 成绩 / 空教室异常

先分清是：

- 本地缓存恢复异常
- 服务端接口变了
- 查询偏好把结果筛掉了
- 学校接口返回登录页、401/403 或非 JSON，触发了教学中心 session 恢复
- 目标学期尚未发布课表（这种情况应显示空课表，而不是阻断式错误）

学期列表必须以学校接口实际返回值为准；不要为了“方便”在客户端推算或补充未来学期。
手动修改首周日期时必须归一化到周一。

### 8.3 小组件没更新

先看：

1. 主 App 课表是否正确
2. 共享快照是否导出成功
3. Widget 是否读到了共享容器
4. 当前 family 是否命中正确布局

### 8.4 灵动岛不显示

先看：

1. 设备是否支持
2. 开关是否开启
3. 提前显示阈值是否太小
4. 当前是不是根本没有“当前项 / 下一项”

## 9. 更新文档的约定

后续如果你改动了下面这些内容，建议同步更新文档：

- tab 结构
- 账号隔离策略
- 小组件 / 锁屏组件 / Live Activity 行为
- 话廊 feed 结构
- 设置页结构
- 主要模块职责边界

最少要同步更新：

- `README.md`
- `docs/CODEBASE_GUIDE.md`

如果改动已经影响维护方式，还要同步更新：

- `docs/MAINTENANCE_GUIDE.md`
- `docs/FILE_INDEX.md`
# 维护边界

- 本项目维护者仅负责 BIT101 iOS 客户端。
- 不拥有 BIT101 相关域名，也不是服务端维护者；服务端问题应提交 issue 或联系服务端维护团队。
- 仅拥有 `aihelpme.dev` 及其相关资源。
