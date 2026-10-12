"""Input validation and SSRF protection shared by all tools."""

from __future__ import annotations

import ipaddress
import os
import re
import socket
from urllib.parse import urlparse

from mcp.server.mcpserver.exceptions import ToolError

K8S_NAME = re.compile(r"^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$")
HOSTNAME = re.compile(r"^(?=.{1,253}$)([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$")
REPO = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$")


def k8s_name(value: str, field: str) -> str:
    if not isinstance(value, str) or not K8S_NAME.match(value):
        raise ToolError(f"{field} must be a valid Kubernetes name (lowercase, digits, '-')")
    return value


def hostname(value: str) -> str:
    if not isinstance(value, str) or not HOSTNAME.match(value):
        raise ToolError("host must be a public DNS name, e.g. example.com")
    return value.lower()


def repo(value: str) -> str:
    if not isinstance(value, str) or not REPO.match(value):
        raise ToolError("repo must look like owner/name")
    return value


def _is_public(ip: str) -> bool:
    addr = ipaddress.ip_address(ip)
    return addr.is_global and not addr.is_multicast


def resolve_public(host: str) -> list[str]:
    """Resolve and refuse private/loopback/link-local targets (SSRF guard).

    Without this, an AI could be talked into probing 169.254.169.254 (cloud
    metadata credentials) or internal admin panels via "check this URL".
    Set ALLOW_PRIVATE_TARGETS=1 only when running inside a trusted network.
    """
    try:
        infos = socket.getaddrinfo(host, None, proto=socket.IPPROTO_TCP)
    except socket.gaierror as e:
        raise ToolError(f"DNS lookup failed for {host}: {e}") from e
    ips = sorted({i[4][0] for i in infos})
    if os.getenv("ALLOW_PRIVATE_TARGETS") != "1":
        blocked = [ip for ip in ips if not _is_public(ip)]
        if blocked:
            raise ToolError(f"refusing non-public address {blocked[0]} for {host} (SSRF protection)")
    return ips


def public_url(url: str) -> str:
    p = urlparse(url)
    if p.scheme not in ("http", "https"):
        raise ToolError("only http(s) URLs are allowed")
    if p.username or p.password:
        raise ToolError("URLs with credentials are not allowed")
    if not p.hostname:
        raise ToolError("URL has no host")
    host = p.hostname
    try:  # literal IPs are checked directly
        ipaddress.ip_address(host)
        if os.getenv("ALLOW_PRIVATE_TARGETS") != "1" and not _is_public(host):
            raise ToolError(f"refusing non-public address {host} (SSRF protection)")
    except ValueError:
        resolve_public(hostname(host))
    return url
