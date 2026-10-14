"""Stand-in for a pager: records alerts that Rundeck sends, and serves them back for checks.

POST /alert?...   -> records a firing alert
POST /resolve?... -> records a recovery
GET  /alerts      -> everything received so far, as JSON lines
"""
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

LOG = "/data/alerts.jsonl"


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        url = urlparse(self.path)
        if url.path not in ("/alert", "/resolve"):
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode(errors="replace")
        record = {
            "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "type": url.path.strip("/"),
            **{k: v[0] for k, v in parse_qs(url.query).items()},
            "body_bytes": len(body),
        }
        with open(LOG, "a") as f:
            f.write(json.dumps(record) + "\n")
        print(json.dumps(record), flush=True)
        self.send_response(204)
        self.end_headers()

    def do_GET(self):
        if self.path != "/alerts":
            self.send_error(404)
            return
        try:
            data = open(LOG, "rb").read()
        except FileNotFoundError:
            data = b""
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 9000), Handler).serve_forever()
