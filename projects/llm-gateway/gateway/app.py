"""llm-gateway: one controlled door between your teams and the Claude API.

Teams point their Anthropic SDK at the gateway with their TEAM key:
    anthropic.Anthropic(base_url="http://llm-gateway", api_key="gw-platform-...")
The gateway checks the key, model allow-list, rate limit and budget, redacts PII,
serves cached answers, calls Claude with the company key, and meters the cost.
"""

from __future__ import annotations

import asyncio
import json
import os
import pathlib
import time
from collections import deque
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, Response, StreamingResponse
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

from . import config as cfg
from .limits import Budgets, ResponseCache, TokenBucket
from .pii import redact_messages
from .upstream import UpstreamError, call_anthropic, call_mock, cost_usd

STATIC = pathlib.Path(__file__).parent / "static"

REQS = Counter("gateway_requests_total", "Requests", ["team", "model", "outcome"])
TOKENS = Counter("gateway_tokens_total", "Tokens", ["team", "model", "direction"])
COST = Counter("gateway_cost_usd_total", "Spend in USD", ["team", "model"])
SAVED = Counter("gateway_cache_saved_usd_total", "Spend avoided by cache hits", ["team"])
PII = Counter("gateway_pii_redactions_total", "PII items redacted", ["team", "kind"])
LATENCY = Histogram(
    "gateway_upstream_latency_seconds",
    "Upstream latency",
    ["model"],
    buckets=(0.1, 0.25, 0.5, 1, 2, 5, 10, 30, 60),
)


class Gateway:
    def __init__(self, conf: cfg.Config, upstream_key: str | None, mock: bool = False):
        self.conf = conf
        self.upstream_key = upstream_key
        self.mock = mock
        self.buckets = {t.name: TokenBucket(t.requests_per_minute) for t in conf.teams}
        self.budgets = Budgets()
        self.cache = ResponseCache(conf.cache_ttl, conf.cache_max)
        self.feed: deque[dict] = deque(maxlen=200)  # recent requests for the live dashboard
        self.version = 0
        self.http: httpx.AsyncClient | None = None

    def record(self, event: dict) -> None:
        self.feed.appendleft({**event, "ts": time.time()})
        self.version += 1

    def summary(self) -> dict:
        teams = []
        for t in self.conf.teams:
            spent = self.budgets.spent(t.name)
            teams.append(
                {
                    "team": t.name,
                    "spent": round(spent, 6),
                    "budget": t.monthly_budget_usd,
                    "used_ratio": round(spent / t.monthly_budget_usd, 4) if t.monthly_budget_usd else 0,
                }
            )
        return {"teams": teams, "recent": list(self.feed)[:40], "version": self.version}


def _load_gateway() -> Gateway:
    conf = cfg.load(os.getenv("GATEWAY_CONFIG", "gateway.yaml"))
    mock = os.getenv("GATEWAY_UPSTREAM", "anthropic") == "mock"
    key = os.getenv("ANTHROPIC_API_KEY")
    if not mock and not key:
        raise SystemExit("ANTHROPIC_API_KEY is required unless GATEWAY_UPSTREAM=mock")
    return Gateway(conf, key, mock)


gw: Gateway | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global gw
    if gw is None:
        gw = _load_gateway()
    gw.http = httpx.AsyncClient()
    yield
    await gw.http.aclose()


app = FastAPI(title="llm-gateway", lifespan=lifespan)


def _error(status: int, kind: str, message: str, headers: dict | None = None) -> JSONResponse:
    # Same error shape as the Anthropic API, so SDK clients handle it naturally
    return JSONResponse(
        {"type": "error", "error": {"type": kind, "message": message}}, status_code=status, headers=headers
    )


@app.post("/v1/messages")
async def messages(request: Request, x_api_key: str | None = Header(default=None)):
    team = gw.conf.team_for_key(x_api_key)
    if team is None:
        return _error(401, "authentication_error", "invalid gateway key")

    body = await request.json()
    model = body.get("model", "")
    if body.get("stream"):
        return _error(400, "invalid_request_error", "streaming is not supported by this gateway yet")
    if model not in team.models:
        REQS.labels(team.name, model, "model_denied").inc()
        return _error(403, "permission_error", f"team '{team.name}' may not use model '{model}'")
    price = gw.conf.pricing.get(model)
    if price is None:
        return _error(400, "invalid_request_error", f"no pricing configured for '{model}'")

    ok, wait = gw.buckets[team.name].allow()
    if not ok:
        REQS.labels(team.name, model, "rate_limited").inc()
        gw.record({"team": team.name, "model": model, "outcome": "rate_limited"})
        return _error(
            429, "rate_limit_error", "team rate limit reached", headers={"retry-after": f"{wait:.1f}"}
        )

    if gw.budgets.spent(team.name) >= team.monthly_budget_usd:
        REQS.labels(team.name, model, "over_budget").inc()
        gw.record({"team": team.name, "model": model, "outcome": "over_budget"})
        return _error(
            429,
            "rate_limit_error",
            f"team '{team.name}' has used its ${team.monthly_budget_usd:.2f} monthly budget",
        )

    redactions: dict[str, int] = {}
    if team.redact_pii:
        body, redactions = redact_messages(body)
        for kind, n in redactions.items():
            PII.labels(team.name, kind).inc(n)

    cache_key = gw.cache.key(team.name, body) if gw.cache.cacheable(body) else None
    if cache_key and (hit := gw.cache.get(cache_key)):
        u = hit.get("usage", {})
        SAVED.labels(team.name).inc(cost_usd(price, u.get("input_tokens", 0), u.get("output_tokens", 0)))
        REQS.labels(team.name, model, "cache_hit").inc()
        gw.record(
            {
                "team": team.name,
                "model": model,
                "outcome": "cache_hit",
                "cost": 0,
                "redactions": sum(redactions.values()),
            }
        )
        return JSONResponse(hit, headers={"x-gateway-cache": "HIT", "x-gateway-team": team.name})

    start = time.perf_counter()
    try:
        result = await (call_mock(body) if gw.mock else call_anthropic(gw.http, gw.upstream_key, body))
    except UpstreamError as e:
        REQS.labels(team.name, model, f"upstream_{e.status}").inc()
        gw.record({"team": team.name, "model": model, "outcome": f"upstream_{e.status}"})
        return JSONResponse(e.body, status_code=e.status)
    except httpx.HTTPError as e:
        REQS.labels(team.name, model, "upstream_unreachable").inc()
        return _error(502, "api_error", f"upstream unreachable: {type(e).__name__}")
    elapsed = time.perf_counter() - start
    LATENCY.labels(model).observe(elapsed)

    usage = result.get("usage", {})
    tin, tout = usage.get("input_tokens", 0), usage.get("output_tokens", 0)
    usd = cost_usd(price, tin, tout)
    gw.budgets.add(team.name, usd)
    TOKENS.labels(team.name, model, "input").inc(tin)
    TOKENS.labels(team.name, model, "output").inc(tout)
    COST.labels(team.name, model).inc(usd)
    REQS.labels(team.name, model, "ok").inc()
    if cache_key:
        gw.cache.put(cache_key, result)
    gw.record(
        {
            "team": team.name,
            "model": model,
            "outcome": "ok",
            "in": tin,
            "out": tout,
            "cost": round(usd, 6),
            "ms": round(elapsed * 1000),
            "redactions": sum(redactions.values()),
        }
    )
    return JSONResponse(
        result,
        headers={
            "x-gateway-cache": "MISS" if cache_key else "BYPASS",
            "x-gateway-team": team.name,
            "x-gateway-cost-usd": f"{usd:.6f}",
        },
    )


# ------------------------------------------------------------------ ops endpoints
def _admin(token: str | None):
    expected = os.getenv("GATEWAY_ADMIN_TOKEN")
    if not expected:
        raise HTTPException(403, "dashboard disabled: set GATEWAY_ADMIN_TOKEN")
    if token != expected:
        raise HTTPException(401, "bad admin token")


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/admin/summary")
def summary(token: str | None = None):
    _admin(token)
    return gw.summary()


@app.get("/admin/stream")
async def stream(request: Request, token: str | None = None):
    _admin(token)  # EventSource can't send headers, so the token rides in the query string

    async def gen():
        seen = -1
        while not await request.is_disconnected():
            if gw.version != seen:
                seen = gw.version
                yield f"data: {json.dumps(gw.summary())}\n\n"
            await asyncio.sleep(0.5)

    return StreamingResponse(gen(), media_type="text/event-stream", headers={"Cache-Control": "no-cache"})


@app.get("/")
def dashboard():
    return FileResponse(STATIC / "dashboard.html")
