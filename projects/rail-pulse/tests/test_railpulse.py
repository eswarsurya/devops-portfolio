import asyncio
import pathlib

import pytest
from fastapi.testclient import TestClient

from railpulse import app as appmod
from railpulse import poller
from railpulse.analytics import diff, is_on_time, stats
from railpulse.feed import Train, category_for, parse_message, parse_trains

FIX = pathlib.Path(__file__).parent / "fixtures"
SNAP = [(FIX / f"snapshot_{i}.xml").read_text() for i in (1, 2, 3)]


def train(code="E1", delay=0, cat=None, status="running", **kw):
    return Train(
        code=code,
        status=status,
        lat=53.3,
        lon=-6.2,
        direction="N",
        category=cat or category_for(code),
        delay_min=delay,
        origin="A",
        destination="B",
        **kw,
    )


# --------------------------------------------------------------------- parsing
def test_parse_message_late_and_position():
    m = parse_message("E820\\n12:05 - Bray to Howth (1 mins late)\\nDeparted Pearse next stop Tara Street")
    assert m == {
        "origin": "Bray",
        "destination": "Howth",
        "scheduled": "12:05",
        "delay_min": 1,
        "last_event": "Departed",
        "last_location": "Pearse",
        "next_stop": "Tara Street",
    }


def test_parse_message_early_is_negative():
    assert (
        parse_message("A208\\n12:05 - Cork to Mallow (-1 mins late)\\nArrived X next stop Y")["delay_min"]
        == -1
    )


def test_parse_message_not_started_has_no_delay():
    m = parse_message("D902\\n12:20 - Drogheda to Dublin Pearse\\nExpected Departure 12:20")
    assert m["destination"] == "Dublin Pearse" and "delay_min" not in m


def test_parse_message_signal_location_without_next_stop():
    m = parse_message("A512\\n11:00 - Dublin to Cork (-5 mins late)\\nArrived Advance Starter")
    assert m["last_location"] == "Advance Starter" and m["next_stop"] is None


def test_parse_trains_from_fixture():
    trains = parse_trains(SNAP[0])
    codes = {t.code for t in trains}
    assert len(trains) == 16 and {"E101", "A101", "D902"} <= codes
    d902 = next(t for t in trains if t.code == "D902")
    assert d902.status == "not_started"


def test_parse_skips_records_without_valid_position():
    xml = SNAP[0].replace("<TrainLatitude>53.2036</TrainLatitude>", "<TrainLatitude>0</TrainLatitude>")
    assert "E101" not in {t.code for t in parse_trains(xml)}


def test_category_heuristic():
    assert [category_for(c) for c in ("E101", "A101", "P501", "D801")] == [
        "DART",
        "Intercity",
        "Commuter",
        "Commuter",
    ]


# --------------------------------------------------------------------- SLIs
def test_on_time_threshold_depends_on_service():
    assert is_on_time(train("E1", 5)) and not is_on_time(train("E1", 6))
    assert is_on_time(train("A1", 10)) and not is_on_time(train("A1", 11))


def test_stats_overall_and_worst():
    s = stats([train("E1", 0), train("E2", 9), train("A1", 20), train("D1", None, status="not_started")])
    assert s["overall"]["running"] == 3
    assert s["overall"]["on_time_ratio"] == pytest.approx(1 / 3, abs=0.001)
    assert s["worst"][0]["code"] == "A1" and s["not_started"] == 1


def test_stats_empty_is_safe():
    assert stats([])["overall"]["on_time_ratio"] is None


# --------------------------------------------------------------------- events
def test_diff_detects_spike_recovery_start_finish():
    prev = {t.code: t for t in [train("A1", 6), train("E2", 9), train("E3", 1)]}
    cur = {t.code: t for t in [train("A1", 15), train("E2", 2), train("E4", 0)]}
    kinds = sorted(e["kind"] for e in diff(prev, cur))
    assert kinds == ["finished", "recovered", "spike", "started"]


def test_events_across_real_fixture_sequence():
    st = poller.State()
    st.apply(parse_trains(SNAP[0]))
    st.apply(parse_trains(SNAP[1]))
    e3 = st.apply(parse_trains(SNAP[2]))
    kinds = {e["kind"] for e in e3}
    assert "spike" in kinds  # A505 jumps 2 -> 22, A101 8 -> 15
    assert "started" in kinds  # D902 begins running
    assert any(e["code"] == "A505" and "+20" in e["text"] for e in e3)


# --------------------------------------------------------------------- poller resilience
def test_poller_backs_off_and_keeps_last_good_data(monkeypatch):
    calls = {"n": 0}
    waits = []

    def flaky():
        calls["n"] += 1
        if calls["n"] == 1:
            return SNAP[0]
        raise OSError("network down")

    async def go():
        st, stop = poller.State(), asyncio.Event()
        real_wait_for = asyncio.wait_for

        async def fake_wait_for(aw, timeout):
            waits.append(timeout)
            if len(waits) >= 4:
                stop.set()
            aw.close() if hasattr(aw, "close") else None
            raise TimeoutError

        monkeypatch.setattr(asyncio, "wait_for", fake_wait_for)
        await poller.run(st, fetch=flaky, interval=15, max_backoff=60, stop=stop)
        monkeypatch.setattr(asyncio, "wait_for", real_wait_for)
        return st

    st = asyncio.run(go())
    assert waits == [15, 30, 60, 60]  # exponential backoff, capped
    assert len(st.trains) == 16 and "network down" in st.last_error  # last good data still served


def test_interval_has_a_polite_minimum(monkeypatch):
    waits = []

    async def go():
        stop = asyncio.Event()

        async def fake_wait_for(aw, timeout):
            waits.append(timeout)
            stop.set()
            aw.close()
            raise TimeoutError

        monkeypatch.setattr(asyncio, "wait_for", fake_wait_for)
        await poller.run(poller.State(), fetch=lambda: SNAP[0], interval=1, stop=stop)

    asyncio.run(go())
    assert waits == [15]


# --------------------------------------------------------------------- HTTP
@pytest.fixture
def client(monkeypatch):
    monkeypatch.setenv("RAILPULSE_DISABLE_POLLER", "1")
    appmod.state = poller.State()
    with TestClient(appmod.app) as c:
        yield c


def test_ready_is_503_until_first_good_poll(client):
    assert client.get("/ready").status_code == 503
    appmod.state.apply(parse_trains(SNAP[0]))
    assert client.get("/ready").status_code == 200


def test_snapshot_and_metrics(client):
    appmod.state.apply(parse_trains(SNAP[0]))
    snap = client.get("/api/snapshot").json()
    assert snap["stats"]["overall"]["running"] == 14 and not snap["stale"]
    m = client.get("/metrics").text
    assert 'railpulse_on_time_ratio{category="all"}' in m
    assert "railpulse_last_success_timestamp_seconds" in m


def test_dashboard_and_static(client):
    assert "Rail Pulse" in client.get("/").text
    assert client.get("/static/ireland.geojson").json()["type"] == "FeatureCollection"
