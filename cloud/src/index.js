// Website hosting only. Claude Code and its subscription token stay on the Mac.
export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    if (path === "/api/step" || path.startsWith("/v1/")) {
      return Response.json(
        { error: "The model runs through the local Claude Code bridge. Open http://127.0.0.1:8766/demo/ on your Mac." },
        { status: 503, headers: { "Cache-Control": "no-store" } },
      );
    }
    return env.ASSETS.fetch(request);
  },
};
