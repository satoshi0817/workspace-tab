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
        if self.path == "/download-page":
            body = b'''<!doctype html><title>Download fixture</title><main>Download fixture: keep this page visible.</main><input id="draft" value="keep unsent input"><a id="attachment" href="/download.bin">Attachment</a><a id="text" href="/download.txt">Text attachment</a><a id="attribute" href="/inline.txt" download="attribute.txt">Download attribute</a><a id="popup" href="/download.bin" target="_blank">New window download</a><a id="cookie" href="/download-cookie" download="cookie.bin">Authenticated download</a><a id="slow" href="/download-slow.bin">Slow download</a><a id="broken" href="/download-broken.bin">Interrupted download</a><a id="postlink" href="#">POST download</a><form id="post" method="post" action="/download-post"><input name="value" value="original"></form><button id="blob" onclick="const a=document.createElement('a');a.href=window.URL.createObjectURL(new Blob(['blob fixture content'],{type:'text/plain'}));a.download='blob.txt';document.body.append(a);a.click();a.remove();">Blob</button>'''
        if self.path in ("/download.bin", "/download.txt", "/inline.txt", "/download-cookie", "/download-slow.bin", "/download-broken.bin"):
            if self.path == "/download-cookie" and "download-profile=alpha" not in (self.headers.get("Cookie") or ""):
                self.send_error(403); return
            body = b"Workspace Tabs download fixture\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain" if self.path.endswith(".txt") else "application/octet-stream")
            if self.path != "/inline.txt":
                self.send_header("Content-Disposition", 'attachment; filename="fixture.txt"')
            self.send_header("Content-Length", str(len(body) + (100 if self.path == "/download-broken.bin" else 0)))
            self.end_headers()
            if self.path == "/download-slow.bin": time.sleep(1)
            self.wfile.write(body)
            if self.path == "/download-broken.bin": self.close_connection = True
            return
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
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.path != "/download-post" or body != b"value=original":
            self.send_error(400); return
        body = b"original POST response"
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", 'attachment; filename="post.txt"')
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
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
        result = subprocess.run([str(root / "build/Workspace Tabs.app/Contents/MacOS/WorkspaceTabs"), "--download-checks" if "--downloads" in sys.argv else "--browser-checks"], timeout=180)
    finally:
        server.shutdown()
        server.server_close()
    raise SystemExit(result.returncode)
