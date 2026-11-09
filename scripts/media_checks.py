#!/usr/bin/env python3
"""Local WebKit PCM smoke test. --live requires an explicit click and OS consent."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import plistlib
import subprocess
import threading

PAGE = r'''<!doctype html><meta charset="utf-8"><title>ローカル音声検証</title>
<style>body{font:16px system-ui;margin:40px;line-height:1.8}button{font:inherit;padding:12px}pre{white-space:pre-wrap}</style>
<h1>マイクのローカル検証</h1>
<p>テスト開始後、マイクを3秒だけ使用します。音声は保存せず、外部へ送信しません。<br>
macOSとサイトの確認が表示された場合は、許可してください。</p>
<button id="start" hidden onclick="startTest(true)">マイクのテスト開始</button><pre id="status">WebKitの音声機能を確認中</pre>
<script>
window.startTest=async live=>{
  if(window.running)return;window.running=true;document.getElementById('start').disabled=true;
  const report={live,secureContext:isSecureContext,getUserMedia:typeof navigator.mediaDevices?.getUserMedia==='function',audioWorklet:false,frames:0};
  let ctx,stream,source,node,gain,timer,timeout;
  try {
    document.getElementById('status').textContent=live?'マイクの許可を確認しています…':'音声処理を確認しています…';
    ctx=new AudioContext({sampleRate:16000});await ctx.resume();
    report.audioWorklet=!!ctx.audioWorklet;report.sampleRate=ctx.sampleRate;
    await ctx.audioWorklet.addModule('/worklet.js');
    if(live){stream=await navigator.mediaDevices.getUserMedia({audio:true,video:false});source=ctx.createMediaStreamSource(stream);report.liveTracks=stream.getAudioTracks().filter(t=>t.readyState==='live').length;}
    else {source=ctx.createOscillator();source.start();}
    node=new AudioWorkletNode(ctx,'frame-counter');gain=ctx.createGain();gain.gain.value=0;
    const completed=new Promise((resolve,reject)=>{
      node.port.onmessage=e=>{report.frames+=e.data;if(report.frames>=ctx.sampleRate*3)resolve();};
      node.onprocessorerror=()=>reject(new Error('AudioWorklet processor failed'));
      timeout=setTimeout(()=>reject(new Error('Timed out waiting for PCM frames')),8000);
    });
    source.connect(node).connect(gain).connect(ctx.destination);
    document.getElementById('status').textContent='3秒間の音声処理を確認しています…';
    await completed;
    report.ok=report.frames>0 && (!live || report.liveTracks>0);
  } catch(e){report.ok=false;report.errorName=e.name;report.error=e.message;}
  finally {
    clearTimeout(timeout);stream?.getTracks().forEach(t=>t.stop());source?.disconnect();node?.disconnect();gain?.disconnect();
    if(ctx && ctx.state!=='closed')await ctx.close();
    report.tracksStopped=!stream || stream.getTracks().every(t=>t.readyState==='ended');
    document.getElementById('status').textContent=JSON.stringify(report,null,2);window.testResult=report;
  }
};
</script>'''
WORKLET = '''class Counter extends AudioWorkletProcessor {
  process(inputs) { const n=inputs[0]?.[0]?.length||0; if(n)this.port.postMessage(n);return true; }
} registerProcessor('frame-counter',Counter);'''

class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/media-check", "/worklet.js"):
            self.send_error(404)
            return
        script = self.path == "/worklet.js"
        body = (WORKLET if script else PAGE).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/javascript" if script else "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'none'")
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass

if __name__ == "__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("--app",default="build/Workspace Tabs.app")
    parser.add_argument("--live",action="store_true",help="Wait for user click before microphone capture")
    args=parser.parse_args()
    app=Path(args.app).resolve()
    info=plistlib.loads((app/"Contents/Info.plist").read_bytes())
    assert info.get("NSMicrophoneUsageDescription"), "Missing microphone usage description"
    signed=subprocess.run(["codesign","-d","--entitlements","-","--xml",str(app)],capture_output=True,check=True)
    entitlements=plistlib.loads(signed.stdout)
    assert entitlements.get("com.apple.security.device.audio-input") is True, "Missing audio-input entitlement"
    print("PASS bundle microphone purpose and signed audio-input entitlement",flush=True)
    server=ThreadingHTTPServer(("127.0.0.1",0),Fixture)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    env=os.environ.copy();env["WORKSPACE_TABS_MEDIA_CHECK_URL"]=f"http://127.0.0.1:{server.server_port}/media-check"
    try:
        command=[str(app/"Contents/MacOS/WorkspaceTabs"),"--media-checks"]
        if args.live:command.append("--live-microphone")
        result=subprocess.run(command,env=env,timeout=260 if args.live else 45)
    finally:
        server.shutdown();server.server_close()
    raise SystemExit(result.returncode)
