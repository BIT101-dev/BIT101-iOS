# Universal Links 与 Cloudflare 配置

BIT101 分享链接使用独立域名：

- `https://open.aihelpme.dev/gallery/{id}`
- `https://open.aihelpme.dev/course/{id}`

安装 App 时由 iOS 打开对应详情。微信、QQ 等内置浏览器可能不触发 Universal Link，因此
Cloudflare Worker 会显示一个轻量中转页，而不是立即重定向。用户可在中转页尝试用
`bit101://` 打开 App，或者继续访问 `https://bit101.cn` 的对应网页。该 Worker 与现有的
`privacy.aihelpme.dev` Pages 项目互相独立，不会改动隐私页面。

## Cloudflare 配置

1. 在 Cloudflare 控制台进入 **Workers & Pages**，新建一个 Worker。
2. 部署下方代码。
3. 进入 Worker 的 **Settings → Domains & Routes → Add → Custom Domain**。
4. 填写 `open.aihelpme.dev`。Cloudflare 会自动创建所需 DNS 记录和证书。

```js
const AASA = {
  applinks: {
    apps: [],
    details: [{
      appID: "Y2T72736G3.BIT101-dev.BIT101-iOS",
      paths: ["/gallery/*", "/course/*"]
    }]
  }
};

const APP_STORE_URL = "https://apps.apple.com/cn/app/bit101/id6761147125";
const APP_ICON_URL = "https://is1-ssl.mzstatic.com/image/thumb/Purple211/v4/0c/23/7f/0c237f6c-ddf5-b329-27ab-a3c5fc10115c/AppIcon-0-0-1x_U007epad-0-1-85-220.png/512x512bb.jpg";
const SHARE_ICON_URL = "https://open.aihelpme.dev/share-icon.jpg";

function escapeHTML(value) {
  return value.replace(/[&<>"']/g, character => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;"
  })[character]);
}

function landingPage(url, route, id) {
  const appURL = `bit101://${route}/${id}`;
  const webURL = new URL(`https://bit101.cn/${route}/${id}`);
  webURL.search = url.search;

  const safeAppURL = escapeHTML(appURL);
  const safeWebURL = escapeHTML(webURL.href);
  const safeUniversalURL = escapeHTML(url.href);
  const appURLForScript = JSON.stringify(appURL).replace(/</g, "\\u003c");
  const contentName = route === "gallery" ? "话题" : "课程";
  const shareTitle = `在 BIT101 查看${contentName}`;
  const shareDescription = `打开 BIT101 查看这个${contentName}。`;

  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
  <meta name="color-scheme" content="light dark">
  <link rel="icon" type="image/jpeg" sizes="512x512" href="${SHARE_ICON_URL}">
  <link rel="apple-touch-icon" href="${SHARE_ICON_URL}">
  <meta name="apple-itunes-app" content="app-id=6761147125, app-argument=${safeUniversalURL}">
  <meta property="og:type" content="website">
  <meta property="og:site_name" content="BIT101">
  <meta property="og:title" content="${shareTitle}">
  <meta property="og:description" content="${shareDescription}">
  <meta property="og:url" content="${safeUniversalURL}">
  <meta property="og:image" content="${SHARE_ICON_URL}">
  <meta property="og:image:secure_url" content="${SHARE_ICON_URL}">
  <meta property="og:image:type" content="image/jpeg">
  <meta property="og:image:width" content="512">
  <meta property="og:image:height" content="512">
  <meta name="description" content="${shareDescription}">
  <meta itemprop="name" content="${shareTitle}">
  <meta itemprop="description" content="${shareDescription}">
  <meta itemprop="image" content="${SHARE_ICON_URL}">
  <title>${shareTitle}</title>
  <style>
    :root {
      font-family: -apple-system, BlinkMacSystemFont, sans-serif;
      color-scheme: light;
      --brand: #ff9a57;
      --brand-deep: #e97832;
      --cream: #fff7ee;
      --ink: #241711;
      --muted: #826f64;
    }
    body {
      margin: 0; min-height: 100vh; display: grid; place-items: center;
      background: radial-gradient(circle at top, #ffe3c8 0, var(--cream) 48%, #f8eee5 100%);
      color: var(--ink);
    }
    main {
      box-sizing: border-box; width: min(88vw, 420px); padding: 36px 28px 28px;
      text-align: center; background: rgba(255,255,255,.82); border: 1px solid rgba(255,154,87,.24);
      border-radius: 28px; box-shadow: 0 18px 55px rgba(91,50,25,.12);
      transform: translateY(-9vh);
    }
    .logo {
      width: 96px; height: 96px; border-radius: 23px; display: block; margin: 0 auto 20px;
      box-shadow: 0 10px 28px rgba(233,120,50,.25);
    }
    h1 { font-size: 26px; margin-bottom: 10px; }
    p { color: var(--muted); line-height: 1.5; margin-bottom: 28px; }
    a { display: block; box-sizing: border-box; margin: 12px 0; padding: 14px 18px; border-radius: 12px;
        text-decoration: none; font-weight: 600; }
    .primary { color: #28150b; background: linear-gradient(135deg, #ffad74, var(--brand));
      box-shadow: 0 8px 20px rgba(233,120,50,.22); }
    .secondary { color: var(--brand-deep); background: #fffaf5; border: 1px solid rgba(233,120,50,.55); }
    .plain { color: var(--muted); }
    @media (prefers-color-scheme: dark) {
      :root { color-scheme: dark; --cream: #17100d; --ink: #fff3e9; --muted: #c7afa0; }
      body { background: radial-gradient(circle at top, #422719 0, #17100d 52%, #100b09 100%); }
      main { background: rgba(38,25,19,.9); border-color: rgba(255,154,87,.3);
        box-shadow: 0 18px 55px rgba(0,0,0,.3); }
      .secondary { background: #2c1c15; }
    }
    @media (max-height: 600px) {
      main { margin: 24px 0; transform: none; }
    }
  </style>
</head>
<body>
  <main>
    <img class="logo" src="${SHARE_ICON_URL}" alt="BIT101">
    <h1>在 BIT101 中查看</h1>
    <p>如果没有自动打开，请点击下方按钮。微信或 QQ 内无法唤起时，请先选择“在浏览器打开”。</p>
    <a class="primary" href="${safeAppURL}">打开 BIT101</a>
    <a class="secondary" href="${safeWebURL}">继续访问网页版</a>
    <a class="plain" href="${APP_STORE_URL}">前往 App Store</a>
  </main>
  <script>
    (() => {
      // 每个浏览器历史记录项只尝试一次：返回或刷新不会重试；用户再次点开同一链接
      // 会形成新的记录项，因此仍会自动尝试。
      const previousState = history.state && typeof history.state === "object"
        ? history.state
        : {};
      if (previousState.bit101AutoOpenAttempted) return;
      history.replaceState(
        { ...previousState, bit101AutoOpenAttempted: true },
        document.title,
        location.href
      );
      setTimeout(() => { window.location.href = ${appURLForScript}; }, 250);
    })();
  </script>
</body>
</html>`;
}

export default {
  async fetch(request) {
    const url = new URL(request.url);

    if (
      url.pathname === "/.well-known/apple-app-site-association" ||
      url.pathname === "/apple-app-site-association"
    ) {
      return Response.json(AASA, {
        headers: {
          "Cache-Control": "public, max-age=300",
          "Content-Type": "application/json"
        }
      });
    }

    if (url.pathname === "/share-icon.jpg") {
      const upstream = await fetch(APP_ICON_URL);
      return new Response(upstream.body, {
        headers: {
          "Cache-Control": "public, max-age=604800",
          "Content-Type": "image/jpeg"
        }
      });
    }

    const match = url.pathname.match(/^\/(gallery|course)\/(\d+)\/?$/);
    if (match) {
      return new Response(landingPage(url, match[1], match[2]), {
        headers: {
          "Cache-Control": "public, max-age=300",
          "Content-Type": "text/html; charset=utf-8",
          "Content-Security-Policy": "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'"
        }
      });
    }

    return Response.redirect("https://bit101.cn/gallery/", 302);
  }
};
```

## 必须满足

- `https://open.aihelpme.dev/.well-known/apple-app-site-association` 必须直接返回 HTTP 200，不能跳转。
- AASA 文件名没有 `.json` 扩展名，响应类型为 `application/json`。
- Apple Developer 后台的 App ID 必须启用 Associated Domains，并重新生成开发及发布描述文件。
- 部署 AASA 后重新安装 App，再从“信息”“备忘录”等外部 App 点击分享链接验证。
- AASA 会被 Apple CDN 缓存，配置变更不一定立即生效。

Cloudflare 免费套餐足以承担此跳转页和 AASA JSON。

## 为什么不能直接 302

Universal Link 是否唤起 App，是 iOS 在网络请求之前决定的。微信、QQ 或用户在浏览器地址栏
粘贴链接时，系统可能选择继续访问网页；若 Worker 此时直接 302 到 `bit101.cn`，原始关联域名
会丢失，之后选择“在浏览器打开”也只会停在网页。中转页保留 `open.aihelpme.dev`，并提供
自定义 URL Scheme 按钮作为这些场景的二次唤起入口。
