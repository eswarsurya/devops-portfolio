"""The only code that touches the network or kubectl. Tests replace these functions."""

from __future__ import annotations

import json
import socket
import ssl
import subprocess
import time
import urllib.error
import urllib.request
from datetime import UTC, datetime


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Don't follow redirects blindly: a public URL could redirect to an internal one."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def http_get(url: str, timeout: float = 8.0) -> dict:
    opener = urllib.request.build_opener(NoRedirect)
    req = urllib.request.Request(url, method="GET", headers={"User-Agent": "devops-mcp/0.1"})
    start = time.perf_counter()
    try:
        with opener.open(req, timeout=timeout) as r:
            status, headers = r.status, dict(r.headers)
            r.read(2048)  # read a little so latency includes first bytes, never the whole body
    except urllib.error.HTTPError as e:  # 3xx/4xx/5xx still give useful info
        status, headers = e.code, dict(e.headers or {})
    return {
        "status": status,
        "latency_ms": round((time.perf_counter() - start) * 1000),
        "location": headers.get("Location"),
        "server": headers.get("Server"),
    }


def tls_certificate(host: str, port: int = 443, timeout: float = 8.0) -> dict:
    ctx = ssl.create_default_context()
    with socket.create_connection((host, port), timeout=timeout) as sock:
        with ctx.wrap_socket(sock, server_hostname=host) as tls:
            cert = tls.getpeercert()
            version = tls.version()
    not_after = datetime.strptime(cert["notAfter"], "%b %d %H:%M:%S %Y %Z").replace(tzinfo=UTC)
    issuer = dict(x[0] for x in cert.get("issuer", []))
    return {
        "not_after": not_after.isoformat(),
        "days_left": (not_after - datetime.now(UTC)).days,
        "issuer": issuer.get("organizationName") or issuer.get("commonName"),
        "subject_alt_names": [v for k, v in cert.get("subjectAltName", []) if k == "DNS"][:10],
        "tls_version": version,
    }


def kubectl(args: list[str]) -> str:
    proc = subprocess.run(  # noqa: S603 - fixed binary, validated args, no shell
        ["kubectl", *args], capture_output=True, text=True, timeout=20, check=False
    )
    if proc.returncode != 0:
        return f"kubectl error: {proc.stderr.strip()[:500]}"
    return proc.stdout


def get_json(url: str, headers: dict | None = None, timeout: float = 10.0) -> dict:
    req = urllib.request.Request(url, headers={"User-Agent": "devops-mcp/0.1", **(headers or {})})
    with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310 - fixed/operator URLs
        return json.loads(r.read())
