# 贡献指南

## 修改原则

- 保持现有用户行为和 UI，结构清理与功能修改分开提交。
- 学校认证、账号隔离、共享快照和缓存键属于高风险契约，修改前先阅读 `docs/`。
- View 负责展示和路由，ViewModel 负责页面状态，Service 负责数据源访问。
- 跨业务复用的纯工具放入 `Shared/Infrastructure`；业务模型不要为了减少文件数强行合并。
- ViewModel 的依赖面优先使用按场景划分的 Service 协议；生产 Service 提供默认实现。

## 提交前检查

首次克隆后启用仓库内置 Git hooks：

```sh
git config core.hooksPath .githooks
```

`pre-commit` 会提示超过 30 天没有修改的 Markdown 文档。检查结果使用 `info` 级别，提交
流程继续执行；Info.plist、Entitlements、配置、静态资源和测试 fixture 保持在检查范围外。
临时关闭提示时可使用：

```sh
SKIP_STALE_DOCS_CHECK=1 git commit ...
```

1. 验证流程禁止启动、使用或创建 iOS / watchOS 模拟器；没有已连接真机时停止验证。
2. 使用 generic device 或已连接真机运行 `xcodebuild build-for-testing`。
3. 仅在已连接真机上运行受影响的单元测试。
4. 按 `docs/MODULE_PLAYBOOK.md` 人工验证受影响页面。
5. 缓存、状态或模块边界变化时同步更新文档。
6. UI 改动按需运行 `Scripts/check-ui-consistency.sh`，确认改动使用公共设计系统。
7. 需要全盘源码风格审查时运行 `Scripts/check-code-quality.sh`；它会固定覆盖报告，不按时间或序号创建文件。
8. 不新增旧版已移除的社区操作或主 App 标准输出；新增的列表、卡片、详情和悬浮操作必须接入公共组件。

## 发布前网络冒烟测试

在已登录的真机上按依赖边界运行只读用户流程测试：

```sh
./Scripts/release-network-smoke-bit101.sh <真机设备ID> /Users/harrybit/Desktop/Xcode-beta.app/Contents/Developer
./Scripts/release-network-smoke-school.sh <真机设备ID> /Users/harrybit/Desktop/Xcode-beta.app/Contents/Developer
```

`release-network-smoke.sh` 先做一次本地构建检查，再向当前已安装并运行中的正式 App 发送
`bit101://network-smoke/...`；该请求在同一进程内触发同一份只读探针，复用正式 App 当前保存的
登录态、Cookie 和缓存。
脚本在 Wi‑Fi、蜂窝网络和校园网环境下使用同一份测试内容；脚本不检测、切换网络，也不根据网络
环境改变测试内容。比较不同网络时，在对应网络环境下重复执行同一条命令。

测试覆盖登录、社区、话廊及图片、课程、文章、个人资料、学期列表、课表、空教室、乐学
日历、成绩、可信成绩单和 App Store 更新接口；不会执行点赞、评论、发帖、上传等写操作。
结果会写到 `group.BIT101-dev.BIT101-iOS.shared/Library/NetworkSmoke/` 下的
`release-network-smoke.json`，完整日志保存在
`.build/release-network-smoke/network-smoke.log`。

每个探针输出 `PASS`、`FAIL` 或 `AUTH_BLOCKED`。`AUTH_BLOCKED` 表示学校要求短信等
人工认证。该状态不计为网络故障，相关路径尚未完成验证，整轮测试不会显示为通过。
