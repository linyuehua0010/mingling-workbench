import http.server
import os
import socketserver
import sys
from urllib.parse import unquote

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "stage"))
OUT = os.path.abspath(os.path.join(os.path.dirname(__file__), "evidence", "vm-upload"))
os.makedirs(ROOT, exist_ok=True)
os.makedirs(OUT, exist_ok=True)

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def do_POST(self):
        if not self.path.startswith("/upload/"):
            self.send_error(404)
            return
        name = os.path.basename(unquote(self.path[len("/upload/"):]))
        if not name:
            self.send_error(400)
            return
        length = int(self.headers.get("Content-Length", "0"))
        data = self.rfile.read(length)
        with open(os.path.join(OUT, name), "wb") as f:
            f.write(data)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True

with Server(("0.0.0.0", 8000), Handler) as httpd:
    print("serving", ROOT, "uploads", OUT, flush=True)
    httpd.serve_forever()
