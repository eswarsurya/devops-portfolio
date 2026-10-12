"""Background poller with backoff, freshness tracking and Prometheus metrics."""

from __future__ import annotations

import asyncio
import logging
import time
import urllib.request
from collections import deque
from collections.abc import Callable

from prometheus_client import Counter, Gauge, Histogram

from .analytics import diff, stats
from .feed import Train, parse_trains

log = logging.getLogger("railpulse.poller")

FEED_URL = "http://api.irishrail.ie/realtime/realtime.asmx/getCurrentTrainsXML"

POLLS = Counter("railpulse_polls_total", "Feed polls", ["result"])
POLL_SECONDS = Histogram("railpulse_poll_duration_seconds", "Feed fetch + parse time")
LAST_SUCCESS = Gauge("railpulse_last_success_timestamp_seconds", "Unix time of last good poll")
RUNNING = Gauge("railpulse_trains_running", "Trains currently running", ["category"])
AVG_DELAY = Gauge("railpulse_avg_delay_minutes", "Average reported delay", ["category"])
ON_TIME = Gauge(
    "railpulse_on_time_ratio", "Share of running trains within the on-time threshold", ["category"]
)
EVENTS = Counter("railpulse_events_total", "Live events detected", ["kind"])


def fetch_feed(url: str = FEED_URL, timeout: float = 10) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "rail-pulse/0.1 (portfolio project)"})
    with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310 - fixed public URL
        return r.read().decode("utf-8", errors="replace")


class State:
    """Latest snapshot + short history, shared by the poller and the web API."""

    def __init__(self, history: int = 240):
        self.trains: dict[str, Train] = {}
        self.stats: dict = {}
        self.events: deque[dict] = deque(maxlen=100)
        self.history: deque[dict] = deque(maxlen=history)  # ~2h at 30s
        self.last_success: float | None = None
        self.last_error: str | None = None
        self.version = 0  # bumps on every update; SSE clients wait on it
        self.changed = asyncio.Event()

    def apply(self, trains: list[Train], now: float | None = None) -> list[dict]:
        now = now or time.time()
        cur = {t.code: t for t in trains}
        new_events = diff(self.trains, cur) if self.trains else []
        for e in new_events:
            e["ts"] = now
            self.events.appendleft(e)
            EVENTS.labels(e["kind"]).inc()
        self.trains, self.stats = cur, stats(trains)
        self.last_success, self.last_error = now, None
        self.history.append(
            {
                "ts": now,
                "on_time": self.stats["overall"]["on_time_ratio"],
                "avg_delay": self.stats["overall"]["avg_delay"],
                "running": self.stats["overall"]["running"],
            }
        )
        self._export_metrics()
        self._bump()
        return new_events

    def fail(self, error: str) -> None:
        self.last_error = error
        self._bump()

    def is_stale(self, max_age: float = 180) -> bool:
        return self.last_success is None or time.time() - self.last_success > max_age

    def _export_metrics(self) -> None:
        for cat, s in {"all": self.stats["overall"], **self.stats["by_category"]}.items():
            RUNNING.labels(cat).set(s["running"])
            if s["avg_delay"] is not None:
                AVG_DELAY.labels(cat).set(s["avg_delay"])
            if s["on_time_ratio"] is not None:
                ON_TIME.labels(cat).set(s["on_time_ratio"])
        LAST_SUCCESS.set(self.last_success)

    def _bump(self) -> None:
        self.version += 1
        self.changed.set()
        self.changed = asyncio.Event()

    def snapshot(self) -> dict:
        return {
            "version": self.version,
            "trains": [t.to_dict() for t in self.trains.values()],
            "stats": self.stats,
            "events": list(self.events)[:25],
            "history": list(self.history),
            "last_success": self.last_success,
            "stale": self.is_stale(),
            "last_error": self.last_error,
        }


async def run(
    state: State,
    fetch: Callable[[], str] = fetch_feed,
    interval: float = 30,
    max_backoff: float = 300,
    stop: asyncio.Event | None = None,
) -> None:
    """Poll forever. On errors back off exponentially, keep serving the last good data."""
    interval = max(interval, 15)  # be polite to a free public API
    delay = interval
    while not (stop and stop.is_set()):
        start = time.perf_counter()
        try:
            xml = await asyncio.to_thread(fetch)
            trains = parse_trains(xml)
            if not trains:
                raise ValueError("feed returned no trains")
            events = state.apply(trains)
            POLLS.labels("ok").inc()
            log.info("poll ok: %d trains, %d events", len(trains), len(events))
            delay = interval
        except Exception as e:  # network, XML, empty feed...
            POLLS.labels("error").inc()
            state.fail(f"{type(e).__name__}: {e}")
            delay = min(delay * 2, max_backoff)
            log.warning("poll failed (%s), retrying in %.0fs", e, delay)
        finally:
            POLL_SECONDS.observe(time.perf_counter() - start)
        try:
            await asyncio.wait_for((stop or asyncio.Event()).wait(), timeout=delay)
        except TimeoutError:
            pass
