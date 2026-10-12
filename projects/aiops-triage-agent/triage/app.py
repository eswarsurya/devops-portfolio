"""Webhook receiver + live dashboard.

Alertmanager POSTs /alertmanager -> 202 -> the agent investigates in the background
-> every step streams to the dashboard over Server-Sent Events (/incidents/{id}/stream)
-> the diagnosis goes to Slack -> a human can Approve the proposed fix in the UI.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import pathlib
import time
from threading import Lock

from fastapi import BackgroundTasks, FastAPI, Header, HTTPException
from fastapi.responses import FileResponse, StreamingResponse

from . import remediate
from .agent import Diagnosis, triage
from .notify import post_to_slack, to_slack_blocks
from .store import Store
from .tools import Toolbox, ToolError

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("triage.app")

app = FastAPI(title="aiops-triage-agent")
store = Store()
STATIC = pathlib.Path(__file__).parent / "static"

DEDUPE_SECONDS = int(os.getenv("DEDUPE_SECONDS", "900"))
_seen: dict[str, float] = {}
_seen_lock = Lock()

# Hooks the tests (and the offline demo) override
make_client = None
make_toolbox = None
kubectl_runner = None


def should_triage(fingerprint: str, now: float | None = None) -> bool:
    """Same alert re-fired within the window? Skip it: saves cost and Slack noise."""
    now = now or time.time()
    with _seen_lock:
        for fp, t in list(_seen.items()):
            if now - t > DEDUPE_SECONDS:
                del _seen[fp]
        if fingerprint in _seen:
            return False
        _seen[fingerprint] = now
        return True


def _client():
    if make_client:
        return make_client()
    import anthropic  # lazy: tests don't need a key

    return anthropic.Anthropic()  # reads ANTHROPIC_API_KEY


def _toolbox() -> Toolbox:
    return make_toolbox() if make_toolbox else Toolbox(prometheus_url=os.getenv("PROMETHEUS_URL"))


def _check_token(authorization: str | None, env_var: str, required: bool = False) -> None:
    expected = os.getenv(env_var)
    if not expected:
        if required:  # fail closed: no token configured = approvals switched off
            raise HTTPException(status_code=403, detail=f"disabled: set {env_var} to enable")
        return
    if authorization != f"Bearer {expected}":
        raise HTTPException(status_code=401, detail="bad token")


def run_incident(incident_id: int, alert: dict) -> Diagnosis | None:
    inc = store.get(incident_id)
    try:
        d = triage(alert, _client(), _toolbox(), on_event=lambda e: store.add_event(incident_id, e))
    except Exception as e:  # never let one bad alert kill the worker
        log.exception("triage failed for incident %s", incident_id)
        store.set_status(incident_id, "failed", f"{type(e).__name__}: {e}")
        return None
    payload = to_slack_blocks(inc.alertname, d)
    if url := os.getenv("SLACK_WEBHOOK_URL"):
        try:
            post_to_slack(url, payload)
        except Exception:
            log.exception("Slack post failed")
    return d


# ---------------------------------------------------------------------------- API
@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/alertmanager", status_code=202)
def alertmanager_webhook(
    payload: dict, background: BackgroundTasks, authorization: str | None = Header(default=None)
):
    _check_token(authorization, "WEBHOOK_TOKEN")
    queued = []
    for alert in payload.get("alerts", []):
        if alert.get("status") != "firing":
            continue
        fp = alert.get("fingerprint") or json.dumps(alert.get("labels", {}), sort_keys=True)
        if not should_triage(fp):
            continue
        labels = alert.get("labels", {})
        inc = store.create(labels.get("alertname", "unknown"), labels.get("namespace", "?"))
        background.add_task(run_incident, inc.id, alert)
        queued.append(inc.id)
    return {"queued": queued}


@app.get("/incidents")
def list_incidents():
    return store.list()


@app.get("/incidents/{incident_id}")
def get_incident(incident_id: int):
    inc = store.get(incident_id)
    if not inc:
        raise HTTPException(404, "not found")
    return {
        **inc.summary(),
        "diagnosis": inc.diagnosis,
        "events": inc.events,
        "action_result": inc.action_result,
    }


@app.get("/incidents/{incident_id}/stream")
async def stream(incident_id: int):
    """Server-Sent Events: replay past events, then push new ones as they happen."""
    if not store.get(incident_id):
        raise HTTPException(404, "not found")

    async def gen():
        sent = 0
        idle_since = time.time()
        while True:
            events = await asyncio.to_thread(store.wait_for_events, incident_id, sent, 10.0)
            for ev in events:
                yield f"data: {json.dumps(ev)}\n\n"
            if events:
                sent += len(events)
                idle_since = time.time()
            else:
                yield ": keep-alive\n\n"  # stops proxies closing the connection
            inc = store.get(incident_id)
            done = inc and inc.status in ("approved", "rejected", "failed")
            if done or time.time() - idle_since > 600:
                break

    return StreamingResponse(
        gen(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.post("/incidents/{incident_id}/approve")
def approve(incident_id: int, authorization: str | None = Header(default=None)):
    """Human-in-the-loop: the ONLY path that changes the cluster."""
    _check_token(authorization, "APPROVER_TOKEN", required=True)
    inc = store.get(incident_id)
    if not inc:
        raise HTTPException(404, "not found")
    action = (inc.diagnosis or {}).get("proposed_action")
    if inc.status != "diagnosed" or not action:
        raise HTTPException(409, "nothing to approve")
    try:
        kwargs = {"kubectl": kubectl_runner} if kubectl_runner else {}
        result = remediate.execute(action, **kwargs)
    except ToolError as e:
        store.set_status(incident_id, "failed", str(e))
        raise HTTPException(400, str(e)) from e
    log.warning("APPROVED action %s on incident %s: %s", action, incident_id, result.strip())
    store.set_status(incident_id, "approved", result.strip())
    return {"status": "approved", "result": result.strip()}


@app.post("/incidents/{incident_id}/reject")
def reject(incident_id: int, authorization: str | None = Header(default=None)):
    _check_token(authorization, "APPROVER_TOKEN", required=True)
    if not store.get(incident_id):
        raise HTTPException(404, "not found")
    store.set_status(incident_id, "rejected")
    return {"status": "rejected"}


@app.get("/")
def dashboard():
    return FileResponse(STATIC / "index.html")
