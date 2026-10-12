"""Rate limiting (token bucket), monthly budgets, and a response cache.

All in-memory for a single replica. For multiple replicas these move to Redis
(INCR + EXPIRE for buckets, a hash per team for spend) - same interfaces.
"""

from __future__ import annotations

import hashlib
import json
import threading
import time
from collections import OrderedDict
from datetime import UTC, datetime


class TokenBucket:
    """`rate` requests per minute, bursting up to `rate`."""

    def __init__(self, rate_per_minute: int, clock=time.monotonic):
        self.capacity = float(rate_per_minute)
        self.tokens = float(rate_per_minute)
        self.refill_per_sec = rate_per_minute / 60.0
        self.clock = clock
        self.last = clock()
        self.lock = threading.Lock()

    def allow(self) -> tuple[bool, float]:
        """Returns (allowed, seconds until a token is available)."""
        with self.lock:
            now = self.clock()
            self.tokens = min(self.capacity, self.tokens + (now - self.last) * self.refill_per_sec)
            self.last = now
            if self.tokens >= 1:
                self.tokens -= 1
                return True, 0.0
            return False, (1 - self.tokens) / self.refill_per_sec


class Budgets:
    """Spend per team per calendar month (UTC)."""

    def __init__(self, now=lambda: datetime.now(UTC)):
        self.now = now
        self.spend: dict[tuple[str, str], float] = {}
        self.lock = threading.Lock()

    def _month(self) -> str:
        return self.now().strftime("%Y-%m")

    def spent(self, team: str) -> float:
        return self.spend.get((team, self._month()), 0.0)

    def add(self, team: str, usd: float) -> float:
        with self.lock:
            key = (team, self._month())
            self.spend[key] = self.spend.get(key, 0.0) + usd
            return self.spend[key]


class ResponseCache:
    """Exact-match cache for deterministic requests (temperature 0)."""

    def __init__(self, ttl: int = 600, max_entries: int = 2000, clock=time.monotonic):
        self.ttl, self.max, self.clock = ttl, max_entries, clock
        self.data: OrderedDict[str, tuple[float, dict]] = OrderedDict()
        self.lock = threading.Lock()

    @staticmethod
    def cacheable(body: dict) -> bool:
        return body.get("temperature", 1.0) == 0 and not body.get("stream")

    @staticmethod
    def key(team: str, body: dict) -> str:
        # Team is part of the key: one team never gets another team's cached answer
        payload = json.dumps(
            {
                "team": team,
                **{k: body.get(k) for k in ("model", "system", "messages", "max_tokens", "tools")},
            },
            sort_keys=True,
        )
        return hashlib.sha256(payload.encode()).hexdigest()

    def get(self, k: str) -> dict | None:
        with self.lock:
            item = self.data.get(k)
            if not item:
                return None
            expires, value = item
            if self.clock() > expires:
                del self.data[k]
                return None
            self.data.move_to_end(k)
            return value

    def put(self, k: str, value: dict) -> None:
        with self.lock:
            self.data[k] = (self.clock() + self.ttl, value)
            self.data.move_to_end(k)
            while len(self.data) > self.max:
                self.data.popitem(last=False)  # evict least recently used
