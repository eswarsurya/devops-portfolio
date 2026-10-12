"""Demo without a Kubernetes cluster.

A simulated cluster where a bad deploy (revision 7) removed DATABASE_URL, so
the API pods crash-loop. The tools return realistic kubectl output for it.

  ANTHROPIC_API_KEY=sk-ant-... python -m triage.demo   # REAL Claude investigates the simulated cluster
  python -m triage.demo --replay                       # no key: replays a recorded-style run (labelled)

Then open http://localhost:8080 and watch it live. Approver token: demo
"""

from __future__ import annotations

import argparse
import os
import threading
import time
from types import SimpleNamespace as NS

from .tools import Toolbox

PODS = """NAME                            READY   STATUS             RESTARTS      AGE   IP           NODE
incident-api-6d9f7c8b5d-4kq2x   0/1     CrashLoopBackOff   6 (40s ago)   7m    10.244.1.7   worker
incident-api-6d9f7c8b5d-p8w1z   0/1     CrashLoopBackOff   6 (35s ago)   7m    10.244.2.4   worker2
incident-api-7b5c9d6f4-x2m9n    1/1     Terminating        0             2d    10.244.1.3   worker"""

EVENTS = """LAST SEEN   TYPE      REASON              OBJECT                               MESSAGE
8m          Normal    ScalingReplicaSet   deployment/incident-api              Scaled up replica set incident-api-6d9f7c8b5d to 2
7m          Normal    Pulled              pod/incident-api-6d9f7c8b5d-4kq2x    Container image "ghcr.io/eswarsurya/docker-cicd-pipeline:a1b2c3d" already present
40s         Warning   BackOff             pod/incident-api-6d9f7c8b5d-4kq2x    Back-off restarting failed container app
35s         Warning   BackOff             pod/incident-api-6d9f7c8b5d-p8w1z    Back-off restarting failed container app"""

LOGS = """INFO:     Started server process [1]
INFO:     Waiting for application startup.
ERROR:    Traceback (most recent call last):
  File "/app/app/db.py", line 12, in connect
    url = os.environ["DATABASE_URL"]
KeyError: 'DATABASE_URL'
ERROR:    Application startup failed. Exiting."""

DESCRIBE = """Name:                   incident-api
Namespace:              prod
Annotations:            deployment.kubernetes.io/revision: 7
Replicas:               2 desired | 2 updated | 2 total | 0 available | 2 unavailable
Pod Template:
  Containers:
   app:
    Image:      ghcr.io/eswarsurya/docker-cicd-pipeline:a1b2c3d
    Environment:
      APP_ENV:  prod
Conditions:
  Type           Status  Reason
  Available      False   MinimumReplicasUnavailable
  Progressing    True    ReplicaSetUpdated
OldReplicaSets:  incident-api-7b5c9d6f4 (1/1 replicas created)   <- revision 6 had DATABASE_URL from secret/db
NewReplicaSet:   incident-api-6d9f7c8b5d (2/2 replicas created)"""


def fake_kubectl(args: list[str]) -> str:
    time.sleep(0.6)  # feel like a real cluster call
    if args[:2] == ["get", "pods"]:
        return PODS
    if args[:2] == ["get", "events"]:
        return EVENTS
    if args[0] == "logs":
        return LOGS
    if args[:2] == ["describe", "deployment"]:
        return DESCRIBE
    if args[0] in ("rollout", "scale"):
        return f"deployment.apps/incident-api {'rolled back' if 'undo' in args else 'updated'} (simulated)"
    return "error: not found"


def fake_http(url: str) -> dict:
    return {"data": {"result": [{"metric": {"job": "incident-api"}, "value": [0, "0"]}]}}


def demo_toolbox() -> Toolbox:
    return Toolbox(prometheus_url="http://prometheus.sim", kubectl=fake_kubectl, http=fake_http)


ALERT = {
    "status": "firing",
    "fingerprint": "demo-1",
    "labels": {
        "alertname": "IncidentApiDown",
        "severity": "critical",
        "namespace": "prod",
        "deployment": "incident-api",
    },
    "annotations": {"summary": "No healthy incident-api targets for 2 minutes"},
}


# ------------------------------------------------------------- replay (no key)
def _tool(id_, name, inp):
    return NS(type="tool_use", id=id_, name=name, input=inp)


def _text(t):
    return NS(type="text", text=t)


REPLAY = [
    [
        _text("[REPLAY MODE: scripted, not a live model] Checking pod health in prod first."),
        _tool("t1", "get_pods", {"namespace": "prod"}),
    ],
    [
        _text("Both new pods are in CrashLoopBackOff. Checking events for the timeline."),
        _tool("t2", "get_events", {"namespace": "prod"}),
    ],
    [
        _text(
            "Crashes started right after a new ReplicaSet rolled out. Reading the crashed container's logs."
        ),
        _tool(
            "t3",
            "get_pod_logs",
            {"namespace": "prod", "pod": "incident-api-6d9f7c8b5d-4kq2x", "previous": True},
        ),
    ],
    [
        _text("Startup fails on a missing DATABASE_URL. Comparing with the previous revision."),
        _tool("t4", "describe_deployment", {"namespace": "prod", "deployment": "incident-api"}),
    ],
    [
        _tool(
            "t5",
            "submit_diagnosis",
            {
                "summary": "Revision 7 of incident-api crash-loops because DATABASE_URL is missing.",
                "likely_cause": "The latest deploy dropped the DATABASE_URL env var (revision 6 loaded it from secret/db).",
                "evidence": [
                    "KeyError: 'DATABASE_URL'",
                    "Available False MinimumReplicasUnavailable",
                    "revision 6 had DATABASE_URL from secret/db",
                ],
                "next_steps": [
                    "kubectl -n prod rollout undo deployment/incident-api",
                    "Restore the env.valueFrom secretKeyRef for DATABASE_URL in the Helm values",
                    "Add a startup config check to CI so this fails before deploy",
                ],
                "confidence": "high",
                "proposed_action": {
                    "type": "rollout_undo",
                    "namespace": "prod",
                    "deployment": "incident-api",
                    "reason": "Restore last healthy revision while the config is fixed",
                },
            },
        )
    ],
]


class ReplayClient:
    def __init__(self):
        self._i = 0
        self.messages = self

    def create(self, **_):
        time.sleep(1.2)
        content = REPLAY[min(self._i, len(REPLAY) - 1)]
        self._i += 1
        return NS(content=content, stop_reason="tool_use")


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--replay", action="store_true", help="no API key: scripted run, clearly labelled")
    p.add_argument("--port", type=int, default=8080)
    args = p.parse_args()

    import uvicorn

    from . import app as appmod

    os.environ.setdefault("APPROVER_TOKEN", "demo")
    appmod.make_toolbox = demo_toolbox
    appmod.kubectl_runner = fake_kubectl
    if args.replay or not os.getenv("ANTHROPIC_API_KEY"):
        print("No ANTHROPIC_API_KEY (or --replay): using the scripted REPLAY client.")
        appmod.make_client = ReplayClient

    def fire():
        time.sleep(2)
        from fastapi.testclient import TestClient

        TestClient(appmod.app).post("/alertmanager", json={"alerts": [ALERT]})

    threading.Thread(target=fire, daemon=True).start()
    print(f"Open http://localhost:{args.port}  (approver token: demo)")
    uvicorn.run(appmod.app, host="127.0.0.1", port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
