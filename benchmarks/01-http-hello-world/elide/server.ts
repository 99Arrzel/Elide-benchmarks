// Elide uses its own built-in HTTP API: Elide.http
const app = Elide.http;
const PORT = parseInt(process.env.PORT || "3000");

app.router.handle("GET", "/", (request, response, context) => {
  response.send(200, "Hello, World!");
});

app.config.port = PORT;
app.config.onBind(() => {
  console.log(`Elide listening on port ${PORT}`);
});
app.start();
