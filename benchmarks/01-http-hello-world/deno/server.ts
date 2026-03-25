const PORT = parseInt(Deno.env.get("PORT") || "3000");

Deno.serve({ port: PORT }, () => {
  return new Response("Hello, World!", {
    headers: { "Content-Type": "text/plain" },
  });
});
