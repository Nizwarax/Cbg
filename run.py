#!/usr/bin/env python3
"""CBG file manager plus an authenticated ttyd terminal on port 7681."""
import base64
import cgi
import hmac
import http.client
import os
import pwd
import select
import shutil
import socket
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn
from urllib.parse import urlsplit

PORT = 7681
TTYD_PORT = 7682
ROOT = "/data/cbg"
TTYD_USER = "cbg"
TTYD_WORKDIR = "/home/cbg/work"
AUTH_HEADER = "X-Ttyd-Auth"
TTYD_PROCESS = None

_HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "proxy-connection",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}


def configured_credentials():
    """Return the configured terminal credentials, or None if they are invalid."""
    username = os.environ.get("TTYD_USERNAME", "")
    password = os.environ.get("TTYD_PASSWORD", "")
    if (
        not username
        or not password
        or ":" in username
        or any(ch in username + password for ch in "\r\n")
    ):
        return None
    return username, password


def start_ttyd():
    """Start ttyd loopback-only as an unprivileged account, behind proxy auth."""
    if configured_credentials() is None:
        raise RuntimeError("Set TTYD_USERNAME and TTYD_PASSWORD to enable the terminal")

    account = pwd.getpwnam(TTYD_USER)
    child_env = {
        "PATH": os.environ.get("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"),
        "HOME": account.pw_dir,
        "USER": account.pw_name,
        "LOGNAME": account.pw_name,
        "LANG": os.environ.get("LANG", "C.UTF-8"),
        "TERM": "xterm-256color",
    }
    return subprocess.Popen(
        [
            "ttyd",
            "-p", str(TTYD_PORT),
            "-i", "lo",
            "-b", "/term",
            "-H", AUTH_HEADER,
            "-W",
            "-w", TTYD_WORKDIR,
            "/bin/bash",
        ],
        cwd=TTYD_WORKDIR,
        env=child_env,
        user=account.pw_uid,
        group=account.pw_gid,
        umask=0o077,
        stdout=subprocess.DEVNULL,
        stderr=sys.stderr,
        close_fds=True,
    )


class H(BaseHTTPRequestHandler):
    def log_message(self, *args, **kwargs):
        pass

    def _send_text(self, status, message, headers=None):
        body = message.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def _is_terminal_path(self):
        path = urlsplit(self.path).path
        return path == "/term" or path.startswith("/term/")

    def _authorized(self, credentials):
        authorization = self.headers.get("Authorization", "")
        scheme, separator, encoded = authorization.partition(" ")
        if not separator or scheme.lower() != "basic":
            return False
        try:
            supplied = base64.b64decode(encoded.strip(), validate=True)
        except (ValueError, TypeError):
            return False
        expected = (credentials[0] + ":" + credentials[1]).encode("utf-8")
        return hmac.compare_digest(supplied, expected)

    def _proxy(self):
        credentials = configured_credentials()
        if credentials is None:
            return self._send_text(
                503,
                "Terminal auth is not configured; set TTYD_USERNAME and TTYD_PASSWORD.",
            )
        if not self._authorized(credentials):
            return self._send_text(
                401,
                "Authentication required.",
                {"WWW-Authenticate": 'Basic realm="CBG Terminal", charset="UTF-8"'},
            )

        parsed = urlsplit(self.path)
        if parsed.path == "/term":
            suffix = "?" + parsed.query if parsed.query else ""
            self.send_response(307)
            self.send_header("Location", "/term/" + suffix)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        try:
            if self.headers.get("Upgrade", "").lower() == "websocket":
                self._proxy_websocket()
            else:
                self._proxy_http()
        except (OSError, http.client.HTTPException, ValueError):
            if not getattr(self, "_response_started", False):
                self._send_text(502, "ttyd not ready")

    def _request_headers(self, websocket=False):
        headers = {}
        connection_tokens = {
            item.strip().lower()
            for item in self.headers.get("Connection", "").split(",")
            if item.strip()
        }
        excluded = {"host", "proxy-connection", "authorization", AUTH_HEADER.lower()}
        if not websocket:
            excluded |= _HOP_BY_HOP | connection_tokens
        for name, value in self.headers.items():
            lowered = name.lower()
            if lowered not in excluded:
                headers[name] = value
        headers["Host"] = f"127.0.0.1:{TTYD_PORT}"
        # ttyd's --auth-header option trusts this private header. Always replace
        # any client-supplied value so it cannot be used to bypass proxy auth.
        headers[AUTH_HEADER] = "authorized"
        return headers

    def _proxy_http(self):
        body = None
        content_length = self.headers.get("Content-Length")
        if content_length:
            body = self.rfile.read(int(content_length))

        connection = http.client.HTTPConnection("127.0.0.1", TTYD_PORT, timeout=15)
        try:
            headers = self._request_headers()
            headers["Connection"] = "close"
            connection.request(self.command, self.path, body=body, headers=headers)
            response = connection.getresponse()
            self._response_started = True
            self.send_response(response.status, response.reason)
            connection_tokens = {
                item.strip().lower()
                for item in response.getheader("Connection", "").split(",")
                if item.strip()
            }
            for name, value in response.getheaders():
                lowered = name.lower()
                if lowered in _HOP_BY_HOP or lowered in connection_tokens:
                    continue
                self.send_header(name, value)
            self.end_headers()
            while True:
                chunk = response.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
        finally:
            connection.close()

    def _proxy_websocket(self):
        upstream = socket.create_connection(("127.0.0.1", TTYD_PORT), timeout=15)
        with upstream:
            upstream.settimeout(15)
            request_line = f"{self.command} {self.path} HTTP/1.1\r\n".encode("ascii")
            upstream.sendall(request_line)
            for name, value in self.headers.items():
                if name.lower() in ("host", "proxy-connection", "authorization", AUTH_HEADER.lower()):
                    continue
                upstream.sendall(f"{name}: {value}\r\n".encode("latin-1"))
            upstream.sendall(f"Host: 127.0.0.1:{TTYD_PORT}\r\n".encode("ascii"))
            upstream.sendall(f"{AUTH_HEADER}: authorized\r\n\r\n".encode("ascii"))

            response = bytearray()
            marker = b"\r\n\r\n"
            while marker not in response:
                chunk = upstream.recv(4096)
                if not chunk:
                    raise ConnectionError("ttyd closed before the WebSocket handshake")
                response.extend(chunk)
                if len(response) > 65536:
                    raise ValueError("ttyd response headers are too large")

            header_end = response.index(marker) + len(marker)
            raw_headers = bytes(response[:header_end])
            remainder = bytes(response[header_end:])
            self.connection.sendall(raw_headers)
            self._response_started = True
            if remainder:
                self.connection.sendall(remainder)

            status_line = raw_headers.split(b"\r\n", 1)[0].split()
            if len(status_line) < 2 or status_line[1] != b"101":
                # A non-upgrade response is passed through until ttyd closes it.
                while True:
                    chunk = upstream.recv(65536)
                    if not chunk:
                        return
                    self.connection.sendall(chunk)

            self.close_connection = True
            upstream.settimeout(None)
            self.connection.settimeout(None)
            while True:
                readable, _, _ = select.select([self.connection, upstream], [], [])
                for source in readable:
                    chunk = source.recv(65536)
                    if not chunk:
                        return
                    destination = upstream if source is self.connection else self.connection
                    destination.sendall(chunk)

    def do_GET(self):
        if self._is_terminal_path():
            return self._proxy()
        self.send_response(200)
        self.send_header("Content-Type", "text/html;charset=utf-8")
        self.end_headers()
        rows = []
        for filename in sorted(os.listdir(".")):
            path = os.path.join(".", filename)
            if not os.path.isfile(path):
                continue
            size = os.path.getsize(path)
            size = f"{size // 1024} KB" if size < 1024 * 1024 else f"{size // 1048576} MB"
            rows.append(
                f'<tr><td><a href="/get/{filename}" download>{filename}</a></td>'
                f'<td>{size}</td><td><a href="/del/{filename}" style="color:#dc2626">del</a></td></tr>'
            )
        html = f'''<!doctype html><title>CBG — Upload/Download</title><body style="font-family:system-ui,sans-serif;max-width:820px;margin:24px auto;padding:0 16px">
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

    def do_HEAD(self):
        if self._is_terminal_path():
            return self._proxy()
        self.send_error(404)

    def do_OPTIONS(self):
        if self._is_terminal_path():
            return self._proxy()
        self.send_error(404)

    def do_POST(self):
        if self._is_terminal_path():
            return self._proxy()
        content_type = self.headers.get("Content-Type", "")
        if "multipart/form-data" in content_type:
            form = cgi.FieldStorage(
                fp=self.rfile,
                environ={"REQUEST_METHOD": "POST", "CONTENT_TYPE": content_type},
                keep_blank_values=True,
            )
            files = form["f"] if isinstance(form["f"], list) else [form["f"]]
            for uploaded in files:
                if uploaded.filename:
                    with open(uploaded.filename, "wb") as output:
                        shutil.copyfileobj(uploaded.file, output)
        self.send_response(303)
        self.send_header("Location", "/")
        self.end_headers()


class TS(ThreadingMixIn, HTTPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    global TTYD_PROCESS
    os.chdir(ROOT)
    try:
        TTYD_PROCESS = start_ttyd()
        print("ttyd started on loopback; terminal access is protected by Basic Auth.", flush=True)
    except (OSError, KeyError, RuntimeError) as error:
        # Do not print credentials or subprocess arguments to application logs.
        print(f"Terminal unavailable: {error}", file=sys.stderr, flush=True)
    print(f"CBG running on :{PORT}  / = upload   /term = terminal", flush=True)
    TS(("0.0.0.0", PORT), H).serve_forever()


if __name__ == "__main__":
    main()
