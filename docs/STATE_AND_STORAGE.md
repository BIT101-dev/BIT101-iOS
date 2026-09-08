# BIT101-iOS 状态与存储说明

本文说明项目状态的存储位置。

本文涵盖以下场景：

- 切换账号后，部分状态随账号变化，部分状态沿用原值
- 小组件获取的数据与主 App 数据存在差异
- 应用将值存储在 `UserDefaults`、Keychain、文件缓存或共享容器中
- 偏好变更后，另一个页面可能延迟生效

## 1. 状态分类总览

项目状态按用途分为七类：

1. 会话与凭据
2. 模块业务缓存
3. 界面偏好
4. 账号隔离偏好
5. 扩展共享快照
6. 页面级瞬时状态
7. 学校业务的短期认证状态

## 2. 会话与凭据

### 2.1 保存内容

会话与凭据包括：

- 学校统一认证账号
- 学校统一认证密码
- 与登录恢复相关的敏感凭据
- BIT101 侧会话恢复所需信息

### 2.2 保存位置

这些状态分布在以下存储中：

- 学号、密码：Keychain
- BIT101 `fake-cookie`、安装标记：`UserDefaults`
- 学校认证 cookie：系统 `HTTPCookieStorage`

相关代码主要在：

- `Login/LoginStorage.swift`
- `Login/LoginService.swift`

### 2.3 维护原则

- 敏感信息始终使用 Keychain，普通 `UserDefaults` 承载非敏感状态
- 登录链路调整字段名或恢复逻辑时，维护者先确认旧 Keychain 迁移是否兼容
- 卸载时系统清除安装标记，Keychain 可能由系统保留；重装后首次创建 `LoginStorage` 时，系统据此主动清理旧学号和密码。
- 登录态检查将“无法确认”保留为待确认状态。网络不稳、学校页面解析失败、缺少静默恢复材料等情况保留本地 session 并向上抛错；远端明确返回凭据无效时，系统清除 `fake-cookie`、cookie 和本地密码。
- `fake-cookie` 为空时，外部课表快照将其导出为 `isLoggedIn = false`，并同步到 widget / Apple Watch。登录检查的清除策略决定手表端是否显示“请先登录”。

### 2.4 学校业务的短期认证状态

课表、成绩、空教室和可信成绩单通过 bit-login 使用短期 challenge，包括
`challenge_id`、access token、短信状态、掩码手机号和有效期。教学中心认证状态和当前
准备状态按当前学号绑定，并以业务会话为范围。

这些值的存储范围是 `ScheduleService`、`ScoreService` 和对应 ViewModel 的内存属性：

- 这些值随内存属性管理，Keychain 和 `UserDefaults` 的写入范围排除这些值
- 系统在退出、切号、过期或收到明确失效响应时立即使这些值失效
- challenge 过期或重复提交后进入失效状态
- 普通成绩使用 `jwb` challenge，可信成绩单使用独立的 `jwb_cjd` challenge

## 3. 课表、DDL、考试与自定义日程

### 3.1 保存内容

- 课程表
- 考试
- DDL
- 自定义日程
- 一些查询所需的本地上下文

### 3.2 保存位置

这类数据主要存储于：

- 本地缓存文件

相关代码主要在：

- `Schedule/ScheduleCacheStore.swift`
- `Schedule/ScheduleModels.swift`
- `Schedule/ScheduleViewModel.swift`

### 3.3 特点

- 系统先恢复缓存，再同步远端
- 系统按账号隔离保存这类数据
- 切号后，系统按当前账号加载课表

### 3.4 覆盖更新与本地课表

按正常的 App 覆盖更新流程，这一层数据继续保留。

当前日程模块的主缓存存储在当前账号对应的本地文件中：

- `ScheduleCacheStore` 会把缓存写到 `Application Support/BIT101-iOS/<account>/schedule-cache.json`
- 这份缓存包含主课表、考试、DDL、自定义日程和导入的分享课表
- 导入别人分享的课表后，本地记录会进入 `sharedSchedules`

用户直接升级新版本、保留 App 安装状态和本地数据时，“别人分享给我的课表”原则上随缓存保留。

### 3.5 分享课表的导入范围

分享课表的导入流程追加一份只读课表，当前日程数据保持原有内容。

导入流程解析的载荷字段限定为：

- 学期、首周、时间表和课程

导入流程随后执行以下动作：

- 将载荷包装成一条 `SharedScheduleRecord`
- 将记录追加进当前账号的 `sharedSchedules`

以下数据在导入后保持原值：

- 当前账号主课表
- DDL
- 考试
- 自定义日程
- 课表显示偏好

分享课表作为当前账号本地收藏的只读记录保存。

### 3.6 本地数据消失条件

本地数据可能在以下情况消失：

1. 用户卸载后重装
2. 用户在设置里执行“删除所有文稿与数据”
3. 某次未来版本修改了缓存结构，兼容解码缺失
4. 开发时手动删除了 `Application Support` 或 `UserDefaults` 内容

维护时优先检查第 3 点。

当前 `ScheduleCache` 的解码策略大量使用“缺字段就回默认值”的兼容写法，常见的“新增字段”通常兼容旧缓存。未来修改字段语义、字段类型或关键结构时，需要明确迁移策略。

### 3.7 iCloud 课表同步

用户开启课表 iCloud 同步后，`ScheduleCloudSyncManager` 会把当前账号的完整
`ScheduleCache` 同步到 CloudKit 私有数据库：

- 记录按学号隔离
- 同步管理器按本地与云端的 `updatedAt` 应用较新版本或上传本地版本
- 关闭 `iCloudSyncEnabled` 后，管理器停止拉取和上传
- App 和扩展导出流程直接读取本地文件缓存，CloudKit 承载云端同步

相关代码主要在：

- `Schedule/ScheduleCloudSyncManager.swift`
- `Schedule/ScheduleCacheStore.swift`

## 4. 设置与偏好

### 4.1 保存内容

包括但不限于：

- 外观模式
- 自动旋转
- 灵动岛提前显示阈值
- 一部分查询筛选结果

### 4.2 保存位置

偏好主要存储于：

- `UserDefaults`
- 通过 `AppSettingsStore` 做统一读写

相关代码主要在：

- `Settings/AppSettingsStore.swift`

### 4.3 两类偏好的区别

#### 4.3.1 全局偏好

例如：

- 主题模式
- 屏幕旋转

这类偏好按全局设置保存，账号切换时沿用原值。

#### 4.3.2 账号隔离偏好

例如：

- 一部分查询筛选
- 成绩列表缓存、学期/种类筛选与排序偏好
- 普通帖子页面是否隐藏机器人帖子（搜索、推荐、关注、个人主页等；机器人分栏除外）

这类偏好按账号分桶保存。

可信成绩单的图片采用 ephemeral URLSession 从学校生成的短期 URL 下载，并由申请页 ViewModel 持有
`UIImage`；退出页面时结束持有，`CachedRemoteImage` 的磁盘缓存排除该图片。

### 4.4 实验性偏好 iCloud 同步

用户单独开启实验开关后，`ExperimentalPreferenceCloudSync` 使用 iCloud Key-Value Store
同步设置、成绩筛选、成绩缓存和话廊消息已读状态：

- 开关保存在当前设备并按学号隔离，默认关闭
- 各同步域分别记录修改时间，更新时按域处理，防止一个域覆盖另一个域
- 课表由上一节所述的 CloudKit 同步负责

相关代码主要在：

- `Shared/Infrastructure/ExperimentalPreferenceCloudSync.swift`
- `Score/ScoreCacheStore.swift`

## 5. 话廊的本地状态

### 5.1 服务端状态

服务端提供：

- 帖子列表
- 评论
- 分类未读数

### 5.2 本地派生状态

客户端额外维护：

- 当前 feed 的分页状态
- 搜索状态
- 消息页“伪新消息”

消息已读状态使用服务端分类未读数，客户端按该计数进行本地近似展示。该状态属于 UI 体验状态，消息存档一致性范围限于分类未读数。

## 6. 小组件与锁屏组件的数据来源

### 6.1 扩展使用独立快照

主 App 缓存结构更复杂，扩展 target 与业务内部对象保持解耦，共享边界限定为扩展所需的快照数据。

### 6.2 当前做法

数据流如下：

1. 主 App 维护完整课表缓存
2. `ScheduleWidgetSupport.swift` 导出精简快照
3. widget / 锁屏组件 / Live Activity 的读取入口限定为共享快照

### 6.3 保存位置

共享快照保存在：

- App Group 共享容器

标识为：

- `group.BIT101-dev.BIT101-iOS.shared`

## 7. Live Activity 的额外运行时状态

Live Activity 同时依赖静态数据和运行时判断：

- 系统判断当前是否有课
- 系统计算下一节课的剩余时间
- 系统判断当前是否命中提前显示阈值
- 系统读取当前账号的功能开关状态

Live Activity 使用以下数据：

- 共享快照
- 当前时间
- 本地设置
- 当前运行中的 activity 状态

Live Activity 的显示结果根据这些数据动态计算。

## 8. 头像缓存

### 8.1 当前状态

头像使用显式缓存层，并保留系统默认网络缓存。

### 8.2 作用

显式缓存层用于：

- 减少冷启动时的重复下载
- 减少列表滚动中的图片抖动
- 提高“我的”“话廊”“消息中心”的稳定性

### 8.3 保存位置

这部分使用：

- 内存缓存
- 磁盘缓存

相关代码在：

- `CachedRemoteImage.swift`

## 9. 页面瞬时状态

状态按生命周期分别处理。

例如：

- sheet 是否打开
- 当前搜索输入
- 当前正在加载更多
- 当前帖子详情是否展开
- bit-login 短信 challenge 和验证码错误
- 可信成绩单临时图片与全屏预览状态

这类状态通常保留在：

- `@State`
- `@StateObject`
- `ViewModel` 的内存属性

瞬时状态保留在内存，需要跨启动恢复的数据进入持久化层。

## 10. 新增状态的存储判断

新增状态时，按以下顺序判断存储位置：

1. 如果状态包含敏感信息，优先使用 Keychain。
2. 如果状态需要跨启动恢复，使用缓存文件或 `UserDefaults`。
3. 如果状态需要按账号隔离，按账号分桶保存。
4. 如果扩展需要读取状态，导出精简快照。
5. 如果状态仅影响当前页面的一段时间，保留在内存。
