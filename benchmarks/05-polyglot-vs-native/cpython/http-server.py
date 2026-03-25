"""Minimal HTTP server using built-in http.server for fair comparison."""
import os
from http.server import HTTPServer, BaseHTTPRequestHandler

PORT = int(os.environ.get("PORT", "3000"))

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"Hello, World!")

    def log_message(self, format, *args):
        pass  # suppress request logging for benchmark

if __name__ == "__main__":
    server = HTTPServer(("", PORT), Handler)
    print(f"CPython listening on port {PORT}")
    server.serve_forever()
