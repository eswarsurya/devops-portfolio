import copy
import time
from types import SimpleNamespace as NS

import pytest
from fastapi.testclient import TestClient

from triage import app as appmod
from triage import remediate
from triage.agent import triage
from triage.demo import ALERT, ReplayClient, demo_toolbox, fake_kubectl
from triage.notify import to_slack_blocks
from triage.redact import redact
from triage.tools import Toolbox, ToolError


# ------------------------------------------------------------------ helpers
def tool(id_, name, inp):
    return NS(type="tool_use", id=id_, name=name, input=inp)


class ScriptedClient:
    """Plays back a fixed list of model responses and records what it was sent."""

    def __init__(self, turns):
        self.turns, self.sent = list(turns), []
        self.messages = self

    def create(self, **kw):
        self.sent.append(copy.deepcopy(kw))
        return NS(content=self.turns.pop(0))


SUBMIT = {"summary": "s", "likely_cause": "c", "evidence": ["e"], "next_steps": ["n"], "confidence": "high"}


@pytest.fixture(autouse=True)
def reset(monkeypatch):
    appmod._seen.clear()
    appmod.store = appmod.Store()
    appmod.make_client = appmod.make_toolbox = appmod.kubectl_runner = None
    monkeypatch.delenv("APPROVER_TOKEN", raising=False)
    monkeypatch.delenv("WEBHOOK_TOKEN", raising=False)
    monkeypatch.delenv("SLACK_WEBHOOK_URL", raising=False)
    yield


# ------------------------------------------------------------------ tool guardrails
def test_rejects_injection_in_namespace():
    tb = Toolbox(kubectl=lambda a: "should not run")
    with pytest.raises(ToolError):
        tb.get_pods("prod; kubectl delete ns prod")


def test_unknown_tool_rejected():
    with pytest.raises(ToolError):
        Toolbox(kubectl=lambda a: "").dispatch("delete_namespace", {"namespace": "prod"})


def test_log_tail_is_capped():
    seen = {}
    Toolbox(kubectl=lambda a: seen.update(args=a) or "").get_pod_logs("prod", "api-1", tail=99999)
    assert "--tail=300" in seen["args"]


def test_tool_output_is_redacted_and_truncated():
    tb = Toolbox(kubectl=lambda a: "DB=postgres://u:hunter2@db/x\n" + "x" * 20000)
    out = tb.get_pods("prod")
    assert "hunter2" not in out and len(out) < 7000


def test_prometheus_requires_config():
    with pytest.raises(ToolError):
        Toolbox().prometheus_query("up")


def test_redact_patterns():
    s = redact("token=abc123 ghp_abcdefghijklmnopqrstuvwxyz0123 AKIAABCDEFGHIJKLMNOP")
    assert "abc123" not in s and "ghp_" not in s and "AKIA" not in s


# ------------------------------------------------------------------ remediation allow-list
def test_remediation_allows_only_listed_actions():
    with pytest.raises(ToolError):
        remediate.validate({"type": "delete", "namespace": "prod", "deployment": "api"})


def test_scale_bounds():
    with pytest.raises(ToolError):
        remediate.validate({"type": "scale", "namespace": "prod", "deployment": "api", "replicas": 500})


def test_rollout_undo_builds_exact_command():
    args = remediate.to_kubectl_args(
        remediate.validate({"type": "rollout_undo", "namespace": "prod", "deployment": "api"})
    )
    assert args == ["rollout", "undo", "deployment/api", "-n", "prod"]


# ------------------------------------------------------------------ agent loop
def test_agent_uses_tools_then_submits_and_streams_events():
    client = ScriptedClient(
        [
            [NS(type="text", text="checking pods"), tool("a", "get_pods", {"namespace": "prod"})],
            [tool("b", "submit_diagnosis", SUBMIT)],
        ]
    )
    events = []
    d = triage(ALERT, client, demo_toolbox(), on_event=events.append)
    assert d.summary == "s" and d.complete
    assert d.tool_calls == ["get_pods(namespace=prod)"]
    kinds = [e["type"] for e in events]
    assert kinds == ["started", "thought", "tool_call", "tool_result", "diagnosis"]
    # the tool result was sent back to the model with the matching id
    last_user = client.sent[1]["messages"][-1]["content"][0]
    assert last_user["tool_use_id"] == "a" and "CrashLoopBackOff" in last_user["content"]


def test_agent_tool_error_is_returned_to_model_not_raised():
    client = ScriptedClient(
        [
            [tool("a", "get_pods", {"namespace": "BAD NS"})],
            [tool("b", "submit_diagnosis", SUBMIT)],
        ]
    )
    triage(ALERT, client, demo_toolbox())
    result = client.sent[1]["messages"][-1]["content"][0]
    assert result["is_error"] is True


def test_agent_stops_at_step_limit():
    loop = [[tool(str(i), "get_pods", {"namespace": "prod"})] for i in range(10)]
    d = triage(ALERT, ScriptedClient(loop), demo_toolbox(), max_steps=3)
    assert d.complete is False and d.confidence == "low" and len(d.tool_calls) == 3


def test_invalid_proposed_action_is_dropped():
    bad = {
        **SUBMIT,
        "proposed_action": {
            "type": "delete_everything",
            "namespace": "prod",
            "deployment": "api",
            "reason": "x",
        },
    }
    d = triage(ALERT, ScriptedClient([[tool("a", "submit_diagnosis", bad)]]), demo_toolbox())
    assert d.proposed_action is None


def test_slack_payload_has_disclaimer():
    d = triage(ALERT, ScriptedClient([[tool("a", "submit_diagnosis", SUBMIT)]]), demo_toolbox())
    blocks = to_slack_blocks("IncidentApiDown", d)
    assert "Verify before acting" in str(blocks)


# ------------------------------------------------------------------ HTTP: webhook, stream, approval
def _wire_replay():
    appmod.make_client = ReplayClient
    appmod.make_toolbox = demo_toolbox
    appmod.kubectl_runner = fake_kubectl


def test_webhook_dedupes_and_ignores_resolved():
    _wire_replay()
    c = TestClient(appmod.app)
    payload = {"alerts": [ALERT, {**ALERT, "status": "resolved", "fingerprint": "x"}]}
    assert c.post("/alertmanager", json=payload).json()["queued"] == [1]
    assert c.post("/alertmanager", json=payload).json()["queued"] == []  # duplicate


def test_webhook_token(monkeypatch):
    monkeypatch.setenv("WEBHOOK_TOKEN", "s3cret")
    c = TestClient(appmod.app)
    assert c.post("/alertmanager", json={"alerts": []}).status_code == 401
    ok = c.post("/alertmanager", json={"alerts": []}, headers={"Authorization": "Bearer s3cret"})
    assert ok.status_code == 202


def test_full_flow_replay_then_human_approval(monkeypatch):
    monkeypatch.setattr(time, "sleep", lambda s: None)
    _wire_replay()
    c = TestClient(appmod.app)
    c.post("/alertmanager", json={"alerts": [ALERT]})  # background task runs inside TestClient
    inc = c.get("/incidents/1").json()
    assert inc["status"] == "diagnosed"
    assert inc["diagnosis"]["proposed_action"]["type"] == "rollout_undo"

    # approvals are OFF until a token is configured (fail closed)
    assert c.post("/incidents/1/approve").status_code == 403
    monkeypatch.setenv("APPROVER_TOKEN", "t")
    assert c.post("/incidents/1/approve", headers={"Authorization": "Bearer wrong"}).status_code == 401
    r = c.post("/incidents/1/approve", headers={"Authorization": "Bearer t"})
    assert r.status_code == 200 and "rolled back" in r.json()["result"]
    # can't approve twice
    assert c.post("/incidents/1/approve", headers={"Authorization": "Bearer t"}).status_code == 409


def test_sse_stream_replays_events(monkeypatch):
    monkeypatch.setattr(time, "sleep", lambda s: None)
    monkeypatch.setenv("APPROVER_TOKEN", "t")
    _wire_replay()
    c = TestClient(appmod.app)
    c.post("/alertmanager", json={"alerts": [ALERT]})
    c.post("/incidents/1/reject", headers={"Authorization": "Bearer t"})  # closes the stream
    body = c.get("/incidents/1/stream").text
    assert body.count("data: ") >= 8
    assert '"type": "diagnosis"' in body and '"status": "rejected"' in body


def test_dashboard_served():
    assert "AIOps Triage" in TestClient(appmod.app).get("/").text
