"""Calls to the real Claude API (with retries), plus a mock upstream for demos and tests."""

from __future__ import annotations

import asyncio
import random

import httpx

from .config import Price

ANTHROPIC_URL = "https://api.anthropic.com/v1/messages"
RETRY_STATUSES = {429, 500, 502, 503, 504, 529}


class UpstreamError(Exception):
    def __init__(self, status: int, body: dict):
        self.status, self.body = status, body


async def call_anthropic(client: httpx.AsyncClient, api_key: str, body: dict, retries: int = 2) -> dict:
    headers = {"x-api-key": api_key, "anthropic-version": "2023-06-01", "content-type": "application/json"}
    for attempt in range(retries + 1):
        resp = await client.post(ANTHROPIC_URL, json=body, headers=headers, timeout=120)
        if resp.status_code == 200:
            return resp.json()
        if resp.status_code in RETRY_STATUSES and attempt < retries:
            retry_after = float(resp.headers.get("retry-after", 0) or 0)
            await asyncio.sleep(max(retry_after, 0.5 * 2**attempt) + random.uniform(0, 0.25))
            continue
        try:
            payload = resp.json()
        except ValueError:
            payload = {"error": {"type": "upstream_error", "message": resp.text[:300]}}
        raise UpstreamError(resp.status_code, payload)
    raise AssertionError("unreachable")


def cost_usd(price: Price, input_tokens: int, output_tokens: int) -> float:
    pin, pout = price.input, price.output
    if price.long_context_threshold and input_tokens > price.long_context_threshold:
        pin, pout = price.long_input or pin, price.long_output or pout
    return (input_tokens * pin + output_tokens * pout) / 1_000_000


# ------------------------------------------------------------------ mock upstream (demo/tests)
async def call_mock(body: dict) -> dict:
    """Pretend model: latency and token counts that scale with the prompt."""
    text = " ".join(
        (m["content"] if isinstance(m["content"], str) else " ".join(b.get("text", "") for b in m["content"]))
        for m in body.get("messages", [])
    )
    in_tok = max(8, len(text) // 4 + len(str(body.get("system", ""))) // 4)
    out_tok = random.randint(40, min(600, body.get("max_tokens", 600)))
    await asyncio.sleep(random.uniform(0.15, 0.6))
    return {
        "id": f"msg_mock_{random.randint(10**6, 10**7)}",
        "type": "message",
        "role": "assistant",
        "model": body.get("model"),
        "content": [{"type": "text", "text": f"(mock reply to: {text[:60]}...)"}],
        "stop_reason": "end_turn",
        "usage": {"input_tokens": in_tok, "output_tokens": out_tok},
    }
