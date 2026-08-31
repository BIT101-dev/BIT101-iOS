export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method !== "GET" || url.pathname !== "/emergency-update.json") {
      return new Response("Not Found", { status: 404 });
    }

    let config = null;
    try {
      config = await env.EMERGENCY_CONFIG.get("emergency-update", {
        type: "json",
        cacheTtl: 30,
      });
    } catch {
      // 配置读取失败时保持关闭，不能让远端故障阻断 App 启动。
    }

    if (!config || typeof config.enabled !== "boolean") {
      config = { schema_version: 1, enabled: false };
    }

    return Response.json(config, {
      headers: {
        "Cache-Control": "no-store",
        "Access-Control-Allow-Origin": "*",
        "X-Content-Type-Options": "nosniff",
      },
    });
  },
};
