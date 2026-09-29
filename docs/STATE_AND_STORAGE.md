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

## 2. 本地存储基础设施

- `Shared/AppFileService.swift` 定义文件服务接口与本机实现。App、Widget 和 Watch 的文件读写、目录查询、缓存清理与文件属性访问共用 `AppFileSystem`。
- `Shared/Client/AppFileDirectories.swift` 统一提供 Application Support、Caches、Documents、App Group 路径与当前账号 `AppStorageSession`。
- `AppStorageSession` 统一生成账号级 UserDefaults 键和稳定、安全的账号目录名；访客状态使用固定默认分区。
- 业务仓库按单用户语义暴露读取、保存和清理入口；`AccountScopedCodableStore` 与 `AccountScopedFileCodableStore` 负责 Codable 快照的本地编码和账号分区。
- `AccountScopedFileCodableStore` 写入前校验已有快照；校验失败时保留原文件并返回失败。
- 成绩明细、课表缓存、发帖草稿及其图片保存在账号隔离的 `Application Support` 文件中，写入使用原子替换和 `completeFileProtectionUntilFirstUserAuthentication`。
- App Group 课表快照使用相同的数据保护级别，首次解锁后供 Widget 与 Watch 读取。
- Widget/Watch 导出在账号切换时先替换共享快照，再按捕获的账号读取；写入队列按 generation 串行化并丢弃迟到的旧导出。
- 持久化容器数据遵循 iOS 应用容器备份策略；可重建的头像和话廊图片放在 `Caches`，由容量策略回收。
- 全局偏好继续使用应用级键，凭据继续由 Keychain 保存，扩展快照继续写入 App Group。
- 日程异步写入在任务创建时固定账号目录，并在切换账号后校验写入和导出归属。
- 成绩文件的读取、JSON 编解码和原子写入由 actor 串行执行；损坏文件会阻止覆盖，也会暂停该域的 iCloud 缓存同步。
- 发帖草稿按当前账号分区；图片以独立 JPEG 文件保存，单张文件上限为 1 MiB，JSON 清单采用原子替换；串行后台 actor 承载读写、图片压缩和旧版内嵌图片迁移。
- CloudKit 承载手动日程调整、个人日程、导入课表、手动 DDL、乐学 DDL 完成状态和日程偏好；学校接口返回的课程、考试、乐学 DDL 正文与查询缓存保留在本机。

## 3. 会话与凭据

### 3.1 保存内容

会话与凭据包括：

- 学校统一认证账号
- 学校统一认证密码
- 与登录恢复相关的敏感凭据
- BIT101 侧会话恢复所需信息

### 3.2 保存位置

这些状态分布在以下存储中：

- 学号、密码：Keychain
- BIT101 `fake-cookie`：Keychain；安装标记：`UserDefaults`
- 学校认证 cookie：系统 `HTTPCookieStorage`

相关代码主要在：

- `Login/LoginStorage.swift`
- `Login/LoginService.swift`

### 3.3 维护原则

- 敏感信息始终使用 Keychain，普通 `UserDefaults` 承载非敏感状态
- 登录字段或恢复逻辑调整时，核对旧版 `fake-cookie` 从 UserDefaults 迁入 Keychain 的迁移入口
- 卸载时系统清除安装标记，Keychain 可能由系统保留；重装后首次创建 `LoginStorage` 时，系统据此主动清理旧学号和密码。
- 登录态检查将“无法确认”保留为待确认状态。网络不稳、学校页面解析失败、缺少静默恢复材料等情况保留本地 session 并向上抛错；远端明确返回凭据无效时，系统清除 `fake-cookie`、cookie 和本地密码。
- `fake-cookie` 为空时，外部课表快照将其导出为 `isLoggedIn = false`，并同步到 widget / Apple Watch。登录检查的清除策略决定手表端是否显示“请先登录”。

### 3.4 学校业务的短期认证状态

课表、成绩、空教室和可信成绩单通过 bit-login 使用短期 challenge，包括
`challenge_id`、access token、短信状态、掩码手机号和有效期。教学中心认证状态和当前
准备状态按当前学号绑定，并以业务会话为范围。

这些值的存储范围是 `ScheduleService`、`ScoreService` 和对应 ViewModel 的内存属性：

- 这些值随内存属性管理，Keychain 和 `UserDefaults` 的写入范围排除这些值
- 系统在退出、切号、过期或收到明确失效响应时立即使这些值失效
- challenge 过期或重复提交后进入失效状态
- 普通成绩使用 `jwb` challenge，可信成绩单使用独立的 `jwb_cjd` challenge

## 4. 课表、DDL、考试与自定义日程

### 4.1 保存内容

- 课程表
- 考试
- DDL
- 自定义日程
- 一些查询所需的本地上下文

### 4.2 保存位置

这类数据主要存储于：

- 本地缓存文件

相关代码主要在：

- `Schedule/ScheduleCacheStore.swift`
- `Schedule/ScheduleModels.swift`
- `Schedule/ScheduleViewModel.swift`

### 4.3 特点

- 系统先恢复缓存，再同步远端
- 系统按账号隔离保存这类数据
- 切号后，系统按当前账号加载课表

### 4.4 覆盖更新与本地课表

App 覆盖更新会保留 Application Support 中按账号保存的日程缓存。

日程页面的课表、DDL 和空教室状态分别管理，共同使用 `ScheduleRepository` 的账号缓存。
仓库捕获账号、加载代际与本机修订，确保磁盘和异步服务结果按当前会话回写。
`ScheduleCacheStore` 保持串行持久化；应用通过 `ScheduleCacheEffects` 连接外部展示与云同步。

当前日程模块的主缓存存储在当前账号对应的本地文件中：

- `ScheduleCacheStore` 会把缓存写到 `Application Support/BIT101-iOS/<account>/schedule-cache.json`
- 这份缓存包含主课表、考试、DDL、自定义日程和导入的分享课表
- `schoolCoursesByTerm`、`cachedCoursesByTerm` 与学期快照保留学校返回的原始课程；放假、删课和换课写入 `manualCourseRulesByTerm`，`courses` 保存当前展示结果
- 成绩页使用原始学期缓存估算未出分课程，课表编辑结果持续通过规则叠加展示
- 历史账号目录在旧路径与账号标识原样一致时参与自动回退；字符替换后的目录作为隔离历史数据留在原位
- 导入别人分享的课表后，本地记录会进入 `sharedSchedules`

用户直接升级新版本、保留 App 安装状态和本地数据时，“别人分享给我的课表”原则上随缓存保留。

### 4.5 分享课表的导入范围

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

### 4.6 本地数据清理与读取故障

本地数据会在以下操作后清理：

1. 用户卸载后重装
2. 用户在设置里执行“删除所有文稿与数据”
3. 开发时手动删除 `Application Support` 或 `UserDefaults` 内容

`ScheduleCache` 的新增字段按默认值解码。文件读取或解码失败时，系统保留原文件、暂停本地写入，并在日程页提示恢复状态；Widget/Watch 改用当前账号的空课表快照，维持账号归属一致。字段语义、字段类型或关键结构变化仍需明确迁移策略。

成绩缓存文件读取或解码失败时，仓库保留原文件并跳过本地替换；实验性偏好同步也跳过成绩缓存域，避免空载荷覆盖本机或云端数据。退出登录会清理会话凭据，账号隔离的课表、成绩和草稿仍保留，供该账号下次登录恢复；“删除所有文稿与数据”会清除这些本地持久数据。

设置页的“删除所有文稿与数据”会清理主 App 沙盒与 App Group 中的日程快照、网络 Smoke 报告和原始课程响应；文件清理遇到错误时，App 呈现部分完成提示。已同步至 iCloud 的课表与偏好属于远端数据，保留在用户 iCloud 账户中。

### 4.7 iCloud 课表同步

用户启用课表 iCloud 同步后，`ScheduleCloudSyncManager` 会把当前账号的用户创建内容与日程偏好同步到 CloudKit 私有数据库。学校接口返回的数据继续保存在本机缓存，由现有自动同步与刷新流程更新：

- 记录按学号隔离
- CloudKit 服务器修改时间记录每台设备的同步基线，本地编辑单独标记为待上传
- 手动调课、调休与放假规则、个人日程、分享课表、手动 DDL、乐学 DDL 完成状态和日程偏好参与跨设备同步
- 课程、考试、乐学 DDL 正文、乐学订阅链接、课程历史快照、校区和教学楼查询缓存留在本机
- 本机存在待上传修改且 iCloud 版本与同步基线分歧时，应用提供本机/iCloud 版本选择；课程等学校抓取数据保留在本机
- 关闭 `iCloudSyncEnabled` 后，管理器停止拉取和上传
- App 和扩展导出流程直接读取本地文件缓存，CloudKit 承载云端同步

CloudKit 载荷使用带版本号的精简 envelope。升级时，应用可读取旧版本上传的完整 `ScheduleCache`，从中提取用户创建内容和偏好，再与本机缓存合并；本机已有的学校抓取数据继续保留。完成首次协调后，记录会以精简载荷覆盖。旧版客户端遇到新载荷时会保留本机缓存并暂停该版本的 CloudKit 同步；各设备升级到兼容版本后，跨设备同步恢复。

相关代码主要在：

- `Schedule/ScheduleCloudSyncManager.swift`
- `Schedule/ScheduleCacheStore.swift`

## 5. 设置与偏好

### 5.1 保存内容

包括但不限于：

- 灵动岛提前显示阈值
- 一部分查询筛选结果

### 5.2 保存位置

偏好主要存储于：

- `UserDefaults`
- 通过 `AppSettingsStore` 做统一读写

相关代码主要在：

- `Settings/AppSettingsStore.swift`

### 5.3 两类偏好的区别

#### 5.3.1 全局偏好

例如：

- 主题模式
- 屏幕旋转

这类偏好按全局设置保存，账号切换时沿用原值。

#### 5.3.2 账号隔离偏好

例如：

- 一部分查询筛选
- 成绩学期/种类筛选与排序偏好
- 普通帖子页面是否隐藏机器人帖子，默认开启（搜索、推荐、关注、个人主页等；机器人分栏除外）

这类偏好按账号分桶保存在 `UserDefaults`。成绩行和更新时间保存在账号隔离的
`Application Support/BIT101-iOS/<account>/score-cache.json`，三个值组成单一原子快照；旧版
`UserDefaults` 成绩键在首次读取时迁入文件并清理来源键。文件访问和编解码在后台 actor 中串行处理，成绩页从单次快照读取所需字段；文件不可读时保留源文件并暂停该成绩域的云同步。

可信成绩单的图片采用 ephemeral URLSession 从学校生成的短期 URL 下载，并由申请页 ViewModel 持有
`UIImage`；退出页面时结束持有，`CachedRemoteImage` 的磁盘缓存排除该图片。

### 5.4 实验性偏好 iCloud 同步

用户单独开启实验开关后，`ExperimentalPreferenceCloudSync` 使用 iCloud Key-Value Store
同步设置、成绩筛选、成绩缓存和话廊消息已读状态：

- 开关保存在当前设备并按学号隔离，默认关闭
- 各同步域分别记录修改时间，更新时按域处理，防止一个域覆盖另一个域
- 成绩快照使用 LZFSE 压缩，并在写入前检查单值、总值和键数量配额；额度不足时在同步设置处显示状态，本机缓存继续保留
- 读取端兼容先前版本写入的 JSON 成绩快照
- 课表由上一节所述的 CloudKit 同步负责

相关代码主要在：

- `Shell/ExperimentalPreferenceCloudSync.swift`
- `Score/ScoreCacheStore.swift`

## 6. 话廊的本地状态

### 6.1 服务端状态

服务端提供：

- 帖子列表
- 评论
- 分类未读数

### 6.2 本地派生状态

客户端额外维护：

- 当前 feed 的分页状态
- 搜索状态
- 消息页“伪新消息”

消息已读状态使用服务端分类未读数，客户端按该计数进行本地近似展示。该状态属于 UI 体验状态，消息存档一致性范围限于分类未读数。

### 6.3 发帖草稿

发帖与建议草稿按账号保存在 `Application Support/BIT101-iOS/<account>/`。JSON 文件保存文本、选项和图片引用，图片独立保存为 JPEG 文件；每张图压缩至 1600 px 以内并限制在 1 MiB。保存失败时保留当前编辑页面并提示重试。草稿图片与文本随 Application Support 备份，完整本地清理会移除草稿清单和图片目录。

## 7. 小组件与锁屏组件的数据来源

### 7.1 扩展使用独立快照

主 App 缓存结构更复杂，扩展 target 与业务内部对象保持解耦，共享边界限定为扩展所需的快照数据。

### 7.2 当前做法

数据流如下：

1. 主 App 维护完整课表缓存
2. `ScheduleWidgetSupport.swift` 导出精简快照
3. widget / 锁屏组件 / Live Activity 的读取入口限定为共享快照

### 7.3 保存位置

共享快照保存在：

- App Group 共享容器

标识为：

- `group.BIT101-dev.BIT101-iOS.shared`

## 8. Live Activity 的额外运行时状态

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

## 9. 头像缓存

### 9.1 当前状态

头像使用显式缓存层，并保留系统默认网络缓存。

### 9.2 作用

显式缓存层用于：

- 减少冷启动时的重复下载
- 减少列表滚动中的图片抖动
- 提高“我的”“话廊”“消息中心”的稳定性

### 9.3 保存位置

话廊图片与头像共享本地图片缓存上限和 LRU 回收；默认上限为 500 MB，设置 0 MB 时停用应用侧限额。这部分使用：

- 内存缓存
- 磁盘缓存

设置页的已用空间统计覆盖话廊图片与头像磁盘缓存；`URLCache` 单独由系统和应用清理入口管理。

相关代码在：

- `Shared/Media/CachedRemoteImage.swift`
- `Shared/Media/RemoteImageCache.swift`

## 10. 页面瞬时状态

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

## 11. 新增状态的存储判断

新增状态时，按以下顺序判断存储位置：

1. 如果状态包含敏感信息，优先使用 Keychain。
2. 如果状态需要跨启动恢复，使用缓存文件或 `UserDefaults`。
3. 如果状态需要按账号隔离，按账号分桶保存。
4. 如果扩展需要读取状态，导出精简快照。
5. 如果状态仅影响当前页面的一段时间，保留在内存。
