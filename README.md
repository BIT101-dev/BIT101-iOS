# BIT101-iOS

## 简介

`BIT101-iOS` 是 `BIT101` 的 iOS 客户端，当前已经上架 App Store。

这个仓库以 Android 端现有能力为基线，工作范围包括：

- 尽量保留用户最常用的功能
- 在 iOS 端将客户端重写为可维护的原生实现
- 对小组件、锁屏组件、Live Activity、账号隔离、缓存等部分做平台适配

项目迁移与生成过程中主要参考了以下仓库：

- Android 端：<https://github.com/BIT101-dev/BIT101-Android>
- 后端：<https://github.com/BIT101-dev/BIT101-GO>
- 网页端：<https://github.com/BIT101-dev/BIT101>

本项目的代码生成与移植过程高度依赖 AI。仓库用于：

- 记录一个复杂 iOS 应用在 AI 辅助下逐步成形的过程
- 积累 Android -> iOS 迁移时的架构和踩坑经验
- 支持后续维护、修补和本地化打磨

## 维护范围

- 本仓库维护者负责的范围是 BIT101 iOS 客户端；BIT101 服务端由其他主体维护。
- 本仓库维护者持有并管理的域名为 `aihelpme.dev`。
- BIT101/101 相关域名（包括 `bit101.cn`）归属其他主体。

## 当前功能覆盖

iOS 端目前支持以下主要能力：

- 登录与会话恢复
- 学校新版认证与短信验证码
- 日程
  - 课表
  - 学校学期切换与首周日期同步
  - 考试
  - DDL
  - 自定义日程
  - 空教室
- 成绩查询、筛选、排序和统计
- 可信成绩单申请与全屏预览
- 课程浏览、搜索、详情、评分与评论
- 校园地图
- 话廊
  - feed 浏览
  - 搜索
  - 发帖
  - 评论
  - 消息中心
- 文章浏览、搜索、发布、编辑与评论
- 我的主页与他人主页
- 设置中心
- 桌面小组件
- 锁屏组件
- Live Activity / 灵动岛提醒
- Apple Watch 课表与 Smart Stack 组件

## 项目状态

项目仍处于实验性阶段。

- 部分实现已经可用，代码结构和实现细节仍需打磨
- 部分链路优先保证可运行
- 部分 UI 与交互细节仍在调整
- 代码库已经具备维护基础，后续仍需继续维护

## 仓库结构

仓库目录：

- `BIT101-iOS`
  主 App 源码
- `BIT101ScheduleWidgets/`
  小组件、锁屏组件、Live Activity / 灵动岛扩展
- `BIT101Watch`
  Apple Watch App
- `BIT101WatchWidgets`
  Apple Watch Smart Stack 组件扩展
- `docs`
  仓库级文档
- `Cloudflare`
  所有自有 `aihelpme.dev` 资源源码：隐私 Pages、Universal Link、紧急更新和错误报告 Worker。

主 App 内的核心模块：

- `Login/`
  App 登录、凭据恢复、学校 SSO 与 BIT101 登录桥接
- `Schedule/`
  学校新版认证、学期切换、课表、考试、DDL、空教室、自定义日程，以及小组件快照导出
- `Score/`
  学校新版认证、成绩查询、可信成绩单、筛选、排序与统计
- `Map/`
  地图页与 `MapKit` 桥接
- `Gallery/`
  话廊 feed、搜索、发帖、详情和消息
- `Paper/`
  文章列表、搜索、发布、详情与评论
- `Course/`
  课程浏览、搜索、详情、评分与评论
- `Mine/`
  我的主页、他人主页、粉丝、关注、帖子
- `Settings/`
  设置中心、账号相关设置、界面偏好
- `Shell/`
  登录后的 tab 壳层与全局路由

## 文档索引

维护文档按以下顺序阅读：

1. [`docs/CODEBASE_GUIDE.md`](docs/CODEBASE_GUIDE.md)
   说明模块边界、数据流、状态流和关键设计约束。
2. [`docs/MAINTENANCE_GUIDE.md`](docs/MAINTENANCE_GUIDE.md)
   说明构建、签名、真机、账号隔离、小组件、Live Activity 和常见维护注意事项。
3. [`docs/FILE_INDEX.md`](docs/FILE_INDEX.md)
   列出全部 Swift 源码文件及其职责，用于定位代码入口。
4. [`docs/TESTING.md`](docs/TESTING.md)
   说明测试 Target、本地测试命令与 CI 门禁。

## 构建说明

本项目使用 Xcode 工程构建，当前包含四个 target：

- 主 App：`BIT101-iOS`
- iOS 扩展 target：`BIT101ScheduleWidgets`（源码目录：`BIT101ScheduleWidgets/`）
- Watch App：`BIT101Watch`
- Watch 扩展：`BIT101WatchWidgets`

修改以下能力时，同时关注主 App 与扩展：

- 课表
- 小组件
- 锁屏组件
- Live Activity / 灵动岛
- App Group 共享快照
- Apple Watch 镜像同步与 Smart Stack

构建和调试需要：

- Xcode 27 或更新版本，并能识别当前单 target Watch App 结构
- 有效的 Apple 签名与描述文件
- 真机调试能力

## 维护原则

- 优先保证行为稳定，再考虑结构重写
- 多账号相关数据必须继续保持隔离
- 小组件与 Live Activity 依赖共享快照，并与主 App 复杂状态保持解耦
- 服务层和状态机变更时，优先同步注释和 `docs/`
- 用户可见文案调整后，同步 README、代码注释和设置页说明

## 文档与代码的关系

这个仓库的文档面向后续维护者，重点说明：

- 模块归属
- 状态保存位置：本地、内存、Keychain 或共享容器
- 平台约束与当前实现选择的区别
- 修改功能时需要同步关注的文件和 target

文档重点记录：

- 模块职责
- 数据流
- 约束条件
- 踩坑记录
- 维护边界

## 反馈

发现 bug、异常行为或明显不合理的实现时，请提交 Issue。

## 免责声明

本项目用于探索 AI 生成代码与 Android -> iOS 迁移的可行性与边界；代码质量、可维护性和生产可用性以实际评估为准。
