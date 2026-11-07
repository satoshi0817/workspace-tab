#!/usr/bin/env python3
"""Run isolated WebKit integration checks against a local fixture."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import threading

class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'<!doctype html><title>Browser fixture</title><nav class="notion-sidebar-container">Sidebar</nav><a href="/child" target="_blank">Child</a>'
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass

if __name__ == "__main__":
    root = Path(__file__).resolve().parent.parent
    server = ThreadingHTTPServer(("127.0.0.1", 48761), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        result = subprocess.run([str(root / "build/Workspace Tabs.app/Contents/MacOS/WorkspaceTabs"), "--browser-checks"], timeout=180)
    finally:
        server.shutdown()
        server.server_close()
    raise SystemExit(result.returncode)
