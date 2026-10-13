"""Public read-only API and dashboard. Data is written only by the ingest job."""

from __future__ import annotations

import datetime as dt
import os
import time
from pathlib import Path

from fastapi import FastAPI, HTTPException, Query, Response
from fastapi.responses import FileResponse, JSONResponse

from . import signal
from .eirgrid import DUBLIN
from .store import Store, from_env

STALE_AFTER_MINUTES = int(os.environ.get("STALE_AFTER_MINUTES", "60"))
STATIC = Path(__file__).parent / "static"


class CachedStore:
    """Caches day documents briefly so a busy dashboard costs a handful of Firestore reads, not thousands."""

    def __init__(self, inner: Store, ttl_seconds: float = 60) -> None:
        self.inner, self.ttl, self._cache = inner, ttl_seconds, {}

    def get_day(self, day: str) -> dict[str, float]:
        hit = self._cache.get(day)
        if hit and time.monotonic() - hit[0] < self.ttl:
            return hit[1]
        values = self.inner.get_day(day)
        self._cache[day] = (time.monotonic(), values)
        return values

    def merge_day(self, day: str, values: dict[str, float]) -> None:
        self.inner.merge_day(day, values)
        self._cache.pop(day, None)


def create_app(store: Store | None = None, clock=lambda: dt.datetime.now(DUBLIN)) -> FastAPI:
    store = store or CachedStore(from_env())
    app = FastAPI(title="Grid Signal", version=os.environ.get("APP_VERSION", "dev"))

    def now_reading():
        now = clock()
        reading = signal.latest(store, now)
        if reading is None:
            raise HTTPException(503, "no readings yet; the ingest job hasn't run")
        return now, reading

    @app.get("/health")
    def health():
        """Healthy only if data is fresh. The uptime check alerts on this, so a stuck ingest job pages someone."""
        now = clock()
        reading = signal.latest(store, now)
        if reading is None:
            return JSONResponse({"status": "no data"}, status_code=503)
        age = int((now - reading.at).total_seconds() // 60)
        ok = age <= STALE_AFTER_MINUTES
        return JSONResponse(
            {"status": "ok" if ok else "stale", "data_age_minutes": age}, status_code=200 if ok else 503
        )

    @app.get("/api/now")
    def api_now():
        now, reading = now_reading()
        return reading.as_dict(now)

    @app.get("/api/history")
    def api_history(hours: int = Query(24, ge=1, le=168)):
        return {"points": signal.history(store, clock(), hours)}

    @app.get("/api/best-window")
    def api_best_window(
        duration_minutes: int = Query(60, ge=15, le=720),
        within_hours: int = Query(24, ge=1, le=48),
    ):
        result = signal.best_window(store, clock(), duration_minutes, within_hours)
        if result is None:
            raise HTTPException(503, "not enough history yet (needs a few days of readings)")
        return result

    @app.get("/badge.svg")
    def badge():
        """A README badge with the live grid intensity."""
        try:
            _, reading = now_reading()
            text, colour = (
                f"{reading.intensity:.0f} g/kWh {signal.band(reading.intensity)}",
                {
                    "low": "#2e7d32",
                    "medium": "#b26a00",
                    "high": "#c62828",
                }[signal.band(reading.intensity)],
            )
        except HTTPException:
            text, colour = "no data", "#6b6b6b"
        label, lw, vw = "Irish grid CO₂", 92, 7 * len(text) + 14
        svg = (
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{lw + vw}" height="20" role="img" '
            f'aria-label="{label}: {text}"><rect width="{lw}" height="20" fill="#444"/>'
            f'<rect x="{lw}" width="{vw}" height="20" fill="{colour}"/>'
            f'<g fill="#fff" font-family="Verdana,DejaVu Sans,sans-serif" font-size="11">'
            f'<text x="6" y="14">{label}</text><text x="{lw + 7}" y="14">{text}</text></g></svg>'
        )
        return Response(svg, media_type="image/svg+xml", headers={"Cache-Control": "max-age=300"})

    @app.get("/")
    def dashboard():
        return FileResponse(STATIC / "index.html")

    return app


app = create_app()
