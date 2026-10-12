import asyncio
import copy

import httpx
import pytest
from fastapi.testclient import TestClient

from gateway import app as appmod
from gateway import config as cfg
from gateway import upstream
from gateway.limits import Budgets, ResponseCache, TokenBucket
from gateway.pii import redact_messages, redact_text

KEY_A, KEY_B = "gw-a-secret", "gw-b-secret"
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
        },
        "teams": [
            {
                "name": "a",
                "key_sha256": cfg.hash_key(KEY_A),
                "models": ["claude-haiku-5-5"],
                "requests_per_minute": 100,
                "monthly_budget_usd": 5,
            },
            {
                "name": "b",
                "key_sha256": cfg.hash_key(KEY_B),
                "models": ["claude-haiku-5-5", "claude-sonnet-5-5"],
                "requests_per_minute": 2,
                "monthly_budget_usd": 0.000001,
                "redact_pii": False,
            },
        ],
    }
)


def body(text="hello", **kw):
    return {
        "model": "claude-haiku-5-5",
        "max_tokens": 100,
        "messages": [{"role": "user", "content": text}],
        **kw,
    }


@pytest.fixture
def client(monkeypatch):
    calls = []

    async def fake_upstream(http, key, b):
        calls.append(b)
        return {
            "type": "message",
            "content": [{"type": "text", "text": "hi"}],
            "usage": {"input_tokens": 1000, "output_tokens": 2000},
        }

    monkeypatch.setattr(appmod, "call_anthropic", fake_upstream)
    monkeypatch.setenv("GATEWAY_ADMIN_TOKEN", "adm")
    appmod.gw = appmod.Gateway(copy.deepcopy(CONF), upstream_key="sk-ant-company", mock=False)
    with TestClient(appmod.app) as c:
        c.calls = calls
        yield c
    appmod.gw = None


def post(c, key, b):
    return c.post("/v1/messages", json=b, headers={"x-api-key": key})


# ------------------------------------------------------------------ PII
def test_redacts_irish_and_eu_pii():
    text = (
        "Mail jane.murphy@example.ie or call 087 123 4567 / +353 1 234 5678. "
        "PPSN 1234567T, IBAN IE29AIBK93115212345678, card 4111 1111 1111 1111."
    )
    out, counts = redact_text(text)
    for secret in ("jane.murphy", "087 123", "234 5678", "1234567T", "IE29AIBK", "4111 1111"):
        assert secret not in out
    assert counts == {"email": 1, "iban": 1, "card": 1, "phone": 2, "ppsn": 1}


def test_card_needs_valid_luhn_so_order_numbers_survive():
    out, counts = redact_text("order 1234 5678 9012 3456 shipped")
    assert "1234 5678 9012 3456" in out and "card" not in counts


def test_redacts_system_and_block_content():
    b = {
        "system": "user is a@b.com",
        "messages": [
            {"role": "user", "content": [{"type": "text", "text": "x@y.ie"}, {"type": "image", "source": {}}]}
        ],
    }
    out, counts = redact_messages(b)
    assert "a@b.com" not in out["system"] and out["messages"][0]["content"][0]["text"] == "[EMAIL]"
    assert out["messages"][0]["content"][1]["type"] == "image" and counts["email"] == 2
    assert b["system"] == "user is a@b.com"  # original not mutated


# ------------------------------------------------------------------ limits
def test_token_bucket_refills_over_time():
    t = [0.0]
    tb = TokenBucket(60, clock=lambda: t[0])  # 1/sec
    assert all(tb.allow()[0] for _ in range(60))
    ok, wait = tb.allow()
    assert not ok and wait == pytest.approx(1.0)
    t[0] += 1.0
    assert tb.allow()[0]


def test_budget_resets_each_month():
    from datetime import UTC, datetime

    now = [datetime(2026, 10, 31, tzinfo=UTC)]
    b = Budgets(now=lambda: now[0])
    b.add("a", 3.0)
    assert b.spent("a") == 3.0
    now[0] = datetime(2026, 11, 1, tzinfo=UTC)
    assert b.spent("a") == 0.0


def test_cache_ttl_and_lru():
    t = [0.0]
    c = ResponseCache(ttl=10, max_entries=2, clock=lambda: t[0])
    c.put("k1", {"v": 1})
    c.put("k2", {"v": 2})
    c.get("k1")  # k1 now most recent
    c.put("k3", {"v": 3})  # evicts k2
    assert c.get("k2") is None and c.get("k1") == {"v": 1}
    t[0] = 11
    assert c.get("k1") is None


def test_cache_key_is_per_team():
    b = body(temperature=0)
    assert ResponseCache.key("a", b) != ResponseCache.key("b", b)


def test_cost_with_long_context_tier():
    p = CONF.pricing["claude-haiku-5-5"]
    assert upstream.cost_usd(p, 1000, 2000) == pytest.approx((1000 * 0.10 + 2000 * 0.50) / 1e6)
    assert upstream.cost_usd(p, 200_000, 0) == pytest.approx(200_000 * 0.50 / 1e6)


# ------------------------------------------------------------------ HTTP flow
def test_rejects_unknown_key(client):
    r = post(client, "nope", body())
    assert r.status_code == 401 and r.json()["error"]["type"] == "authentication_error"


def test_model_allow_list(client):
    assert post(client, KEY_A, body(model="claude-sonnet-5-5")).status_code == 403


def test_streaming_refused_clearly(client):
    assert post(client, KEY_A, body(stream=True)).status_code == 400


def test_happy_path_meters_cost_and_hides_company_key(client):
    r = post(client, KEY_A, body("my email is a@b.com"))
    assert r.status_code == 200 and r.headers["x-gateway-cache"] == "BYPASS"
    assert float(r.headers["x-gateway-cost-usd"]) == pytest.approx((1000 * 0.10 + 2000 * 0.50) / 1e6)
    assert "a@b.com" not in str(client.calls[-1])  # PII never reached upstream
    assert appmod.gw.budgets.spent("a") > 0


def test_pii_redaction_can_be_disabled_per_team(client):
    post(client, KEY_B, body("my email is a@b.com"))
    assert "a@b.com" in str(client.calls[-1])


def test_cache_hit_skips_upstream(client):
    b = body("same question", temperature=0)
    r1, r2 = post(client, KEY_A, b), post(client, KEY_A, b)
    assert r1.headers["x-gateway-cache"] == "MISS" and r2.headers["x-gateway-cache"] == "HIT"
    assert len(client.calls) == 1


def test_rate_limit_returns_429_with_retry_after(client):
    appmod.gw.budgets.spend.clear()
    appmod.gw.conf.teams[1].monthly_budget_usd = 100
    codes = [post(client, KEY_B, body()).status_code for _ in range(3)]
    assert codes == [200, 200, 429]
    r = post(client, KEY_B, body())
    assert "retry-after" in r.headers


def test_budget_exhausted_blocks_team(client):
    assert post(client, KEY_B, body()).status_code == 200  # first call spends the tiny budget
    r = post(client, KEY_B, body())
    assert r.status_code == 429 and "monthly budget" in r.json()["error"]["message"]


def test_upstream_error_passed_through(client, monkeypatch):
    async def boom(http, key, b):
        raise upstream.UpstreamError(
            400, {"type": "error", "error": {"type": "invalid_request_error", "message": "bad"}}
        )

    monkeypatch.setattr(appmod, "call_anthropic", boom)
    r = post(client, KEY_A, body())
    assert r.status_code == 400 and r.json()["error"]["message"] == "bad"


def test_admin_requires_token(client):
    assert client.get("/admin/summary").status_code == 401
    s = client.get("/admin/summary?token=adm").json()
    assert {t["team"] for t in s["teams"]} == {"a", "b"}


def test_metrics_exposed(client):
    post(client, KEY_A, body())
    m = client.get("/metrics").text
    assert 'gateway_cost_usd_total{model="claude-haiku-5-5",team="a"}' in m


# ------------------------------------------------------------------ upstream retries
def test_upstream_retries_on_overload(monkeypatch):
    responses = [httpx.Response(529, json={}), httpx.Response(200, json={"usage": {}})]
    seen = []

    def handler(req):
        seen.append(req.headers["x-api-key"])
        return responses.pop(0)

    async def no_sleep(_):
        return None

    monkeypatch.setattr(asyncio, "sleep", no_sleep)

    async def go():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http:
            return await upstream.call_anthropic(http, "sk-ant-company", body())

    assert asyncio.run(go()) == {"usage": {}}
    assert seen == ["sk-ant-company", "sk-ant-company"]
