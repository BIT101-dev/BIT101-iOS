# 贡献指南

## 修改原则

- 保持现有用户行为和 UI，结构清理与功能修改分开提交。
- 学校认证、账号隔离、共享快照和缓存键属于高风险契约，修改前先阅读 `docs/`。
- View 负责展示和路由，ViewModel 负责页面状态，Service 负责数据源访问。
- 跨业务复用的纯工具放入 `Shared/Infrastructure`；业务模型不要为了减少文件数强行合并。
- ViewModel 依赖面优先定义为按场景划分的 Service 协议，生产 Service 提供默认实现。

## 提交前检查

1. 禁止启动、使用或创建 iOS / watchOS 模拟器；没有已连接真机时停止验证，不得改用模拟器。
2. 使用 generic device 或已连接真机运行 `xcodebuild build-for-testing`。
3. 仅在已连接真机上运行受影响的单元测试。
4. 按 `docs/MODULE_PLAYBOOK.md` 人工验证受影响页面。
5. 缓存、状态或模块边界变化时同步更新文档。
