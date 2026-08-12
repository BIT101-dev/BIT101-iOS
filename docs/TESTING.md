# 测试与持续集成

## 设备使用红线

**禁止启动、使用或创建任何 iOS / watchOS 模拟器。**

- 不得执行 `simctl boot`，不得选择 Simulator destination，也不得运行任何会隐式启动模拟器的自动化操作。
- 构建、测试、安装和运行验证只能使用当前已连接并受信任的真机。
- 没有可用真机时必须停止验证并明确说明，不能改用模拟器。
- 仅做编译检查时使用 generic device destination，执行前仍须确认命令不指向模拟器。
- 本约束同样适用于维护者、CI 脚本和自动化代理。

## 本地工具链

工程当前使用 Xcode 27 Beta。若它没有设为系统默认，所有命令显式指定开发者目录：

```sh
export DEVELOPER_DIR=/Users/harrybit/Desktop/Xcode-beta.app/Contents/Developer
xcodebuild -version
```

不必为了本仓库永久切换系统 `xcode-select`。执行任何构建或测试前，先确认 destination 是 generic device 或当前连接的真机。

## 编译测试包

```sh
xcodebuild build-for-testing \
  -project BIT101-iOS.xcodeproj \
  -scheme BIT101-iOS \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/Tests \
  -allowProvisioningUpdates
```

## 运行真机测试

连接并信任真机后，通过 `xcodebuild -showdestinations` 获取设备 ID：

```sh
DEVICE_ID='<xcode-device-id>'

xcodebuild test \
  -project BIT101-iOS.xcodeproj \
  -scheme BIT101-iOS \
  -configuration Debug \
  -destination "platform=iOS,id=$DEVICE_ID" \
  -derivedDataPath build/Tests \
  -collect-test-diagnostics never \
  -allowProvisioningUpdates
```

2026-08-09 的历史基线为 **40 项测试全部通过，0 条编译警告/错误**。后续只能在真机上复验。覆盖范围包括：

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

CI 或其它自动化同样不得启动、创建或使用模拟器。无法提供真机 destination 的环境只能做不依赖模拟器的静态检查；真机构建、测试、Widget 时间线和 Live Activity 时序按 `MODULE_PLAYBOOK.md` 人工验证。
