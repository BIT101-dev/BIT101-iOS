# 网络层架构

## 1. 分层

网络代码分成三层：

1. `HTTPClient`
   只负责发送 `URLRequest`、校验 `HTTPURLResponse`、检查状态码并提取服务端错误消息。
2. `CommunityAPIClient`
   负责 BIT101 社区域名、查询参数、`fake-cookie`、JSON 编解码和业务错误映射。
3. 各模块 `Service`
   只描述 endpoint、请求体和业务特有的数据组合，不再创建自己的社区 `URLSession`。

ViewModel 继续通过场景化 `Servicing` 协议依赖 Service，不直接依赖网络基础设施。

## 2. 会话边界

`NetworkSessionPool` 维护可复用会话：

- `community`
  Gallery、Course、Paper、Mine、Settings 和举报共用。共享 Cookie、URLCache、连接池与 TLS 连接。
- `scoreAuthentication`
  普通成绩和可信成绩单共用 bit-login 连接，但认证 challenge 状态仍由各自业务流程管理。
- `sensitiveDownloads`
  使用 ephemeral 配置下载可信成绩单图片，不写入通用磁盘缓存。

以下会话不能合并：

- 学校 CAS 同时需要“禁止自动重定向”和“HTTPS 升级后自动重定向”两套 delegate。
- 教学中心需要自己的 HTTPS 升级 delegate 和可失效会话恢复逻辑。
- `jwb`、`jwb_cjd` 和教学中心认证不能共享业务登录状态。

## 3. 性能策略

- 社区模块不再为每个 Service 新建 `URLSession`，减少重复 DNS、TLS 和连接预热。
- 共享网络会话启用 `waitsForConnectivity`，短暂断网或网络切换时由系统等待可用连接，
  但上层仍需正确呈现最终的超时、DNS 和离线错误。
- `BIT101APIClient.shared` 复用 CAS 的两套重定向会话，设置检查和日程前置登录不再重复创建会话。
- 成绩两类页面复用相同的 bit-login 传输会话。
- 课表拿到目标学期后，并发请求课程、考试和首周日期，避免三个独立请求串行等待。
- 头像和全屏图片继续使用已有本地缓存/展示策略，但 HTTP 状态码统一校验，避免把错误页当图片解码。

不做无条件自动重试。学校接口和写请求具有认证与副作用语义，盲目重试可能重复提交或拉长失败时间。

## 4. 错误规则

- 非 HTTP 响应统一视为 `invalidResponse`。
- 社区 `401` 映射回各模块原有的 `notLoggedIn` 错误，保持 UI 文案不变。
- 其它非 2xx 响应优先读取 JSON 的 `message`、`msg`、`detail` 或 `error`。
- 取消和超时仍由现有 ViewModel / 学校 Service 按业务语义处理。

## 5. 测试要求

`NetworkClientTests` 使用注入的 `HTTPTransport`，不访问真实服务器，覆盖：

- HTTP 状态码和结构化错误消息
- `fake-cookie` 的 required / optional 行为
- URL 查询参数
- snake_case JSON 解码
- multipart 文件字段契约

修改共享网络层时至少运行 `build-for-testing` 和测试 Target。修改学校认证链路后还必须做真机同步冒烟验证。
