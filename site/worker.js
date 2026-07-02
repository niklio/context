export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    // Releases live in R2 (too big for static assets).
    const match = url.pathname.match(/^\/(ContextLayer-[\w.]+\.zip)$/);
    if (match) {
      const obj = await env.RELEASES.get(match[1]);
      if (!obj) return new Response("not found", { status: 404 });
      return new Response(obj.body, {
        headers: {
          "content-type": "application/zip",
          "content-length": obj.size,
          "content-disposition": `attachment; filename="${match[1]}"`,
          "cache-control": "public, max-age=3600",
        },
      });
    }
    return env.ASSETS.fetch(request);
  },
};
