"""Read-only diagnostic tools the agent may call.

Safety model:
  * allow-list only: the agent can call exactly these functions, nothing else
  * every argument is validated (Kubernetes name regex, bounded numbers)
  * commands run WITHOUT a shell (no injection), with a timeout
  * no tool can change anything - the ServiceAccount is read-only too (deploy/rbac.yaml)
  * output is truncated and secrets are redacted before the model sees it
"""

from __future__ import annotations

import json
import re
import subprocess
import urllib.parse
import urllib.request
from collections.abc import Callable

from .redact import redact

K8S_NAME = re.compile(r"^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$")
MAX_OUTPUT = 6_000


class ToolError(Exception):
    """Raised for invalid input; returned to the model as an error result."""


def _name(value: str, field: str) -> str:
    if not isinstance(value, str) or not K8S_NAME.match(value):
        raise ToolError(f"invalid {field}: must be a valid Kubernetes name")
    return value


def _clip(text: str) -> str:
    text = redact(text)
    if len(text) > MAX_OUTPUT:
        return "...(truncated)...\n" + text[-MAX_OUTPUT:]
    return text


def run_kubectl(args: list[str]) -> str:
    """Default runner. Separate function so tests can swap it out."""
    proc = subprocess.run(  # noqa: S603 - fixed binary, validated args, no shell
        ["kubectl", *args], capture_output=True, text=True, timeout=20, check=False
    )
    return proc.stdout if proc.returncode == 0 else f"kubectl error: {proc.stderr.strip()}"


def http_get_json(url: str) -> dict:
    with urllib.request.urlopen(url, timeout=10) as resp:  # noqa: S310 - operator-configured URL
        return json.loads(resp.read())


class Toolbox:
    def __init__(
        self,
        prometheus_url: str | None = None,
        kubectl: Callable[[list[str]], str] = run_kubectl,
        http: Callable[[str], dict] = http_get_json,
    ):
        self.prometheus_url = prometheus_url
        self.kubectl = kubectl
        self.http = http

    # ---- tools -------------------------------------------------------------
    def get_pods(self, namespace: str) -> str:
        ns = _name(namespace, "namespace")
        return _clip(self.kubectl(["get", "pods", "-n", ns, "-o", "wide"]))

    def get_pod_logs(self, namespace: str, pod: str, tail: int = 100, previous: bool = False) -> str:
        ns, p = _name(namespace, "namespace"), _name(pod, "pod")
        tail = max(1, min(int(tail), 300))
        args = ["logs", p, "-n", ns, f"--tail={tail}", "--all-containers=true"]
        if previous:  # logs of the crashed container - key for CrashLoopBackOff
            args.append("--previous")
        return _clip(self.kubectl(args))

    def get_events(self, namespace: str) -> str:
        ns = _name(namespace, "namespace")
        return _clip(self.kubectl(["get", "events", "-n", ns, "--sort-by=.lastTimestamp"]))

    def describe_deployment(self, namespace: str, deployment: str) -> str:
        ns, d = _name(namespace, "namespace"), _name(deployment, "deployment")
        return _clip(self.kubectl(["describe", "deployment", d, "-n", ns]))

    def prometheus_query(self, promql: str) -> str:
        if not self.prometheus_url:
            raise ToolError("Prometheus is not configured")
        if not isinstance(promql, str) or len(promql) > 500:
            raise ToolError("promql must be a string under 500 chars")
        url = f"{self.prometheus_url.rstrip('/')}/api/v1/query?" + urllib.parse.urlencode({"query": promql})
        data = self.http(url)
        return _clip(json.dumps(data.get("data", {}).get("result", []))[:MAX_OUTPUT])

    # ---- registry ----------------------------------------------------------
    def dispatch(self, name: str, args: dict) -> str:
        fn = {
            "get_pods": self.get_pods,
            "get_pod_logs": self.get_pod_logs,
            "get_events": self.get_events,
            "describe_deployment": self.describe_deployment,
            "prometheus_query": self.prometheus_query,
        }.get(name)
        if fn is None:
            raise ToolError(f"unknown tool: {name}")
        try:
            return fn(**args)
        except TypeError as e:  # wrong/missing arguments from the model
            raise ToolError(f"bad arguments for {name}: {e}") from e


NS = {"type": "string", "description": "Kubernetes namespace"}

TOOL_SPECS = [
    {
        "name": "get_pods",
        "description": "List pods in a namespace with status, restarts, node and age.",
        "input_schema": {"type": "object", "properties": {"namespace": NS}, "required": ["namespace"]},
    },
    {
        "name": "get_pod_logs",
        "description": "Recent logs of a pod. Set previous=true for the last crashed container.",
        "input_schema": {
            "type": "object",
            "properties": {
                "namespace": NS,
                "pod": {"type": "string"},
                "tail": {"type": "integer", "minimum": 1, "maximum": 300},
                "previous": {"type": "boolean"},
            },
            "required": ["namespace", "pod"],
        },
    },
    {
        "name": "get_events",
        "description": "Kubernetes events in a namespace, oldest first (scheduling, OOMKilled, probes...).",
        "input_schema": {"type": "object", "properties": {"namespace": NS}, "required": ["namespace"]},
    },
    {
        "name": "describe_deployment",
        "description": "kubectl describe for a deployment: image, replicas, conditions, recent rollout.",
        "input_schema": {
            "type": "object",
            "properties": {"namespace": NS, "deployment": {"type": "string"}},
            "required": ["namespace", "deployment"],
        },
    },
    {
        "name": "prometheus_query",
        "description": "Run an instant PromQL query, e.g. error rate or restarts.",
        "input_schema": {
            "type": "object",
            "properties": {"promql": {"type": "string"}},
            "required": ["promql"],
        },
    },
]
