#!/usr/bin/env python3
"""Tiny demo HTTP service used as the thing you tunnel to.

Unlike `python3 -m http.server` this reports the client address it actually
saw, which is the fastest way to tell a tunnel apart from a direct connection.
"""

import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    role = os.environ.get("ROLE", "unknown")
    service_port = os.environ.get("SERVICE_PORT", "?")

    def do_GET(self):
        body = f"""<!doctype html>
<html>
  <head><title>lab demo</title></head>
  <body style="font-family:system-ui;margin:3rem;line-height:1.6">
    <h1>Internal demo service</h1>
    <p>Served by <strong>{self.role}</strong> on container port <strong>{self.service_port}</strong>.</p>
    <p>My TCP peer: <code>{self.client_address[0]}:{self.client_address[1]}</code></p>
    <p>This port is not published to the host. You are only seeing this page
       because an SSH tunnel carried it.</p>
    <p>Request path: <code>{self.path}</code></p>
  </body>
</html>
""".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        sys.stderr.write("[%s] %s - %s\n" % (self.role, self.client_address[0], fmt % args))


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()