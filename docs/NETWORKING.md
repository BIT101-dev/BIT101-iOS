# 网络层架构

## 1. 分层

网络代码分成三层：

1. `HTTPClient`
   只负责发送 `URLRequest`、校验 `HTTPURLResponse`、检查状态码并提取服务端错误消息。
2. `CommunityAPIClient`
   负责 BIT101 社区域名、查询参数、`fake-cookie`、JSON 编解码和业务错误映射。
3. 各模块 `Service`
   描述 endpoint、请求体和业务特有的数据组合，社区 `URLSession` 由共享网络层管理。

各 ViewModel 通过场景化 `Servicing` 协议依赖 Service，不直接依赖网络基础设施。

## 2. 会话边界

`NetworkSessionPool` 维护可复用会话：

- `community`
  Gallery、Course、Paper、Mine 和 Settings 共用 `community` 会话。该会话共享 Cookie、URLCache、连接池与 TLS 连接。
- `scoreAuthentication`
  普通成绩和可信成绩单共用 bit-login 连接。各自业务流程管理认证 challenge 状态。
- `sensitiveDownloads`
  下载可信成绩单图片时使用 ephemeral 配置，图片不写入通用磁盘缓存。

业务页面将请求交给 `HTTPClient` 或对应的场景化 Service；两者统一会话、认证、取消和错误映射。
业务页面对 `URLSession.shared` 的直接调用限定在共享基础设施例外范围内；版本检查、紧急更新、错误上报和网络
smoke 属于该例外范围。

以下会话保持独立：

- 学校 CAS 同时需要“禁止自动重定向”和“HTTPS 升级后自动重定向”两套 delegate。
- 教学中心需要自己的 HTTPS 升级 delegate 和可失效会话恢复逻辑。
- `jwb`、`jwb_cjd` 和教学中心认证保持独立的业务登录状态。

## 3. 性能策略

- 社区模块的 Service 共用网络会话，减少每个 Service 新建 `URLSession` 带来的重复 DNS、TLS 和连接预热。
- 共享网络会话启用 `waitsForConnectivity`，短暂断网或网络切换时由系统等待可用连接，
  但上层仍需正确呈现最终的超时、DNS 和离线错误。
- `BIT101APIClient.shared` 复用 CAS 的两套重定向会话，设置检查和日程前置登录不再重复创建会话。
- 成绩两类页面复用相同的 bit-login 传输会话。
- 课表拿到目标学期后，并发请求课程、考试和首周日期，避免三个独立请求串行等待。
- 头像和全屏图片使用已有本地缓存/展示策略；HTTP 状态码统一校验，避免把错误页当图片解码。

自动重试按条件执行。学校接口和写请求具有认证与副作用语义，盲目重试可能重复提交或拉长失败时间。

## 4. 错误规则

- 非 HTTP 响应统一视为 `invalidResponse`。
- 社区 `401` 映射到各模块原有的 `notLoggedIn` 错误，保持 UI 文案不变。
- 其它非 2xx 响应优先读取 JSON 的 `message`、`msg`、`detail` 或 `error`。
- 取消和超时由现有 ViewModel / 学校 Service 按业务语义处理。

## 5. 测试要求

`NetworkClientTests` 使用注入的 `HTTPTransport`，不访问真实服务器，覆盖：

- HTTP 状态码和结构化错误消息
- `fake-cookie` 的 required / optional 行为
- URL 查询参数
- snake_case JSON 解码
- multipart 文件字段契约

修改共享网络层时至少运行 `build-for-testing` 和测试 Target。修改学校认证链路后还必须做真机同步冒烟验证。
