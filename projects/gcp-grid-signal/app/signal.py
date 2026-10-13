"""The useful part: how clean is the grid now, and when is it likely to be cleanest?"""

from __future__ import annotations

import datetime as dt
from dataclasses import dataclass
from statistics import median

from .eirgrid import DUBLIN
from .store import Store

SLOT = dt.timedelta(minutes=15)
# gCO2/kWh. The Irish grid usually sits between about 100 (very windy) and 450 (calm, gas-heavy).
BANDS = [(200, "low"), (300, "medium"), (float("inf"), "high")]


def band(intensity: float) -> str:
    return next(name for limit, name in BANDS if intensity < limit)


def floor_slot(t: dt.datetime) -> dt.datetime:
    return t.replace(minute=t.minute - t.minute % 15, second=0, microsecond=0)


@dataclass
class Reading:
    at: dt.datetime  # Dublin local, tz-aware
    intensity: float
    wind: float | None
    demand: float | None

    @property
    def wind_share(self) -> float | None:
        if self.wind is None or not self.demand:
            return None
        return round(100 * self.wind / self.demand, 1)

    def as_dict(self, now: dt.datetime) -> dict:
        return {
            "at": self.at.isoformat(),
            "intensity_g_per_kwh": self.intensity,
            "band": band(self.intensity),
            "wind_mw": self.wind,
            "demand_mw": self.demand,
            "wind_share_pct": self.wind_share,
            "age_minutes": int((now - self.at).total_seconds() // 60),
        }


def _days_back(now: dt.datetime, n: int) -> list[str]:
    return [(now.date() - dt.timedelta(days=i)).isoformat() for i in range(n)]


def latest(store: Store, now: dt.datetime) -> Reading | None:
    for day in _days_back(now, 2):
        values = store.get_day(day)
        slots = sorted(k.split("/")[0] for k in values if k.endswith("/intensity"))
        if slots:
            s = slots[-1]
            at = dt.datetime.fromisoformat(f"{day}T{s}").replace(tzinfo=DUBLIN)
            return Reading(at, values[f"{s}/intensity"], values.get(f"{s}/wind"), values.get(f"{s}/demand"))
    return None


def history(store: Store, now: dt.datetime, hours: int) -> list[dict]:
    since = now - dt.timedelta(hours=hours)
    points = []
    for day in reversed(_days_back(now, hours // 24 + 2)):
        for key, value in store.get_day(day).items():
            slot, metric = key.split("/")
            if metric != "intensity":
                continue
            at = dt.datetime.fromisoformat(f"{day}T{slot}").replace(tzinfo=DUBLIN)
            if since <= at <= now:
                points.append({"at": at.isoformat(), "intensity_g_per_kwh": value})
    return sorted(points, key=lambda p: p["at"])


def typical_profile(store: Store, now: dt.datetime, days: int = 7) -> dict[str, float]:
    """Median intensity for each 15-minute slot of the day over the last `days` full days."""
    by_slot: dict[str, list[float]] = {}
    for day in _days_back(now, days + 1)[1:]:
        for key, value in store.get_day(day).items():
            slot, metric = key.split("/")
            if metric == "intensity":
                by_slot.setdefault(slot, []).append(value)
    return {slot: median(vals) for slot, vals in by_slot.items()}


def best_window(store: Store, now: dt.datetime, duration_minutes: int, within_hours: int) -> dict | None:
    """Pick the start time in the next `within_hours` whose typical intensity over `duration_minutes`
    is lowest. Typical = median of the same time of day over the last 7 days (EirGrid publishes no
    carbon forecast). Returns None when there isn't enough history yet.
    """
    profile = typical_profile(store, now)
    slots_needed = max(1, -(-duration_minutes // 15))
    first = floor_slot(now) + SLOT
    candidates = int(within_hours * 4) - slots_needed + 1
    best = None
    for i in range(max(candidates, 0)):
        start = first + i * SLOT
        window = [profile.get((start + j * SLOT).strftime("%H:%M")) for j in range(slots_needed)]
        if any(v is None for v in window):
            continue
        avg = sum(window) / len(window)
        if best is None or avg < best[1]:
            best = (start, avg)
    if best is None:
        return None
    current = latest(store, now)
    result = {
        "start": best[0].isoformat(),
        "end": (best[0] + slots_needed * SLOT).isoformat(),
        "expected_intensity_g_per_kwh": round(best[1], 1),
        "expected_band": band(best[1]),
        "method": "median of the same times over the last 7 days",
    }
    if current:
        result["now_intensity_g_per_kwh"] = current.intensity
        result["saving_pct_vs_now"] = round(100 * (current.intensity - best[1]) / current.intensity, 1)
    return result
