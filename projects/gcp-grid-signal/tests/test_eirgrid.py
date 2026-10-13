import json
from pathlib import Path

import httpx
import pytest

from app.eirgrid import FeedError, fetch_day, parse_rows

FIX = Path(__file__).parent / "fixtures"


def load(name):
    return json.loads((FIX / name).read_text())


def test_parses_all_island_rows_by_dublin_day_and_slot():
    out = parse_rows(load("co2_2026-10-13.json"))
    day = out["2026-10-13"]
    assert day["00:00/intensity"] == 125
    assert "13:45/intensity" in day and "13:45/emissions" in day


def test_ignores_nulls_regions_and_unknown_fields():
    day = parse_rows(load("co2_2026-10-13.json"))["2026-10-13"]
    assert "14:00/intensity" not in day  # null value (future slot)
    assert day["13:45/intensity"] != 111  # ROI row must not overwrite the all-island value
    assert not any("SOMETHING" in k for k in day)


@pytest.mark.parametrize("payload", [[], {"rows": []}, {"Rows": "nope"}, None])
def test_rejects_unexpected_shapes(payload):
    with pytest.raises(FeedError):
        parse_rows(payload)


def test_rejects_bad_timestamps():
    with pytest.raises(FeedError):
        parse_rows(
            {"Rows": [{"EffectiveTime": "13/10/2026", "FieldName": "CO2_INTENSITY", "Region": "ALL", "Value": 1}]}
        )


def test_fetch_day_merges_co2_and_outturn_and_retries():
    calls = {"n": 0}

    def handler(request: httpx.Request):
        calls["n"] += 1
        if calls["n"] == 1:
            return httpx.Response(502)  # first attempt fails, retry succeeds
        name = "co2_2026-10-13.json" if request.url.params["chartType"] == "co2" else "outturn_2026-10-13.json"
        return httpx.Response(200, json=load(name))

    import datetime as dt

    client = httpx.Client(base_url="https://example.test", transport=httpx.MockTransport(handler))
    day = fetch_day(dt.date(2026, 10, 13), client)["2026-10-13"]
    assert {"13:45/intensity", "13:45/wind", "13:45/demand"} <= set(day)


def test_fetch_day_gives_up_after_three_failures():
    import datetime as dt

    client = httpx.Client(base_url="https://example.test", transport=httpx.MockTransport(lambda r: httpx.Response(503)))
    with pytest.raises(FeedError, match="3 attempts"):
        fetch_day(dt.date(2026, 10, 13), client)
