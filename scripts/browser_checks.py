#!/usr/bin/env python3
"""Run isolated WebKit integration checks against a local fixture."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import threading
import base64
import time
import sys

class Fixture(BaseHTTPRequestHandler):
    flaky_icon_requests = 0
    gateway_attempts = 0
    def do_GET(self):
        body = b'<!doctype html><title>Browser fixture</title><link rel="icon" href="/icon.png"><nav class="notion-sidebar-container">Sidebar</nav><a href="/child" target="_blank">Child</a>'
        mime = "text/html; charset=utf-8"
        if self.path in ("/gateway-timeout", "/server-unavailable"):
            self.send_error(504 if self.path == "/gateway-timeout" else 503)
            return
        if self.path == "/startup-retry":
            Fixture.gateway_attempts += 1
            if Fixture.gateway_attempts == 1:
                self.send_error(504)
                return
        if self.path == "/failed-resource":
            body = b'<!doctype html><title>Healthy page</title><main>Usable content</main><img src="/server-unavailable">'
        if self.path == "/native-skeleton":
            body = b'<!doctype html><title>Native skeleton</title><body><div id="skeleton" role="progressbar" style="position:fixed;inset:0;background:#eee"></div><script>setTimeout(()=>{document.getElementById("skeleton").remove();document.body.innerHTML="<main>Native ready content</main>"},1200)</script></body>'
        if self.path == "/skeleton-delayed":
            body = b'<!doctype html><title>Skeleton ready</title><body><script>setTimeout(()=>{document.body.innerHTML="<main>Ready content</main>"},700)</script></body>'
        if self.path == "/skeleton-slow":
            time.sleep(4)
        if self.path == "/slow-page":
            body = b'<!doctype html><title>DOM ready fixture</title><img src="/slow-image">'
        if self.path == "/slow-image":
            time.sleep(2)
            body = b''
        if self.path == "/flaky-icon.png":
            Fixture.flaky_icon_requests += 1
            if Fixture.flaky_icon_requests <= 2:
                self.send_error(503)
                return
        if self.path in ("/icon.png", "/flaky-icon.png"):
            body = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aF1sAAAAASUVORK5CYII=")
            mime = "image/png"
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass
    def log_message(self, *args):
        pass

class FixtureServer(ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        # WebKit closes the socket when a deliberately failed response is cancelled.
        if isinstance(sys.exc_info()[1], (BrokenPipeError, ConnectionResetError)):
            return
        super().handle_error(request, client_address)

if __name__ == "__main__":
    root = Path(__file__).resolve().parent.parent
    server = FixtureServer(("127.0.0.1", 48761), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        result = subprocess.run([str(root / "build/Workspace Tabs.app/Contents/MacOS/WorkspaceTabs"), "--browser-checks"], timeout=180)
    finally:
        server.shutdown()
        server.server_close()
    raise SystemExit(result.returncode)
