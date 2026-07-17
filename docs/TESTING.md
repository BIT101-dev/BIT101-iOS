# 测试与持续集成

## 本地工具链

工程当前使用 Xcode 27。若 Beta Xcode 没有设为系统默认，可只为单条命令指定：

```sh
DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer \
xcodebuild -version
```

`build` 和 `build-for-testing` 可只使用 `DEVELOPER_DIR`。运行模拟器测试时，Xcode 的测试进程还会通过系统 `xcrun` 收集诊断，建议先执行：

```sh
sudo xcode-select --switch /path/to/Xcode-beta.app/Contents/Developer
```

## 编译测试包

不启动模拟器、只验证主 App、扩展和测试包能否共同编译：

```sh
xcodebuild build-for-testing \
  -project BIT101-iOS.xcodeproj \
  -scheme BIT101-iOS \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/Tests \
  CODE_SIGNING_ALLOWED=NO
```

## 运行测试

先从 `xcrun simctl list devices available` 选择设备，再执行：

```sh
xcodebuild test \
  -project BIT101-iOS.xcodeproj \
  -scheme BIT101-iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build/Tests \
  CODE_SIGNING_ALLOWED=NO
```

当前测试基线覆盖共享取消错误识别、账号隔离 Codable 存储和成绩排序规则。新增纯逻辑、缓存键或 ViewModel 状态转换时，应同步补测试。

## CI 门禁

`.github/workflows/ci.yml` 在 push 到 `main` 和 Pull Request 时执行工程校验及 `build-for-testing`。CI 不负责签名、真机能力、Widget 时间线或 Live Activity 时序，这些仍按 `MODULE_PLAYBOOK.md` 做人工验证。
