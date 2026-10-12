"""The triage agent: a bounded tool-use loop with the Claude Messages API.

The model investigates with read-only tools, then MUST finish by calling
`submit_diagnosis`, which gives us structured output we can trust the shape of.
Every step is reported through `on_event`, so a UI can stream it live.
"""

from __future__ import annotations

import logging
import os
from collections.abc import Callable
from dataclasses import asdict, dataclass, field

from .remediate import ALLOWED_ACTIONS, validate
from .tools import TOOL_SPECS, Toolbox, ToolError

log = logging.getLogger("triage")

MODEL = os.getenv("CLAUDE_MODEL", "claude-haiku-5-5")
MAX_STEPS = int(os.getenv("TRIAGE_MAX_STEPS", "8"))

SYSTEM_PROMPT = """You are an on-call SRE assistant triaging a Kubernetes alert.
Investigate with the read-only tools, starting from the namespace in the alert.
Typical order: pods -> events -> logs of failing pods (previous=true if restarting) -> deployment.
Before each tool call, say in one short sentence what you are checking and why.
Base every claim on tool output and quote the decisive line as evidence.
You cannot change anything yourself. You MAY propose one remediation action from the
allowed list; a human must approve it. Only propose it if the evidence supports it
(e.g. rollout_undo when a bad new image/config caused the failure).
If the evidence is inconclusive, say so and lower your confidence.
When done, call submit_diagnosis exactly once."""

SUBMIT_TOOL = {
    "name": "submit_diagnosis",
    "description": "Submit the final triage result. Ends the investigation.",
    "input_schema": {
        "type": "object",
        "properties": {
            "summary": {"type": "string", "description": "One sentence: what is wrong"},
            "likely_cause": {"type": "string"},
            "evidence": {"type": "array", "items": {"type": "string"}},
            "next_steps": {
                "type": "array",
                "items": {"type": "string"},
                "description": "Commands or actions for the human on call",
            },
            "confidence": {"type": "string", "enum": ["high", "medium", "low"]},
            "proposed_action": {
                "type": "object",
                "description": "Optional fix for a human to approve. "
                + "; ".join(f"{k}: {v}" for k, v in ALLOWED_ACTIONS.items()),
                "properties": {
                    "type": {"type": "string", "enum": sorted(ALLOWED_ACTIONS)},
                    "namespace": {"type": "string"},
                    "deployment": {"type": "string"},
                    "replicas": {"type": "integer"},
                    "reason": {"type": "string"},
                },
                "required": ["type", "namespace", "deployment", "reason"],
            },
        },
        "required": ["summary", "likely_cause", "evidence", "next_steps", "confidence"],
    },
}

Event = dict
EventSink = Callable[[Event], None]


@dataclass
class Diagnosis:
    summary: str
    likely_cause: str
    evidence: list[str]
    next_steps: list[str]
    confidence: str
    proposed_action: dict | None = None
    tool_calls: list[str] = field(default_factory=list)
    complete: bool = True

    def to_dict(self) -> dict:
        return asdict(self)


def describe_alert(alert: dict) -> str:
    labels, ann = alert.get("labels", {}), alert.get("annotations", {})
    lines = [f"Alert: {labels.get('alertname', 'unknown')} ({labels.get('severity', 'n/a')})"]
    lines += [f"  {k}={v}" for k, v in sorted(labels.items()) if k not in ("alertname", "severity")]
    if ann.get("summary"):
        lines.append(f"Summary: {ann['summary']}")
    if ann.get("description"):
        lines.append(f"Description: {ann['description']}")
    return "\n".join(lines)


def _clean_action(raw) -> dict | None:
    """Drop a proposed action that isn't on the allow-list instead of trusting it."""
    if not raw:
        return None
    try:
        clean = validate(raw)
    except ToolError as e:
        log.warning("discarding invalid proposed action: %s", e)
        return None
    clean["reason"] = str(raw.get("reason", ""))[:300]
    return clean


def triage(
    alert: dict,
    client,
    toolbox: Toolbox,
    model: str = MODEL,
    max_steps: int = MAX_STEPS,
    on_event: EventSink | None = None,
) -> Diagnosis:
    emit = on_event or (lambda e: None)
    messages: list[dict] = [{"role": "user", "content": describe_alert(alert)}]
    calls: list[str] = []
    emit({"type": "started", "alert": describe_alert(alert)})

    for step in range(max_steps):
        resp = client.messages.create(
            model=model,
            max_tokens=1500,
            system=SYSTEM_PROMPT,
            tools=[*TOOL_SPECS, SUBMIT_TOOL],
            messages=messages,
        )
        messages.append({"role": "assistant", "content": resp.content})

        for b in resp.content:  # stream the model's reasoning notes
            if getattr(b, "type", None) == "text" and b.text.strip():
                emit({"type": "thought", "text": b.text.strip()})

        tool_uses = [b for b in resp.content if getattr(b, "type", None) == "tool_use"]
        if not tool_uses:  # answered in prose without submitting - nudge once
            messages.append({"role": "user", "content": "Please call submit_diagnosis now."})
            continue

        results = []
        for tu in tool_uses:
            if tu.name == "submit_diagnosis":
                d = tu.input
                diagnosis = Diagnosis(
                    summary=d.get("summary", ""),
                    likely_cause=d.get("likely_cause", ""),
                    evidence=list(d.get("evidence", [])),
                    next_steps=list(d.get("next_steps", [])),
                    confidence=d.get("confidence", "low"),
                    proposed_action=_clean_action(d.get("proposed_action")),
                    tool_calls=calls,
                )
                emit({"type": "diagnosis", "diagnosis": diagnosis.to_dict()})
                return diagnosis

            call = f"{tu.name}({', '.join(f'{k}={v}' for k, v in tu.input.items())})"
            calls.append(call)
            emit({"type": "tool_call", "step": step + 1, "call": call})
            log.info("step %d tool %s", step + 1, call)
            try:
                output, is_error = toolbox.dispatch(tu.name, dict(tu.input)), False
            except ToolError as e:
                output, is_error = str(e), True
            except Exception as e:  # tool backend failure must not crash triage
                output, is_error = f"tool failed: {type(e).__name__}: {e}", True
            emit({"type": "tool_result", "call": call, "error": is_error, "output": output[:1500]})
            results.append(
                {"type": "tool_result", "tool_use_id": tu.id, "content": output, "is_error": is_error}
            )
        messages.append({"role": "user", "content": results})

    diagnosis = Diagnosis(
        summary="Investigation hit the step limit before reaching a conclusion.",
        likely_cause="unknown",
        evidence=[],
        next_steps=["Investigate manually; tool calls made are listed below."],
        confidence="low",
        tool_calls=calls,
        complete=False,
    )
    emit({"type": "diagnosis", "diagnosis": diagnosis.to_dict()})
    return diagnosis
