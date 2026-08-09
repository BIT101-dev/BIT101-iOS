# 测试与持续集成

## 本地工具链

工程当前使用 Xcode 27 Beta。若它没有设为系统默认，所有命令显式指定开发者目录：

```sh
export DEVELOPER_DIR=/Users/harrybit/Desktop/Xcode-beta.app/Contents/Developer
xcodebuild -version
```

不必为了本仓库永久切换系统 `xcode-select`。Beta 环境下测试诊断进程可能仍调用系统工具；先手动启动模拟器，并传入 `-collect-test-diagnostics never` 可避免该依赖。

## 编译测试包

```sh
xcodebuild build-for-testing \
  -project BIT101-iOS.xcodeproj \
  -scheme BIT101-iOS \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/Tests \
  -collect-test-diagnostics never \
  CODE_SIGNING_ALLOWED=NO
```

## 运行模拟器测试

先从 `xcrun simctl list devices available` 选择设备并启动：

```sh
DEVICE_ID='<simulator-udid>'
xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE_ID" -b

xcodebuild test \
  -project BIT101-iOS.xcodeproj \
  -scheme BIT101-iOS \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$DEVICE_ID" \
  -derivedDataPath build/Tests \
  -collect-test-diagnostics never \
  CODE_SIGNING_ALLOWED=NO
```

2026-08-09 的基线为 **39 项测试全部通过，0 条编译警告/错误**。覆盖范围包括：

- 取消错误、页码分页、账号隔离 Codable 快照
- HTTP/社区请求构造和错误映射
- 登录启动状态、CAS HTML 解析、AES/MD5 兼容向量
- 成绩详细模式与排序
- 课程草稿/周次、空教室筛选和文案
- ICS 折行/转义/时区解析
- 课程列表与文章搜索 ViewModel 的成功、失败、取消和分页状态
- widget/watch 共享快照与时间线计算

## 真机验证

连接并信任设备后，先用 `xcodebuild -showdestinations` 获取 Xcode 设备 ID。工程已配置自动签名：

```sh
xcodebuild build \
  -project BIT101-iOS.xcodeproj \
  -scheme BIT101-iOS \
  -configuration Debug \
  -destination 'platform=iOS,id=<xcode-device-id>' \
  -derivedDataPath build/DeviceReview \
  -allowProvisioningUpdates
```

构建后可用 `xcrun devicectl device install app` 和 `device process launch` 安装、启动开发包。真机检查至少确认主 App 与 widget extension 没有启动即崩溃；涉及登录、学校接口、通知、Live Activity 或深链时，再按 `MODULE_PLAYBOOK.md` 完成人工交互回归。

## CI 门禁

`.github/workflows/ci.yml` 在 push 到 `main` 和 Pull Request 时执行工程校验及 `build-for-testing`。CI 不负责签名、真机能力、Widget 时间线或 Live Activity 时序，这些仍按 `MODULE_PLAYBOOK.md` 做人工验证。
