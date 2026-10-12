import asyncio
import json
import socket

import pytest
from mcp.client import Client
from mcp.server.mcpserver.exceptions import ToolError

from devops_mcp import backends, guards
from devops_mcp.server import mcp


def run(coro):
    return asyncio.run(coro)


async def call(name, args):
    async with Client(mcp) as c:
        return await c.call_tool(name, args)


def text(result):
    return result.content[0].text


@pytest.fixture(autouse=True)
def fake_dns(monkeypatch):
    """example.com -> public IP, internal.corp -> private IP, metadata -> link-local."""
    table = {
        "example.com": "93.184.216.34",
        "internal.corp.com": "10.0.0.5",
        "evil-rebind.com": "169.254.169.254",
    }

    def fake_getaddrinfo(host, *a, **k):
        if host not in table:
            raise socket.gaierror("not found")
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (table[host], 0))]

    monkeypatch.setattr(socket, "getaddrinfo", fake_getaddrinfo)
    monkeypatch.delenv("ALLOW_PRIVATE_TARGETS", raising=False)


# ------------------------------------------------------------------ discovery
def test_all_tools_are_marked_read_only():
    async def go():
        async with Client(mcp) as c:
            return (await c.list_tools()).tools

    tools = run(go())
    names = {t.name for t in tools}
    assert {"check_url", "tls_certificate", "prometheus_query", "k8s_pods", "github_actions_runs"} <= names
    assert all(t.annotations.read_only_hint and not t.annotations.destructive_hint for t in tools)


def test_triage_prompt_available():
    async def go():
        async with Client(mcp) as c:
            return await c.get_prompt("triage_service", {"namespace": "prod", "url": "https://example.com"})

    msg = run(go()).messages[0].content.text
    assert "k8s_pods" in msg and "Change nothing" in msg


# ------------------------------------------------------------------ SSRF protection
@pytest.mark.parametrize(
    "url",
    [
        "http://169.254.169.254/latest/meta-data/",  # cloud metadata
        "http://127.0.0.1:8080/admin",
        "http://10.1.2.3/",
        "http://[::1]/",
        "https://internal.corp.com/",  # public name, private IP
        "https://evil-rebind.com/",  # public name -> metadata IP
        "file:///etc/passwd",
        "https://user:pass@example.com/",
    ],
)
def test_check_url_blocks_ssrf(url, monkeypatch):
    monkeypatch.setattr(backends, "http_get", lambda u: pytest.fail("must not fetch"))
    r = run(call("check_url", {"url": url}))
    assert r.is_error


def test_private_targets_allowed_only_when_opted_in(monkeypatch):
    monkeypatch.setenv("ALLOW_PRIVATE_TARGETS", "1")
    monkeypatch.setattr(
        backends, "http_get", lambda u: {"status": 200, "latency_ms": 3, "location": None, "server": None}
    )
    assert not run(call("check_url", {"url": "http://10.1.2.3/"})).is_error


def test_check_url_happy_path(monkeypatch):
    monkeypatch.setattr(
        backends,
        "http_get",
        lambda u: {"status": 301, "latency_ms": 42, "location": "https://www.example.com/", "server": "x"},
    )
    out = json.loads(text(run(call("check_url", {"url": "https://example.com"}))))
    assert out["up"] is True and out["location"] == "https://www.example.com/"


# ------------------------------------------------------------------ TLS
def test_tls_flags_expiring_soon(monkeypatch):
    monkeypatch.setattr(
        backends,
        "tls_certificate",
        lambda h, p: {
            "days_left": 9,
            "issuer": "Let's Encrypt",
            "not_after": "x",
            "subject_alt_names": [],
            "tls_version": "TLSv1.3",
        },
    )
    out = json.loads(text(run(call("tls_certificate", {"host": "example.com"}))))
    assert out["status"] == "EXPIRING_SOON"


def test_tls_rejects_bad_host():
    assert run(call("tls_certificate", {"host": "not a host; rm -rf /"})).is_error


# ------------------------------------------------------------------ kubernetes
def test_k8s_rejects_injection(monkeypatch):
    monkeypatch.setattr(backends, "kubectl", lambda a: pytest.fail("must not run"))
    r = run(call("k8s_pods", {"namespace": "prod --all-namespaces"}))
    assert r.is_error and "valid Kubernetes name" in text(r)


def test_k8s_logs_caps_tail_and_supports_previous(monkeypatch):
    seen = {}
    monkeypatch.setattr(backends, "kubectl", lambda a: seen.update(args=a) or "log line")
    run(call("k8s_logs", {"namespace": "prod", "pod": "api-1", "tail": 99999, "previous": True}))
    assert "--tail=500" in seen["args"] and "--previous" in seen["args"]


def test_k8s_output_truncated(monkeypatch):
    monkeypatch.setattr(backends, "kubectl", lambda a: "x" * 50_000)
    assert len(text(run(call("k8s_events", {"namespace": "prod"})))) < 6200


# ------------------------------------------------------------------ prometheus
def test_prometheus_requires_config(monkeypatch):
    monkeypatch.delenv("PROMETHEUS_URL", raising=False)
    r = run(call("prometheus_alerts", {}))
    assert r.is_error and "PROMETHEUS_URL" in text(r)


def test_prometheus_query(monkeypatch):
    monkeypatch.setenv("PROMETHEUS_URL", "http://prom:9090")
    seen = {}

    def fake(url, headers=None):
        seen["url"] = url
        return {"status": "success", "data": {"result": [{"metric": {"job": "api"}, "value": [0, "1"]}]}}

    monkeypatch.setattr(backends, "get_json", fake)
    out = json.loads(text(run(call("prometheus_query", {"promql": 'up{job="api"}'}))))
    assert out["series"] == 1 and "query=up%7Bjob%3D%22api%22%7D" in seen["url"]


# ------------------------------------------------------------------ GitHub
def test_github_runs_summarised(monkeypatch):
    monkeypatch.setattr(
        backends,
        "get_json",
        lambda url, headers=None: {
            "workflow_runs": [
                {
                    "name": "ci",
                    "head_branch": "main",
                    "status": "completed",
                    "conclusion": "failure",
                    "head_sha": "abcdef123",
                    "html_url": "https://github.com/x/y/actions/runs/1",
                }
            ]
        },
    )
    out = json.loads(text(run(call("github_actions_runs", {"repo": "eswarsurya/devops-portfolio"}))))
    assert out["failing"] == 1 and out["runs"][0]["commit"] == "abcdef1"


def test_github_rejects_bad_repo():
    assert run(call("github_actions_runs", {"repo": "../../etc"})).is_error


# ------------------------------------------------------------------ unit: guards
def test_guards_ipv6_and_literal_ips():
    with pytest.raises(ToolError, match="SSRF"):
        guards.public_url("http://[fd00::1]/")
    assert guards.public_url("https://example.com/health")
