"""Turn a snapshot of trains into SLIs, and diff snapshots into live events."""

from __future__ import annotations

from .feed import Train

# On-time threshold per service type, in minutes (a train within this is "on time")
ON_TIME_THRESHOLD = {"DART": 5, "Commuter": 5, "Intercity": 10}
SPIKE_MINUTES = 5  # delay grew by at least this much between polls -> event


def is_on_time(t: Train) -> bool:
    return (t.delay_min or 0) <= ON_TIME_THRESHOLD.get(t.category, 5)


def stats(trains: list[Train]) -> dict:
    running = [t for t in trains if t.status == "running"]
    reported = [t for t in running if t.delay_min is not None]

    def block(ts: list[Train]) -> dict:
        rep = [t for t in ts if t.delay_min is not None]
        return {
            "running": len(ts),
            "avg_delay": round(sum(t.delay_min for t in rep) / len(rep), 1) if rep else None,
            "on_time_ratio": round(sum(is_on_time(t) for t in rep) / len(rep), 3) if rep else None,
            "max_delay": max((t.delay_min for t in rep), default=None),
        }

    by_cat = {c: block([t for t in running if t.category == c]) for c in ("DART", "Commuter", "Intercity")}
    worst = sorted(reported, key=lambda t: -t.delay_min)[:5]
    return {
        "overall": block(running),
        "by_category": by_cat,
        "not_started": len(trains) - len(running),
        "worst": [
            {
                "code": t.code,
                "delay_min": t.delay_min,
                "route": f"{t.origin} → {t.destination}",
                "category": t.category,
                "at": t.last_location,
            }
            for t in worst
            if t.delay_min > 0
        ],
        "reported": len(reported),
    }


def diff(prev: dict[str, Train], cur: dict[str, Train]) -> list[dict]:
    """Events between two polls: started, finished, delay spikes, recovered."""
    events = []
    for code, t in cur.items():
        p = prev.get(code)
        route = f"{t.origin} → {t.destination}" if t.origin else t.direction
        if t.status == "running" and (p is None or p.status != "running"):
            events.append({"kind": "started", "code": code, "text": f"{code} departed · {route}"})
        if p and t.delay_min is not None and p.delay_min is not None:
            grew = t.delay_min - p.delay_min
            if grew >= SPIKE_MINUTES:
                events.append(
                    {
                        "kind": "spike",
                        "code": code,
                        "text": f"{code} now {t.delay_min} min late (+{grew}) "
                        f"near {t.last_location} · {route}",
                    }
                )
            elif not is_on_time(p) and is_on_time(t):
                events.append(
                    {
                        "kind": "recovered",
                        "code": code,
                        "text": f"{code} back on time ({t.delay_min} min) · {route}",
                    }
                )
    for code, p in prev.items():
        if code not in cur and p.status == "running":
            events.append(
                {
                    "kind": "finished",
                    "code": code,
                    "text": f"{code} finished at {p.destination or p.last_location}",
                }
            )
    return events
