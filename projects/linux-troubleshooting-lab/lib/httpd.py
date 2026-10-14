"""Tiny HTTP(S) server used as the "application" in the network scenarios.

GET /            -> a one-line body naming the service
GET /blob?size=N -> N bytes (used to push enough data to see TCP behaviour)
"""

import argparse
import ctypes
import http.server
import ssl
import sys
from urllib.parse import parse_qs, urlparse


def set_process_name(name: str) -> None:
    # PR_SET_NAME = 15. Makes the process show up as <name> in ps, top and ss.
    ctypes.CDLL(None).prctl(15, name.encode()[:15], 0, 0, 0)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--bind", default="0.0.0.0")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--name", default="lab-httpd")
    p.add_argument("--tls-cert")
    p.add_argument("--tls-key")
    args = p.parse_args()

    set_process_name(args.name)

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):  # noqa: N802 (stdlib naming)
            url = urlparse(self.path)
            if url.path == "/blob":
                size = int(parse_qs(url.query).get("size", ["1000000"])[0])
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(size))
                self.end_headers()
                chunk = b"x" * 65536
                left = size
                while left > 0:
                    n = min(left, len(chunk))
                    self.wfile.write(chunk[:n])
                    left -= n
                return
            body = f"{args.name} ok\n".encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *a):
            sys.stderr.write("%s %s\n" % (self.address_string(), fmt % a))

    srv = http.server.ThreadingHTTPServer((args.bind, args.port), Handler)
    if args.tls_cert:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(args.tls_cert, args.tls_key)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    print(f"{args.name} listening on {args.bind}:{args.port}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
