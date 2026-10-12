"""Human-approved remediation.

The agent may PROPOSE one of a few safe, reversible actions. Nothing runs until
a human clicks Approve. Each action is validated again at execution time.
"""

from __future__ import annotations

from collections.abc import Callable

from .tools import ToolError, _name, run_kubectl

# action -> (description, builder of kubectl args)
ALLOWED_ACTIONS = {
    "rollout_restart": "Restart all pods of a deployment (rolling, zero downtime)",
    "rollout_undo": "Roll a deployment back to its previous revision",
    "scale": "Scale a deployment to N replicas (1-10)",
}


def validate(action: dict) -> dict:
    """Return a clean copy of the action or raise ToolError."""
    if not isinstance(action, dict):
        raise ToolError("action must be an object")
    kind = action.get("type")
    if kind not in ALLOWED_ACTIONS:
        raise ToolError(f"action type must be one of {sorted(ALLOWED_ACTIONS)}")
    clean = {
        "type": kind,
        "namespace": _name(action.get("namespace", ""), "namespace"),
        "deployment": _name(action.get("deployment", ""), "deployment"),
    }
    if kind == "scale":
        try:
            replicas = int(action.get("replicas"))
        except (TypeError, ValueError) as e:
            raise ToolError("scale needs an integer 'replicas'") from e
        if not 1 <= replicas <= 10:
            raise ToolError("replicas must be between 1 and 10")
        clean["replicas"] = replicas
    return clean


def to_kubectl_args(a: dict) -> list[str]:
    target = f"deployment/{a['deployment']}"
    if a["type"] == "rollout_restart":
        return ["rollout", "restart", target, "-n", a["namespace"]]
    if a["type"] == "rollout_undo":
        return ["rollout", "undo", target, "-n", a["namespace"]]
    return ["scale", target, f"--replicas={a['replicas']}", "-n", a["namespace"]]


def execute(action: dict, kubectl: Callable[[list[str]], str] = run_kubectl) -> str:
    clean = validate(action)
    return kubectl(to_kubectl_args(clean))
