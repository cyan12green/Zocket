// Minimal Bun.serve benchmark server: GET / -> 200 empty, POST /echo -> body echo.
// Usage: bun run server.ts [port]
const port = Number(process.argv[2] ?? 8080);

Bun.serve({
  port,
  hostname: "127.0.0.1",
  async fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === "/echo" && req.method === "POST") {
      const body = await req.text();
      return new Response(body);
    }
    return new Response("");
  },
});
