"""HTTP server running on Elide's Python runtime.
NOTE: Elide added Python HTTP serving intrinsics in beta10.
This may need to use Elide's specific API. Adjust if needed."""
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
        pass

if __name__ == "__main__":
    server = HTTPServer(("", PORT), Handler)
    print(f"Elide Python listening on port {PORT}")
    server.serve_forever()
