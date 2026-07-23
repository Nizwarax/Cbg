#!/usr/bin/env python3
"""
CBG: Upload page @ /  +  TTYD terminal @ /term
All on ONE port (7681) — no extra ports needed.
"""
import os, sys, subprocess, cgi, shutil
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn
from urllib.request import urlopen
from urllib.error import URLError

PORT = 7681
TTYD_PORT = 7682
ROOT = "/data/cbg"
os.chdir(ROOT)

# Start ttyd in background on localhost only
subprocess.Popen(
    ["ttyd","-p",str(TTYD_PORT),"-i","127.0.0.1","-W","-c","lo:sayangenicbg46","bash"],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
)

class H(BaseHTTPRequestHandler):
    def log_message(self,*a,**k): pass

    def _proxy(self):
        try:
            url = f"http://127.0.0.1:{TTYD_PORT}{self.path[5:]}" if self.path.startswith("/term") else f"http://127.0.0.1:{TTYD_PORT}{self.path}"
            req = urlopen(url, timeout=30)
            data = req.read()
            self.send_response(req.status)
            for k,v in req.getheaders():
                if k.lower() in ("transfer-encoding","connection"): continue
                self.send_header(k,v)
            self.end_headers()
            self.wfile.write(data)
        except URLError:
            self.send_response(502); self.end_headers(); self.wfile.write(b"ttyd not ready")

    def do_GET(self):
        if self.path in ("/term","/term/") or self.path.startswith("/term/") or self.path.startswith("/token") or self.path.startswith("/ws"):
            return self._proxy()
        # list + upload form
        self.send_response(200); self.send_header("Content-Type","text/html;charset=utf-8"); self.end_headers()
        rows=[]
        for f in sorted(os.listdir(".")):
            p=os.path.join(".",f)
            if not os.path.isfile(p): continue
            sz=os.path.getsize(p)
            sz=f"{sz//1024} KB" if sz<1024*1024 else f"{sz//1048576} MB"
            rows.append(f'<tr><td><a href="/get/{f}" download>{f}</a></td><td>{sz}</td><td><a href="/del/{f}" style="color:#dc2626">del</a></td></tr>')
        html=f'''<!doctype html><title>CBG — Upload/Download</title><body style="font-family:system-ui,sans-serif;max-width:820px;margin:24px auto;padding:0 16px">
<h1>💎 COINBUSTER — File Manager</h1>
<p><a href="/term" style="padding:8px 14px;background:#6366f1;color:#fff;border-radius:8px;text-decoration:none">➡️ BUKA TERMINAL</a></p>
<hr>
<h2>📤 Upload APK</h2>
<form method="post" enctype="multipart/form-data">
<input type="file" name="f" multiple required style="padding:8px;width:100%;font-size:15px">
<button style="margin-top:10px;padding:12px 24px;font-size:15px;background:#10b981;color:#fff;border:0;border-radius:8px;cursor:pointer">UPLOAD</button>
</form>
<hr>
<h2>📁 Files (klik = download)</h2>
<table style="width:100%;border-collapse:collapse"><thead><tr style="text-align:left;border-bottom:1px solid #333"><th>Name</th><th>Size</th><th></th></tr></thead>
<tbody>{''.join(rows)}</tbody></table></body>'''
        self.wfile.write(html.encode())

    def do_POST(self):
        ct = self.headers["Content-Type"]
        if ct and "multipart/form-data" in ct:
            form = cgi.FieldStorage(fp=self.rfile, environ={"REQUEST_METHOD":"POST","CONTENT_TYPE":ct}, keep_blank_values=True)
            files = form["f"] if isinstance(form["f"],list) else [form["f"]]
            for x in files:
                if x.filename:
                    with open(x.filename,"wb") as out: shutil.copyfileobj(x.file, out)
        self.send_response(303); self.send_header("Location","/"); self.end_headers()

class TS(ThreadingMixIn, HTTPServer):
    allow_reuse_address = True
    daemon_threads = True

if __name__=="__main__":
    print(f"CBG running on :{PORT}  / = upload   /term = terminal")
    TS(("0.0.0.0",PORT),H).serve_forever()
