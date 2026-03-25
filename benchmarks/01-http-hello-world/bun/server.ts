const PORT = parseInt(process.env.PORT || "3000");

Bun.serve({
  port: PORT,
  fetch() {
    return new Response("Hello, World!", {
      headers: { "Content-Type": "text/plain" },
    });
  },
});

console.log(`Bun listening on port ${PORT}`);
