"""Run the gateway with a MOCK upstream and simulated traffic from three teams.

    python scripts/demo.py            # then open http://localhost:8070/?token=demo

No API key is used or needed: responses come from the mock upstream, and the
dashboard says "mock" in every model call's id. Costs shown are computed from
real per-token prices on simulated token counts.
"""

from __future__ import annotations

import pathlib
import random
import sys
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

import httpx  # noqa: E402
import uvicorn  # noqa: E402

from gateway import app as appmod  # noqa: E402
from gateway import config as cfg  # noqa: E402

KEYS = {"platform": "gw-platform-demo", "data-science": "gw-ds-demo", "support-bot": "gw-support-demo"}

CONF = cfg.from_dict(
    {
        "pricing": {
            "claude-haiku-5-5": {
                "input": 0.10,
                "output": 0.50,
                "long_context_threshold": 100000,
                "long_input": 0.50,
                "long_output": 2.50,
            },
            "claude-sonnet-5-5": {"input": 2.0, "output": 10.0},
            "claude-opus-5-5": {"input": 4.0, "output": 20.0},
        },
        "teams": [
            {
                "name": "platform",
                "key_sha256": cfg.hash_key(KEYS["platform"]),
                "models": ["claude-haiku-5-5", "claude-sonnet-5-5"],
                "requests_per_minute": 120,
                "monthly_budget_usd": 0.5,
            },
            {
                "name": "data-science",
                "key_sha256": cfg.hash_key(KEYS["data-science"]),
                "models": ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"],
                "requests_per_minute": 60,
                "monthly_budget_usd": 0.08,
            },
            {
                "name": "support-bot",
                "key_sha256": cfg.hash_key(KEYS["support-bot"]),
                "models": ["claude-haiku-5-5"],
                "requests_per_minute": 15,
                "monthly_budget_usd": 0.004,
            },
        ],
    }
)

PROMPTS = {
    "platform": [
        "Summarise this Terraform plan: 3 to add, 1 to change, 0 to destroy.",
        "Explain this Kubernetes event: Back-off restarting failed container.",
        "Write a commit message for: bump helm chart to 0.2.0",
    ],
    "data-science": [
        "Classify the sentiment of these 20 reviews about Dublin Bus.",
        "Draft SQL to find churned customers in the last 90 days.",
        "Explain SHAP values to a non-technical stakeholder.",
    ],
    "support-bot": [
        "Customer jane.murphy@example.ie (087 123 4567) says her card 4111 1111 1111 1111 was charged twice.",
        "Reply to Seán, PPSN 1234567T, IBAN IE29AIBK93115212345678, asking about his refund.",
        "Where is my order? Call me on +353 1 234 5678.",
    ],
}


def traffic():
    time.sleep(1.5)
    with httpx.Client(base_url="http://127.0.0.1:8070", timeout=30) as c:
        while True:
            team = random.choices(list(KEYS), weights=[4, 3, 5])[0]
            model = {
                "platform": random.choice(["claude-haiku-5-5", "claude-sonnet-5-5"]),
                "data-science": random.choice(["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5"]),
                "support-bot": "claude-haiku-5-5",
            }[team]
            if random.random() < 0.05:
                model = "claude-opus-5-5"  # occasionally try a model the team isn't allowed
            body = {
                "model": model,
                "max_tokens": 400,
                "messages": [{"role": "user", "content": random.choice(PROMPTS[team])}],
            }
            if random.random() < 0.4:
                body["temperature"] = 0  # deterministic -> cacheable
            c.post("/v1/messages", json=body, headers={"x-api-key": KEYS[team]})
            time.sleep(random.uniform(0.1, 0.5))


if __name__ == "__main__":
    import os

    os.environ.setdefault("GATEWAY_ADMIN_TOKEN", "demo")
    appmod.gw = appmod.Gateway(CONF, upstream_key=None, mock=True)
    threading.Thread(target=traffic, daemon=True).start()
    print("Dashboard: http://localhost:8070/?token=demo   (mock upstream, simulated traffic)")
    uvicorn.run(appmod.app, host="127.0.0.1", port=8070, log_level="warning")
