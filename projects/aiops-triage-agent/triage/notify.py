"""Format a diagnosis for Slack and send it via an incoming webhook."""

from __future__ import annotations

import json
import urllib.request

from .agent import Diagnosis
from .redact import redact

ICON = {"high": "🟢", "medium": "🟡", "low": "🔴"}


def to_slack_blocks(alertname: str, d: Diagnosis) -> dict:
    evidence = "\n".join(f"• `{redact(e)[:300]}`" for e in d.evidence) or "_none_"
    steps = "\n".join(f"{i}. {redact(s)}" for i, s in enumerate(d.next_steps, 1)) or "_none_"
    tools = ", ".join(d.tool_calls) or "none"
    return {
        "text": f"Triage for {alertname}: {d.summary}",  # fallback for notifications
        "blocks": [
            {"type": "header", "text": {"type": "plain_text", "text": f"🩺 {alertname}"}},
            {"type": "section", "text": {"type": "mrkdwn", "text": f"*{redact(d.summary)}*"}},
            {
                "type": "section",
                "fields": [
                    {"type": "mrkdwn", "text": f"*Likely cause*\n{redact(d.likely_cause)}"},
                    {
                        "type": "mrkdwn",
                        "text": f"*Confidence*\n{ICON.get(d.confidence, '⚪')} {d.confidence}",
                    },
                ],
            },
            {"type": "section", "text": {"type": "mrkdwn", "text": f"*Evidence*\n{evidence}"}},
            {"type": "section", "text": {"type": "mrkdwn", "text": f"*Suggested next steps*\n{steps}"}},
            {
                "type": "context",
                "elements": [
                    {
                        "type": "mrkdwn",
                        "text": f"AI-generated from read-only checks: {tools[:500]}. Verify before acting.",
                    }
                ],
            },
        ],
    }


def post_to_slack(webhook_url: str, payload: dict) -> None:
    req = urllib.request.Request(
        webhook_url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10):  # noqa: S310 - operator-configured URL
        pass
