export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method !== "GET" || url.pathname !== "/emergency-update.json") {
      return new Response("Not Found", { status: 404 });
    }

    const headers = { "Cache-Control": "no-store", "Access-Control-Allow-Origin": "*", "X-Content-Type-Options": "nosniff" };
    let config;
    try {
      config = await env.EMERGENCY_CONFIG.get("emergency-update", {
        type: "json",
        cacheTtl: 30,
      });
    } catch {
      return Response.json({ error: "configuration_unavailable" }, { status: 503, headers });
    }

    if (!config || config.schema_version !== 1 || typeof config.enabled !== "boolean"
      || config.enabled && (![config.notice_id, config.title, config.message].every(value => typeof value === "string" && value.trim())
        || !Number.isSafeInteger(config.maximum_affected_build) || config.maximum_affected_build < 0)) {
      return Response.json({ error: "invalid_configuration" }, { status: 503, headers });
    }

    return Response.json(config, { headers });
  },
};
