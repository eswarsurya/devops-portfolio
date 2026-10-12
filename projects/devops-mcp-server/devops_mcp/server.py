"""devops-mcp: read-only DevOps tools for AI assistants over the Model Context Protocol.

Add to Claude Desktop / Claude Code and ask things like:
  "Is api.example.com up, and when does its certificate expire?"
  "Why is the payments namespace unhealthy?"
  "Did the last CI run on eswarsurya/devops-portfolio pass?"

Every tool is read-only (and marked readOnlyHint), validates its inputs, and
refuses private network targets unless explicitly allowed.
"""

from __future__ import annotations

import os
import urllib.parse

from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from mcp.types import ToolAnnotations

from . import backends, guards

MAX_TEXT = 6000
READ_ONLY = ToolAnnotations(readOnlyHint=True, destructiveHint=False, idempotentHint=True)
READ_ONLY_WEB = ToolAnnotations(readOnlyHint=True, destructiveHint=False, openWorldHint=True)

mcp = MCPServer(
    "devops-mcp",
    version="0.1.0",
    instructions=(
        "Read-only DevOps tools: website health, TLS certificates, Prometheus, Kubernetes, "
        "GitHub Actions. Nothing here can change any system. Quote tool output as evidence."
    ),
)


def _clip(text: str) -> str:
    return text if len(text) <= MAX_TEXT else "...(truncated)...\n" + text[-MAX_TEXT:]


# ------------------------------------------------------------------ web
@mcp.tool(annotations=READ_ONLY_WEB)
def check_url(url: str) -> dict:
    """Check if a public URL is up: HTTP status, latency, redirect target.
    Redirects are reported, not followed."""
    guards.public_url(url)
    result = backends.http_get(url)
    result["up"] = 200 <= result["status"] < 400
    return {"url": url, **result}


@mcp.tool(annotations=READ_ONLY_WEB)
def tls_certificate(host: str, port: int = 443) -> dict:
    """TLS certificate details for a host: expiry date, days left, issuer, SANs.
    Flags certificates expiring within 14 days."""
    host = guards.hostname(host)
    if not 1 <= port <= 65535:
        raise ToolError("port must be 1-65535")
    guards.resolve_public(host)
    cert = backends.tls_certificate(host, port)
    days = cert["days_left"]
    cert["status"] = "EXPIRED" if days < 0 else "EXPIRING_SOON" if days <= 14 else "OK"
    return {"host": host, **cert}


# ------------------------------------------------------------------ prometheus
def _prom_url() -> str:
    url = os.getenv("PROMETHEUS_URL")
    if not url:
        raise ToolError("PROMETHEUS_URL is not configured for this server")
    return url.rstrip("/")


@mcp.tool(annotations=READ_ONLY)
def prometheus_query(promql: str) -> dict:
    """Run an instant PromQL query, e.g. 'sum by (job) (up)' or an error-rate expression."""
    if not promql or len(promql) > 500:
        raise ToolError("promql must be 1-500 characters")
    data = backends.get_json(f"{_prom_url()}/api/v1/query?" + urllib.parse.urlencode({"query": promql}))
    if data.get("status") != "success":
        raise ToolError(f"Prometheus error: {data.get('error', 'unknown')}")
    results = data["data"]["result"]
    return {"query": promql, "series": len(results), "result": results[:50]}


@mcp.tool(annotations=READ_ONLY)
def prometheus_alerts() -> dict:
    """List alerts currently firing or pending in Prometheus."""
    data = backends.get_json(f"{_prom_url()}/api/v1/alerts")
    alerts = data.get("data", {}).get("alerts", [])
    return {
        "count": len(alerts),
        "alerts": [
            {
                "name": a.get("labels", {}).get("alertname"),
                "state": a.get("state"),
                "severity": a.get("labels", {}).get("severity"),
                "summary": a.get("annotations", {}).get("summary"),
                "since": a.get("activeAt"),
            }
            for a in alerts[:50]
        ],
    }


# ------------------------------------------------------------------ kubernetes
@mcp.tool(annotations=READ_ONLY)
def k8s_pods(namespace: str) -> str:
    """Pods in a namespace with status, restarts and node."""
    ns = guards.k8s_name(namespace, "namespace")
    return _clip(backends.kubectl(["get", "pods", "-n", ns, "-o", "wide"]))


@mcp.tool(annotations=READ_ONLY)
def k8s_events(namespace: str) -> str:
    """Recent Kubernetes events in a namespace (BackOff, OOMKilled, FailedScheduling...)."""
    ns = guards.k8s_name(namespace, "namespace")
    return _clip(backends.kubectl(["get", "events", "-n", ns, "--sort-by=.lastTimestamp"]))


@mcp.tool(annotations=READ_ONLY)
def k8s_logs(namespace: str, pod: str, tail: int = 100, previous: bool = False) -> str:
    """Last lines of a pod's logs. previous=true shows the crashed container's logs."""
    ns, p = guards.k8s_name(namespace, "namespace"), guards.k8s_name(pod, "pod")
    tail = max(1, min(tail, 500))
    args = ["logs", p, "-n", ns, f"--tail={tail}", "--all-containers=true"]
    if previous:
        args.append("--previous")
    return _clip(backends.kubectl(args))


# ------------------------------------------------------------------ CI
@mcp.tool(annotations=READ_ONLY_WEB)
def github_actions_runs(repo: str, limit: int = 5) -> dict:
    """Latest GitHub Actions runs for owner/repo: workflow, branch, status, conclusion, link."""
    r = guards.repo(repo)
    limit = max(1, min(limit, 20))
    headers = {"Accept": "application/vnd.github+json"}
    if token := os.getenv("GITHUB_TOKEN"):
        headers["Authorization"] = f"Bearer {token}"
    data = backends.get_json(f"https://api.github.com/repos/{r}/actions/runs?per_page={limit}", headers)
    runs = [
        {
            "workflow": x.get("name"),
            "branch": x.get("head_branch"),
            "status": x.get("status"),
            "conclusion": x.get("conclusion"),
            "commit": (x.get("head_sha") or "")[:7],
            "started": x.get("run_started_at"),
            "url": x.get("html_url"),
        }
        for x in data.get("workflow_runs", [])
    ]
    failing = [x for x in runs if x["conclusion"] == "failure"]
    return {"repo": r, "runs": runs, "failing": len(failing)}


# ------------------------------------------------------------------ prompt
@mcp.prompt()
def triage_service(namespace: str, url: str = "") -> str:
    """A ready-made investigation plan for an unhealthy service."""
    steps = [
        f"1. k8s_pods for namespace '{namespace}': look for CrashLoopBackOff, Pending, high restarts.",
        f"2. k8s_events for '{namespace}': scheduling, OOMKilled, probe failures.",
        "3. k8s_logs (previous=true) for any restarting pod.",
        "4. prometheus_alerts: is anything firing that explains it?",
    ]
    if url:
        steps.append(f"5. check_url {url} and tls_certificate for its host.")
    steps.append("Finish with: likely cause, evidence (quoted), and next steps for a human. Change nothing.")
    return "Investigate this service step by step:\n" + "\n".join(steps)


def main() -> None:
    transport = os.getenv("MCP_TRANSPORT", "stdio")
    mcp.run(transport=transport)


if __name__ == "__main__":
    main()
