# BIT101-iOS 维护手册

这份文档面向后续维护 BIT101-iOS 仓库的人员，说明：

- 构建方式
- 需要联动检查的 target
- 按账号隔离的数据
- 小组件、锁屏组件和 Live Activity 的维护边界
- 问题排查的层级顺序

## 1. 工程组成

当前工程包含四个 target：

- 主 App：`BIT101-iOS`
- iOS 扩展：`BIT101ScheduleWidgets`
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

### 2.1 日常开发

改动限于主 App 内部逻辑时，先构建主工程确认。

改动涉及以下内容时，同时检查扩展 target：

- 课表数据结构
- 小组件快照导出
- 锁屏组件
- Live Activity / 灵动岛
- App Group 相关路径

### 2.2 命令行构建

当前仓库常用的命令行构建命令如下：

```bash
xcodebuild \
  -project BIT101-iOS.xcodeproj \
  -scheme BIT101-iOS \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  build
```

命令行未发现可用真机时，使用 `generic/platform=iOS` 作为构建目标。

当前工程使用 Xcode 27 的单 Watch App target 结构。完整构建 `BIT101-iOS` scheme 时，
依赖图同时构建并嵌入 iOS widget、Watch App 和 Watch widget；旧式
`BIT101WatchExtension` target 已删除。

### 2.3 真机调试

真机调试同时核对：

- 签名状态
- 扩展 target 签名状态
- App Group entitlement 一致性
- Live Activities 在 Info.plist / target settings 中的启用状态

## 3. 本地状态与持久化

项目当前本地状态来源主要有四类。

### 3.1 Keychain

Keychain 保存以下数据：

- 学校统一认证账号密码
- 与登录恢复相关的敏感信息

对应入口包括：

- `Login/LoginStorage.swift`
- `Login/LoginService.swift`

学号和密码存入 Keychain；`fake-cookie` 和安装标记存入 `UserDefaults`；学校认证 cookie
由系统 `HTTPCookieStorage` 管理。维护和排查时按这三类存储分别处理。

bit-login 返回的 `challenge_id`、access token、短信状态和教学中心准备状态属于短期状态。
对应 `Service` / `ViewModel` 仅在内存中保存这些状态；退出、切号、过期或收到明确失效响应时，
系统丢弃这些状态。

### 3.2 UserDefaults

UserDefaults 保存以下数据：

- 全局设置
- 账号隔离设置快照
- 话廊相关偏好
- 一些查询筛选偏好

对应入口包括：

- `Settings/AppSettingsStore.swift`

### 3.3 本地缓存文件

本地缓存文件保存以下数据：

- 课表
- DDL
- 考试
- 自定义日程

基础成绩列表另存于按学号分桶的 `UserDefaults`；可信成绩单图片不落盘。

对应入口包括：

- `Schedule/ScheduleCacheStore.swift`
- `Schedule/ScheduleModels.swift`

课表缓存可按用户开关同步到 CloudKit 私有数据库，记录仍按当前学号隔离。实验性的偏好同步
使用 iCloud Key-Value Store，覆盖设置、成绩筛选与缓存、话廊消息已读状态。课表缓存同步和
偏好同步按用途分别使用两套机制。

对应入口包括：

- `Schedule/ScheduleCloudSyncManager.swift`
- `Shared/Infrastructure/ExperimentalPreferenceCloudSync.swift`

### 3.4 App Group 共享快照

App Group 共享快照保存以下数据：

- 提供给 widget / 锁屏组件 / Live Activity 的精简课表快照

对应入口包括：

- `Schedule/ScheduleWidgetSupport.swift`
- `BIT101ScheduleWidgets/BIT101ScheduleWidgets.swift`

### 3.5 覆盖更新与本地数据保留

用户从旧版本直接升级到新版本时，当前实现默认保留以下本地数据：

- `Application Support` 里的日程缓存
- `UserDefaults` 里的设置快照
- Keychain 里的账号密码

分享课表相关数据位于日程缓存：

- 分享课表会进入 `ScheduleCache.sharedSchedules`
- 缓存文件按账号写到 `Application Support/BIT101-iOS/<account>/schedule-cache.json`
- 升级不会主动清这一层

按当前实现，正常覆盖更新后的分享课表应继续存在。

### 3.6 本地数据清除条件

以下行为触发本地数据清除：

1. 卸载再安装（首次启动会根据安装标记清理 Keychain 中可能残留的旧账号密码）
2. 设置页执行“删除所有文稿与数据”
3. 开发时手动清空 App 沙盒
4. 某次版本升级引入了破坏性迁移 bug

改动以下内容时，发版前验证升级路径：

- `ScheduleCache`
- `AppSettingsSnapshot`
- 登录恢复相关本地状态
- 分享课表导入 / 删除 / 重命名逻辑

升级路径通过实际覆盖安装验证，步骤如下：

1. 用旧版本造一份真实本地数据
2. 包括主课表、至少一份分享课表、DDL 和设置项
3. 直接覆盖安装新版本
4. 在真机确认这些数据仍然存在

## 4. 账号隔离的维护原则

账号隔离已覆盖当前实现，后续修改需要保持这一边界。

新增设置或缓存时，先确认以下作用域关系：

- 设备级偏好与账号级偏好的归属
- 切换账号后的状态变化
- 退出登录后的状态保留范围

状态随账号变化时，按账号保存并为每个账号使用独立 key。

当前至少以下数据按账号隔离：

- 课表 / DDL 缓存
- 一部分查询和筛选偏好

## 5. 小组件、锁屏组件与 Live Activity

### 5.1 修改课表模型时要注意什么

主 App 内部课表结构变化时，维护者同步检查 widget 导出链路。

当前链路如下：

1. 主 App 维护完整课表缓存
2. `ScheduleWidgetSupport` 导出精简快照
3. Widget 和 Live Activity 只读快照

课表结构变化时，同步检查：

- `ScheduleWidgetSupport.swift`
- `BIT101ScheduleWidgets.swift`
- `ScheduleLiveActivityManager.swift`

### 5.2 修改灵动岛提醒时要注意什么

灵动岛的数据来源是当前账号的课表缓存和自定义日程，系统依据提前显示阈值计算当前项与下一项提醒。

灵动岛显示异常时，按以下顺序核对：

- 当前账号的课表缓存
- 快照同步状态
- 提前显示阈值对提醒的影响

### 5.3 锁屏组件与桌面组件

桌面组件和锁屏组件共享同一批快照，展示目标分别为：

- 桌面组件强调“下一节 / 后续几节”
- 锁屏组件强调高密度、低字数

后续调整排版时，按 family 分别维护视图。

## 6. 话廊模块维护建议

### 6.1 分页与刷新

话廊的主要体验风险集中在以下环节：

- 刷新后丢位置
- 预取时机不对
- 推荐流去重和过滤
- 可见列表与原始列表错位

维护分页时要区分三个概念：

- 原始服务端返回列表
- 本地过滤后的可见列表
- 当前屏幕上真正处于尾部的触发项

### 6.2 消息中心

消息中心当前的“新消息”状态由客户端根据分类未读数计算，属于本地近似状态；服务端
不提供逐条已读状态。

维护时按以下边界处理：

- 该状态用于本地消息展示，强一致消息系统语义属于当前边界之外
- 跨设备同步结果允许存在偏差
- 本地体验通过“全部已读”“单条点开即清除”维持当前交互行为

## 7. 地图维护建议

地图页由 SwiftUI 页面和原生 MapKit 桥接层组成，目前不依赖 `MKMapView` 的私有子视图层级。
出现问题时按职责检查：

- 页面状态、校区切换：`Map/CampusMapScreen.swift`
- 地图相机、用户定位、下一节课标记：`Map/CampusNativeMapView.swift`
- 校区坐标和地点别名：`Map/CampusMapLocations.swift`
- 下一节课地点解析：`Map/UpcomingCourseMapResolver.swift`

系统升级后的显示问题按公开接口路径排查。attribution、legal label、logo 等内部子视图
属于私有层级，相关实现会随 MapKit 版本变化而失效。

## 8. 常见排查路径

### 8.1 登录失败

登录失败按以下两条链路定位：

1. App 登录：核对 BIT101 / bit-login 的登录、注册与 `fake-cookie` 获取链路
2. 学校 SSO 恢复：核对本地凭据、学校 CAS 参数与 cookie 恢复链路

App 登录流程按需调用学校 CAS，学校 CAS 主要承担需要学校身份时的静默恢复。

登录态检查按“明确失效”和“暂时无法确认”两类处理：

- 明确失效：例如 BIT101 `/user/check` 返回 401，或学校 CAS 静默重登明确失败；此时清理本地 session。
- 暂时无法确认：例如网络错误、学校登录页结构异常、临时拿不到 `salt` / `execution`、本地缺少静默恢复凭据；此时保留 `fake-cookie`。

空的 `fake-cookie` 会触发共享课表快照导出为未登录，进而让 widget / Apple Watch 一起显示未登录。

App/BIT101 登录正常且课表、成绩或空教室流程要求短信验证码时，排查 bit-login 链路：

1. 核对普通成绩是否请求 `jwb`
2. 核对可信成绩单是否请求独立的 `jwb_cjd`
3. 核对课表与空教室的教学中心 session 是否绑定当前学号
4. 核对 challenge 是否已过期、被重复提交，或仍停在 `running/processing`

### 8.2 课表 / 成绩 / 空教室异常

课表 / 成绩 / 空教室异常按以下类别定位：

- 本地缓存恢复异常
- 服务端接口发生变化
- 查询偏好筛除结果
- 学校接口返回登录页、401/403 或非 JSON，触发了教学中心 session 恢复
- 目标学期尚未发布课表时，界面显示空课表，错误处理保持非阻断

学期列表以学校接口实际返回值为准；客户端仅展示接口返回的学期范围，未来学期通过学校接口发布后显示。
手动修改首周日期时必须归一化到周一。

### 8.3 小组件未更新

按以下顺序确认：

1. 确认主 App 课表状态
2. 确认共享快照导出状态
3. 确认 Widget 读取的共享容器
4. 确认当前 family 命中的布局

### 8.4 灵动岛未显示

按以下顺序确认：

1. 确认设备支持状态
2. 确认开关状态
3. 确认提前显示阈值对提醒的影响
4. 确认当前项 / 下一项存在情况

## 9. 更新文档的约定

后续改动以下内容时，同步更新文档：

- tab 结构
- 账号隔离策略
- 小组件 / 锁屏组件 / Live Activity 行为
- 话廊 feed 结构
- 设置页结构
- 主要模块职责边界

至少同步更新：

- `README.md`
- `docs/CODEBASE_GUIDE.md`

如果改动已经影响维护方式，还要同步更新：

- `docs/MAINTENANCE_GUIDE.md`
- `docs/FILE_INDEX.md`

## 10. 维护边界

- 本项目维护者负责 BIT101 iOS 客户端。
- BIT101 相关域名和服务端属于本项目维护范围之外；服务端问题提交 issue 或联系服务端维护团队。
- 本项目维护者拥有 `aihelpme.dev` 及其相关资源。
