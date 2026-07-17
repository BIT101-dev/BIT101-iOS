# BIT101-iOS 文档目录

`docs/` 目录的目标是把“能跑的代码”补成“能接手的工程”。

当前文档基线对应 `1.7.0 (26)`：已包含学校新版 bit-login challenge、学期切换、
可信成绩单，以及 Xcode 27 单 Watch App target 结构。

如果你是第一次进入这个仓库，建议从这里开始，而不是直接闯进某个大文件。

## 阅读顺序

1. [`ARCHITECTURE.md`](ARCHITECTURE.md)
   先建立对整体结构、模块边界和 target 协作方式的认识。
2. [`CODEBASE_GUIDE.md`](CODEBASE_GUIDE.md)
   再看代码库导览，理解各模块职责和关键约束。
3. [`STATE_AND_STORAGE.md`](STATE_AND_STORAGE.md)
   如果你要改缓存、设置、账号隔离、小组件数据源，这份最重要。
4. [`NETWORKING.md`](NETWORKING.md)
   如果你要改接口、认证、会话复用或排查网络耗时，先看这份。
5. [`MODULE_PLAYBOOK.md`](MODULE_PLAYBOOK.md)
   如果你准备改具体模块，先看对应模块的维护清单和验证建议。
6. [`MAINTENANCE_GUIDE.md`](MAINTENANCE_GUIDE.md)
   如果你准备长期维护、构建、签名、真机调试，这份最重要。
7. [`CODE_QUALITY_AUDIT.md`](CODE_QUALITY_AUDIT.md)
   如果你准备继续清理大文件、收重复逻辑或评估哪些 UI 是刻意桥接实现，先看这份。
8. [`FILE_INDEX.md`](FILE_INDEX.md)
   如果你已经知道自己要改什么，只是不知道文件在哪，从这里查最快。
9. [`TESTING.md`](TESTING.md)
   说明测试 Target、本地命令和 CI 门禁。

## 每份文档的定位

- `ARCHITECTURE.md`
  讲系统边界、主 App / widget / Apple Watch / Live Activity 的协作关系。
- `CODEBASE_GUIDE.md`
  讲当前代码库里各模块的职责、数据流和维护约束。
- `STATE_AND_STORAGE.md`
  讲状态到底落在哪里，以及如何判断一个新状态该放哪。
- `NETWORKING.md`
  讲 HTTP、社区 API、共享会话和学校认证链路之间的边界。
- `MODULE_PLAYBOOK.md`
  讲“改某个模块时先看什么、最容易坏什么、改完该验什么”。
- `MAINTENANCE_GUIDE.md`
  讲工程维护、构建、真机、账号隔离、小组件和排障建议。
- `CODE_QUALITY_AUDIT.md`
  讲当前代码清理的落点、仍保留的桥接/非原生实现，以及后续继续收口时该优先看哪里。
- `FILE_INDEX.md`
  讲全部 Swift 源码文件及其职责。
- `TESTING.md`
  讲如何编译和运行测试，以及 CI 覆盖范围。

## 建议使用方式

如果你是：

- 想理解整个项目
  先读 `ARCHITECTURE.md`
- 想改某个模块
  先读 `MODULE_PLAYBOOK.md`
- 想查某份文件
  直接看 `FILE_INDEX.md`
- 想改缓存或账号隔离
  优先看 `STATE_AND_STORAGE.md`
- 想确认覆盖更新会不会清掉本地数据
  优先看 `STATE_AND_STORAGE.md` 和 `MAINTENANCE_GUIDE.md`
- 想排查构建、签名、扩展问题
  优先看 `MAINTENANCE_GUIDE.md`
- 想改 Apple Watch 课表、Smart Stack 或跨 target 共享快照
  优先看 `ARCHITECTURE.md`、`CODEBASE_GUIDE.md` 和 `FILE_INDEX.md`
- 想继续清理大文件或桥接实现
  优先看 `CODE_QUALITY_AUDIT.md`
