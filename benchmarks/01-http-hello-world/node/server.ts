import { createServer } from "node:http";

const PORT = parseInt(process.env.PORT || "3000");

const server = createServer((req, res) => {
  res.writeHead(200, { "Content-Type": "text/plain" });
  res.end("Hello, World!");
});

server.listen(PORT, () => {
  console.log(`Node.js listening on port ${PORT}`);
});
