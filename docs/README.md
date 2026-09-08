# BIT101-iOS 文档目录

`docs/` 目录记录项目结构、模块边界、数据存储、网络链路和维护流程，供项目接手与后续维护时查阅。

当前文档基线对应 `1.8.0 (36)`，已包含学校新版 bit-login challenge、学期切换、可信成绩单、错误反馈、日历集成、
Universal Links，以及 Xcode 27 单 Watch App target 结构。

## 1.8.0 更新内容

- 日程：课程、待办、空教室和上课地点查看更清晰。
- 成绩：登录、查成绩和成绩单查看更稳定，问题提示更清晰。
- 社区：发帖、评论、搜索、图片和个人主页的使用体验更统一。
- 同步：桌面小组件、Apple Watch 和灵动岛上的课表信息更及时、更可靠。
- 修复部分问题，页面加载和日常使用更流畅。

首次进入仓库时，按下面的顺序阅读。

## 阅读顺序

1. [`ARCHITECTURE.md`](ARCHITECTURE.md)
   了解系统边界、整体结构、模块边界，以及主 App、widget、Apple Watch、Live Activity 和 target 的协作关系。
2. [`CODEBASE_GUIDE.md`](CODEBASE_GUIDE.md)
   了解各模块的职责、数据流和关键维护约束。
3. [`STATE_AND_STORAGE.md`](STATE_AND_STORAGE.md)
   修改缓存、设置、账号隔离或小组件数据源时，先读这份，确认状态存储位置和新状态存放规则。
4. [`NETWORKING.md`](NETWORKING.md)
   修改接口、认证、会话复用或排查网络耗时前，先读这份，确认 HTTP、社区 API、共享会话和学校认证链路的边界。
5. [`MODULE_PLAYBOOK.md`](MODULE_PLAYBOOK.md)
   修改具体模块时，查看对应模块的维护清单、常见风险和验证建议。
6. [`MAINTENANCE_GUIDE.md`](MAINTENANCE_GUIDE.md)
   长期维护、构建、签名或真机调试时，先读工程维护、账号隔离、小组件和排障说明。
7. [`CODE_QUALITY_AUDIT.md`](CODE_QUALITY_AUDIT.md)
   清理大文件、整理重复逻辑或评估刻意保留的 UI 桥接实现时，先读代码清理重点、逐份源码审查、检查脚本覆盖范围和后续清理优先位置。
8. [`FILE_INDEX.md`](FILE_INDEX.md)
   知道修改目标但不知道文件位置时，从这里查找全部 Swift 源码文件及其职责。
9. [`DESIGN_SYSTEM.md`](DESIGN_SYSTEM.md)
   复用或调整 UI 样式时，先看 UI 设计令牌、公共卡片组件、显式变体和自动检查入口，沿用现有颜色、间距和公共组件。
10. [`TESTING.md`](TESTING.md)
   查看测试 Target、本地命令和 CI 门禁，了解如何编译和运行测试及 CI 覆盖范围。

## 按任务查阅

- 理解整个项目：`ARCHITECTURE.md`
- 修改某个模块：`MODULE_PLAYBOOK.md`
- 查找文件：`FILE_INDEX.md`
- 修改缓存或账号隔离：`STATE_AND_STORAGE.md`
- 确认覆盖更新是否会清掉本地数据：`STATE_AND_STORAGE.md` 和 `MAINTENANCE_GUIDE.md`
- 排查构建、签名或扩展问题：`MAINTENANCE_GUIDE.md`
- 修改 Apple Watch 课表、Smart Stack 或跨 target 共享快照：`ARCHITECTURE.md`、`CODEBASE_GUIDE.md` 和 `FILE_INDEX.md`
- 继续清理大文件或桥接实现：`CODE_QUALITY_AUDIT.md`
