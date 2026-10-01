# BIT101-iOS

BIT101 的原生 iOS 客户端，已上架 App Store。项目以 Android 端能力为基线，使用 AI 辅助迁移与维护，并适配 Widget、Live Activity 和 Apple Watch。

参考项目：[Android](https://github.com/BIT101-dev/BIT101-Android)、[服务端](https://github.com/BIT101-dev/BIT101-GO)、[Web](https://github.com/BIT101-dev/BIT101)。

## 功能

- 登录、会话恢复、学校认证与短信验证码。
- 日程：课表、学期与首周同步、考试、DDL、自定义日程、空教室和分享课表。
- 成绩查询、筛选、统计与可信成绩单预览。
- 课程浏览、评分与评论；校园地图。
- 话廊、文章、消息中心、个人主页与设置。
- 桌面和锁屏组件、Live Activity、Apple Watch 课表与 Smart Stack。

## 仓库结构

| 路径 | 职责 |
| --- | --- |
| `BIT101-iOS/` | App 入口、登录、设置、账号生命周期、路由和平台适配 |
| `Modules/`、`Package.swift` | 本地模块源码及编译依赖 |
| `BIT101ScheduleWidgets/` | iOS Widget、锁屏组件与 Live Activity |
| `BIT101Watch/`、`BIT101WatchWidgets/` | Watch App 与 Smart Stack |
| `ModuleTests/` | macOS 原生包级测试 |
| `BIT101-iOSTests/`、`BIT101-iOSUITests/` | App 行为测试、固定 fixture 与真机 UI 测试 |
| `Scripts/` | 构建、装机、测试与维护入口 |
| `Cloudflare/` | 自有域名的隐私 Pages、链接跳转、紧急更新与反馈资源 |

## 构建与文档

本地开发使用 Xcode 27.x、有效签名及已连接并受信任的真机。构建、装机和启动通过既有脚本执行：

```sh
Scripts/build-install-device.sh
```

- [架构与数据边界](docs/ARCHITECTURE.md)：模块职责、依赖注入、网络、存储与扩展协作。
- [模块化审计](docs/MODULARITY_AUDIT.md)：解耦重构、依赖指标、验证证据与后续边界。
- [设计系统](docs/DESIGN_SYSTEM.md)：公共令牌、组件和界面规范。
- [构建与测试](docs/TESTING.md)：真机流程、测试分组、固定产物和 CI。
- [Cloudflare 资源](Cloudflare/README.md)：域名、链接契约与部署入口。

## 维护范围

- 本仓库维护者负责 iOS 客户端及真机验证。
- Android、Web 和服务端由对应主体维护；接口阅读、功能对照和问题记录在本仓库开展，源码改动与上线动作转交对应维护主体。
- 本仓库维护者管理 `aihelpme.dev`；`bit101.cn` 等 BIT101 域名归属对应主体。
- 跨模块调整遵循账号隔离、公共领域端口、共享草稿与设计系统边界；依赖和平台副作用由 App 显式组装，验证证据集中维护在模块化审计文档。

发现问题请提交 Issue。项目的代码质量和生产可用性以实际验证结果为准。
