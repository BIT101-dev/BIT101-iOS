# 贡献指南

## 修改原则

- 保持现有用户行为和 UI，结构清理与功能修改分开提交。
- 学校认证、账号隔离、共享快照和缓存键属于高风险契约，修改前先阅读 `docs/`。
- View 负责展示和路由，ViewModel 负责页面状态，Service 负责数据源访问。
- 跨业务复用的纯工具放入 `Shared/Infrastructure`；业务模型不要为了减少文件数强行合并。
- ViewModel 依赖面优先定义为按场景划分的 Service 协议，生产 Service 提供默认实现。

## 提交前检查

首次克隆后启用仓库内置 Git hooks：

```sh
git config core.hooksPath .githooks
```

`pre-commit` 会提示超过 30 天没有修改的 Markdown 文档。它只提供 `info`，不会阻止
提交；Info.plist、Entitlements、配置、静态资源和测试 fixture 均不参与检查。确需临时
关闭提示时可使用：

```sh
SKIP_STALE_DOCS_CHECK=1 git commit ...
```

1. 禁止启动、使用或创建 iOS / watchOS 模拟器；没有已连接真机时停止验证，不得改用模拟器。
2. 使用 generic device 或已连接真机运行 `xcodebuild build-for-testing`。
3. 仅在已连接真机上运行受影响的单元测试。
4. 按 `docs/MODULE_PLAYBOOK.md` 人工验证受影响页面。
5. 缓存、状态或模块边界变化时同步更新文档。

## 发布前网络冒烟测试

在已登录的真机上按依赖边界运行只读用户流程测试：

```sh
./Scripts/release-network-smoke-bit101.sh <真机设备ID> /Users/harrybit/Desktop/Xcode-beta.app/Contents/Developer
./Scripts/release-network-smoke-school.sh <真机设备ID> /Users/harrybit/Desktop/Xcode-beta.app/Contents/Developer
```

`release-network-smoke.sh` 会先做一次本地构建检查，然后直接向当前已安装并运行中的正式 App
发送 `bit101://network-smoke/...`，在同一进程内触发同一份只读探针，因此会复用正式 App 当前
保存的登录态、Cookie 和缓存。
脚本不会检测、切换或根据 Wi‑Fi、蜂窝网络、校园网改变测试内容。需要比较不同网络时，
只需在对应网络环境下重复执行同一条命令。

测试覆盖登录、社区、话廊及图片、课程、文章、个人资料、学期列表、课表、空教室、乐学
日历、成绩、可信成绩单和 App Store 更新接口；不会执行点赞、评论、发帖、上传等写操作。
结果会写到 `group.BIT101-dev.BIT101-iOS.shared/Library/NetworkSmoke/` 下的
`release-network-smoke-<runID>.json`，完整日志保存在
`.build/release-network-smoke/network-smoke.log`。

每个探针输出 `PASS`、`FAIL` 或 `AUTH_BLOCKED`。`AUTH_BLOCKED` 表示学校要求短信等
人工认证：它不算网络故障，但相关路径尚未完成验证，因此整轮测试不会显示为通过。
