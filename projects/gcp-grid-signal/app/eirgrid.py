"""Client and parser for EirGrid's Smart Grid Dashboard data (all-island, 15-minute readings).

The dashboard's own chart endpoint is used: it's public but undocumented, so the parser is strict
about what it accepts and a daily CI job checks the live response still parses.
"""

from __future__ import annotations

import datetime as dt
from zoneinfo import ZoneInfo

import httpx

DUBLIN = ZoneInfo("Europe/Dublin")
BASE_URL = "https://www.smartgriddashboard.com"

# FieldName in the response -> our metric name
FIELDS = {
    "CO2_INTENSITY": "intensity",  # gCO2/kWh
    "CO2_EMISSIONS": "emissions",  # tCO2/hr
    "WIND_ACTUAL": "wind",  # MW
    "SYSTEM_DEMAND": "demand",  # MW
}


class FeedError(RuntimeError):
    """EirGrid returned something we can't use."""


def parse_rows(payload: object) -> dict[str, dict[str, float]]:
    """Turn {"Rows": [...]} into {"YYYY-MM-DD": {"HH:MM/metric": value}} keyed by Dublin local time.

    Only all-island rows with a known FieldName and a numeric Value are kept.
    """
    if not isinstance(payload, dict) or not isinstance(payload.get("Rows"), list):
        raise FeedError("expected a JSON object with a 'Rows' list")
    out: dict[str, dict[str, float]] = {}
    for row in payload["Rows"]:
        if not isinstance(row, dict) or row.get("Region") != "ALL":
            continue
        metric = FIELDS.get(row.get("FieldName"))
        value = row.get("Value")
        if metric is None or isinstance(value, bool) or not isinstance(value, (int, float)):
            continue
        try:
            when = dt.datetime.strptime(row["EffectiveTime"], "%d-%b-%Y %H:%M:%S")
        except (KeyError, TypeError, ValueError) as exc:
            raise FeedError(f"bad EffectiveTime in row {row!r}") from exc
        day, slot = when.strftime("%Y-%m-%d"), when.strftime("%H:%M")
        out.setdefault(day, {})[f"{slot}/{metric}"] = float(value)
    return out


def fetch_day(day: dt.date, client: httpx.Client | None = None) -> dict[str, dict[str, float]]:
    """Fetch CO2 intensity/emissions plus wind and demand for one Dublin-local day."""
    own = client is None
    client = client or httpx.Client(base_url=BASE_URL, timeout=20, headers={"User-Agent": "grid-signal"})
    date = day.strftime("%d-%b-%Y")
    common = {"region": "ALL", "dateRange": "day", "dateFrom": date, "dateTo": date}
    requests = [
        {**common, "chartType": "co2", "areas": "co2emission,co2intensity"},
        {**common, "chartType": "default", "areas": "windactual,demandactual"},
    ]
    merged: dict[str, dict[str, float]] = {}
    try:
        for params in requests:
            last_error: Exception | None = None
            for _attempt in range(3):
                try:
                    r = client.get("/api/chart/", params=params)
                    r.raise_for_status()
                    for d, values in parse_rows(r.json()).items():
                        merged.setdefault(d, {}).update(values)
                    break
                except (httpx.HTTPError, ValueError) as exc:
                    last_error = exc
            else:
                raise FeedError(f"EirGrid request failed after 3 attempts: {last_error}")
    finally:
        if own:
            client.close()
    return merged
